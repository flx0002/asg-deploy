#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DNS Shadow AI Collector v2（接口上报版，方案 B）
================================================
功能：抓取宿主机网卡上的 DNS 查询（AI 域名），匹配影子 AI 分类后：
  1) 聚合计数暴露 Prometheus metric（保留 v1 链路，供实时展示）
  2) 按窗口批量上报 ASG Console 的 POST /v1/shadow-ai/detect-events，
     事件持久化到 MySQL（IR-025 内容安全检测记录，可与审计链按 Session ID 关联）
  3) 周期性拉取 GET /v1/shadow-ai/dns-policy，执行控制能力（IR-004）：
     强制模式下对未授权 AI 域名下发 iptables 丢弃规则（DNS 查询阻断），
     监控模式/授权域名自动移除规则。

数据链路：
    tshark (enp3s0, udp 53 查询包, 关键词粗过滤)
      → 连续段精确匹配分类
      → Prometheus /metrics (9101)  +  HTTP 上报 Console (NodePort)
      → 策略轮询 → iptables string 规则同步（OUTPUT/FORWARD, comment=asg-shadow-ai）
"""

import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import urllib.request
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ---------------------------------------------------------------- 配置区

INTERFACE = os.environ.get("ASG_DNS_IFACE", "enp3s0")
LISTEN_ADDR, LISTEN_PORT = "0.0.0.0", 9101
METRIC_NAME = "shadow_ai_detect_category_domain_risk_status_requests"
SOURCE_LABEL = "dns"
TSHARK_BIN = "/usr/bin/tshark"

# Console 上报/策略接口（higress-console NodePort）
CONSOLE_BASE = os.environ.get("ASG_CONSOLE_BASE", "http://127.0.0.1:30080")
COLLECTOR_TOKEN = os.environ.get("ASG_COLLECTOR_TOKEN", "wnt-asg-collector-2026")

REPORT_INTERVAL = 15          # 上报窗口（秒）
POLICY_INTERVAL = 10          # 策略轮询间隔（秒）
PENDING_LIMIT = 500           # 上报失败缓冲上限（条）
IPTABLES_COMMENT = "asg-shadow-ai"

# 与集群中 shadow-ai-detect WasmPlugin 配置保持一致
CATEGORIES = [
    {
        "name": "saas_ai", "risk": "high",
        "domains": ["api.openai.com", "chat.openai.com", "api.anthropic.com", "claude.ai",
                    "gemini.google.com", "deepseek.com", "api.deepseek.com", "chat.deepseek.com",
                    "www.deepseek.com", "mistral.ai", "api.mistral.ai", "coze.com", "www.coze.com",
                    "doubao.com", "kimi.moonshot.cn", "chatglm.cn", "tongyi.aliyun.com",
                    "yiyan.baidu.com", "chat.zhipu.ai", "api.groq.com", "ai-demo.local"],
        "suffixes": [".openai.com", ".deepseek.com", ".anthropic.com", ".mistral.ai",
                     ".moonshot.cn", ".coze.com", ".doubao.com"],
    },
    {
        "name": "embedded_ai", "risk": "medium",
        "domains": ["copilot.github.com", "api.githubcopilot.com", "cursor.sh",
                    "codeium.com", "windsurf.com", "notion.so"],
        "suffixes": [".cursor.sh", ".codeium.com"],
    },
    {
        "name": "ai_agent", "risk": "critical",
        "domains": ["models.openclaw.ai", "api.openclaw.ai", "langchain.com", "winclaw.ai"],
        "suffixes": [".openclaw.ai", ".langchain.com"],
    },
]

# 粗过滤关键词（tshark -Y 用，精确匹配在 Python 侧）
_COMMON_TLDS = {"com", "net", "org", "io", "co", "cn", "ai", "sh", "app", "dev"}
_KEYWORD_PARTS = set()
for _cat in CATEGORIES:
    for _d in _cat["domains"] + _cat["suffixes"]:
        for _p in _d.strip(".").split("."):
            if len(_p) >= 4 and _p not in _COMMON_TLDS:
                _KEYWORD_PARTS.add(_p)
_KEYWORD_PARTS.update({"coze", "groq", "openclaw", "winclaw"})
KEYWORDS_REGEX = "(?i)(" + "|".join(re.escape(k) for k in sorted(_KEYWORD_PARTS)) + ")"

# 分类内全部已知域名（含后缀展开）
KNOWN_DOMAINS = sorted(
    {d for cat in CATEGORIES for d in cat["domains"] + [s.lstrip(".") for s in cat["suffixes"]]})


# ---------------------------------------------------------------- 匹配逻辑

def match_category(qname):
    """连续域名段匹配，兼容 CNAME 链（api.deepseek.com.eo.dnse1.com 命中 deepseek.com）。"""
    parts = qname.lower().rstrip(".").split(".")
    for cat in CATEGORIES:
        for d in cat["domains"] + [s.lstrip(".") for s in cat["suffixes"]]:
            dparts = d.split(".")
            for i in range(len(parts) - len(dparts) + 1):
                if parts[i:i + len(dparts)] == dparts:
                    return cat, d
    return None, None


def dns_qname_pattern(domain):
    """将域名编码为 DNS qname 字节序列（每段前置长度字节），
    作为 iptables string 匹配串：精确命中该域名（含其任意子域），
    避免主域段匹配误伤同名站点（如 yiyan.baidu.com 不影响 baidu.com）。"""
    out = b""
    for part in domain.lower().rstrip(".").split("."):
        out += bytes([len(part)]) + part.encode("ascii")
    return out



def is_authorized(domain, authorized):
    for a in authorized:
        if domain == a or domain.endswith("." + a):
            return True
    return False


# ---------------------------------------------------------------- iptables 控制

def run_iptables(args):
    try:
        cmd = [a if isinstance(a, bytes) else a.encode() for a in ["iptables", "-w", "2"] + args]
        proc = subprocess.run(cmd, capture_output=True, timeout=10)
        return proc.returncode == 0, proc.stderr.decode("utf-8", "replace").strip()
    except Exception as e:
        return False, str(e)



def iptables_rule_args(pattern):
    # DNS 层阻断：任意 UDP 端口上的明文 DNS 查询（qname 二进制，去端口限制，
    # 覆盖 53/5353 等非标端口；插入与删除统一 --hex-string，保证可删）
    return ["-p", "udp", "-m", "string", "--hex-string",
            "|%s|" % pattern.hex(), "--algo", "bm", "-j", "DROP"]


def sni_rule_args(domain):
    # 连接层阻断：任意 TCP 端口上的 TLS ClientHello 明文 SNI 匹配
    # （与端口无关；HTTPS 无论 443/8443 都必须携带 SNI）
    return ["-p", "tcp", "-m", "string", "--string", domain,
            "--algo", "bm", "-j", "DROP"]


def list_block_rules():
    """返回 (dns_patterns, sni_patterns)：解析 iptables -S 中两类阻断规则
    （DNS: -p udp + --hex-string；SNI: -p tcp + --string 文本）。"""
    dns_patterns, sni_patterns = set(), set()
    try:
        out = subprocess.run([b"iptables", b"-w", b"2", b"-S"], capture_output=True,
                             timeout=10).stdout.decode("utf-8", "replace")
        for line in out.splitlines():
            if "-j DROP" not in line or "string" not in line:
                continue
            if "-p udp" in line:
                m = re.search(r'--hex-string "\|([0-9a-f]+)\|"', line)
                if m:
                    dns_patterns.add(bytes.fromhex(m.group(1)))
            elif "-p tcp" in line:
                m = re.search(r'--string "([^"]+)"', line)
                if m:
                    sni_patterns.add(m.group(1))
    except Exception:
        pass
    return dns_patterns, sni_patterns



def sync_block_rules(mode, authorized):
    """双规则同步：DNS qname（任意 UDP 端口）+ TLS SNI（任意 TCP 端口）。
    enforcement 阻断未授权 AI 域名，其余情况清空两类规则。"""
    exp_dns, exp_sni = set(), set()
    if mode == "enforcement":
        for d in KNOWN_DOMAINS:
            if is_authorized(d, authorized):
                continue
            exp_dns.add(dns_qname_pattern(d))
            exp_sni.add(d.lower())
    act_dns, act_sni = list_block_rules()
    for p in sorted(exp_dns - act_dns):
        ok, err = run_iptables(["-I", "OUTPUT", "1"] + iptables_rule_args(p))
        ok2, err2 = run_iptables(["-I", "FORWARD", "1"] + iptables_rule_args(p))
        print("[policy] +dns-block %s (out=%s fwd=%s)" % (p.hex(), ok and ok2, err or err2), flush=True)
    for p in sorted(act_dns - exp_dns):
        run_iptables(["-D", "OUTPUT"] + iptables_rule_args(p))
        run_iptables(["-D", "FORWARD"] + iptables_rule_args(p))
        print("[policy] -dns-block %s" % p.hex(), flush=True)
    for d in sorted(exp_sni - act_sni):
        ok, err = run_iptables(["-I", "OUTPUT", "1"] + sni_rule_args(d))
        ok2, err2 = run_iptables(["-I", "FORWARD", "1"] + sni_rule_args(d))
        print("[policy] +sni-block %s (out=%s fwd=%s)" % (d, ok and ok2, err or err2), flush=True)
    for d in sorted(act_sni - exp_sni):
        run_iptables(["-D", "OUTPUT"] + sni_rule_args(d))
        run_iptables(["-D", "FORWARD"] + sni_rule_args(d))
        print("[policy] -sni-block %s" % d, flush=True)
    return len(exp_dns) + len(exp_sni)



# ---------------------------------------------------------------- 抓包线程

class DnsCapture:

    def __init__(self):
        self.counters = defaultdict(int)          # (category, domain) -> count (metric)
        self.window = {}                          # (category, domain, status) -> 事件聚合
        self.pending = []                         # 上报失败缓冲
        self.lock = threading.Lock()
        self.running = True
        # 策略快照（策略线程更新，上报线程读 status 用）
        self.policy_lock = threading.Lock()
        self.policy_mode = "monitoring"
        self.policy_authorized = set()

    def _tshark_cmd(self):
        return [
            TSHARK_BIN, "-i", INTERFACE, "-n", "-f", "udp port 53", "-l",
            "-T", "fields", "-e", "dns.qry.name", "-e", "ip.src",
            "-Y", 'dns.flags.response == 0 and dns.qry.name matches "' + KEYWORDS_REGEX + '"',
            "-E", "separator=|", "-E", "quote=n",
        ]

    def run(self):
        while self.running:
            proc = subprocess.Popen(self._tshark_cmd(), stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, text=True, bufsize=1)
            try:
                for line in proc.stdout:
                    line = line.strip()
                    if not line:
                        continue
                    self._process_line(line)
            finally:
                try:
                    proc.terminate()
                    proc.wait(timeout=3)
                except Exception:
                    proc.kill()
                if self.running:
                    time.sleep(3)

    def _process_line(self, line):
        fields = line.split("|")
        qname = fields[0].strip() if fields else ""
        src_ip = fields[1].strip() if len(fields) > 1 else ""
        if not qname:
            return
        cat, known_domain = match_category(qname)
        if not cat:
            return
        domain_metric = known_domain.replace(".", "_").replace("-", "_")
        with self.policy_lock:
            blocked = self.policy_mode == "enforcement" and not is_authorized(known_domain,
                                                                              self.policy_authorized)
        status = "blocked" if blocked else "allowed"
        with self.lock:
            self.counters[(cat["name"], cat["risk"], domain_metric)] += 1
            key = (cat["name"], known_domain, status)
            if key not in self.window:
                self.window[key] = {"count": 0, "qname": qname, "src": src_ip}
            self.window[key]["count"] += 1

    def current_status(self, known_domain):
        with self.policy_lock:
            blocked = self.policy_mode == "enforcement" and not is_authorized(known_domain,
                                                                              self.policy_authorized)
        return "blocked" if blocked else "allowed"

    def stop(self):
        self.running = False


# ---------------------------------------------------------------- 上报线程

def http_json(url, payload, method="POST"):
    req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("X-Collector-Token", COLLECTOR_TOKEN)
    with urllib.request.urlopen(req, timeout=8) as resp:
        return resp.status, resp.read().decode("utf-8", "replace")


def report_loop(capture):
    while capture.running:
        time.sleep(REPORT_INTERVAL)
        with capture.lock:
            window = dict(capture.window)
            capture.window.clear()
            pending = list(capture.pending)
            capture.pending = []
        events = []
        for (category, domain, status), agg in window.items():
            events.append({
                "detectType": "dns_shadow_ai",
                "domain": domain,
                "category": category,
                "riskLevel": next((c["risk"] for c in CATEGORIES if c["name"] == category), "high"),
                "status": status,
                "source": "dns",
                "srcIp": agg["src"] or "unknown",
                "detail": json.dumps({"count": agg["count"], "qname": agg["qname"]}),
                "eventTime": int(time.time() * 1000),
            })
        events.extend(pending)
        if not events:
            continue
        try:
            status, body = http_json(CONSOLE_BASE.rstrip("/") + "/v1/shadow-ai/detect-events",
                                     {"events": events})
            if status != 200:
                raise RuntimeError("HTTP %s: %s" % (status, body[:200]))
            print("[report] sent %d events -> %s" % (len(events), status), flush=True)
        except Exception as e:
            print("[report] failed: %s, buffering %d events" % (e, len(events)), flush=True)
            with capture.lock:
                capture.pending = (capture.pending + events)[-PENDING_LIMIT:]


# ---------------------------------------------------------------- 策略线程

def policy_loop(capture):
    while capture.running:
        time.sleep(POLICY_INTERVAL)
        try:
            status, body = http_json(CONSOLE_BASE.rstrip("/") + "/v1/shadow-ai/dns-policy", {}, "GET")
            if status != 200:
                raise RuntimeError("HTTP %s" % status)
            data = json.loads(body)["data"]
            mode = data.get("mode", "monitoring")
            authorized = set(data.get("authorizedDomains") or [])
            with capture.policy_lock:
                capture.policy_mode = mode
                capture.policy_authorized = authorized
            rule_count = sync_block_rules(mode, authorized)
            print("[policy] mode=%s authorized=%d rules=%d"
                  % (mode, len(authorized), rule_count), flush=True)
        except Exception as e:
            print("[policy] fetch failed: %s" % e, flush=True)


# ---------------------------------------------------------------- HTTP /metrics

class MetricsHandler(BaseHTTPRequestHandler):

    def do_GET(self):
        if self.path != "/metrics":
            self.send_error(404)
            return
        body = render_metrics().encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


CAPTURE = DnsCapture()


def render_metrics():
    lines = [
        "# HELP " + METRIC_NAME + " AI domain DNS queries by category/domain/risk/status (source=dns)",
        "# TYPE " + METRIC_NAME + " counter",
    ]
    with CAPTURE.lock:
        for (category, risk, domain), count in sorted(CAPTURE.counters.items()):
            lines.append('%s{category="%s",domain="%s",risk="%s",status="%s",source="%s"} %d'
                         % (METRIC_NAME, category, domain, risk, "allowed", SOURCE_LABEL, count))
    return "\n".join(lines) + "\n"


def serve_metrics():
    server = ThreadingHTTPServer((LISTEN_ADDR, LISTEN_PORT), MetricsHandler)
    server.serve_forever()


# ---------------------------------------------------------------- 入口

def main():
    signal.signal(signal.SIGTERM, lambda *_: CAPTURE.stop())
    signal.signal(signal.SIGINT, lambda *_: CAPTURE.stop())
    threading.Thread(target=serve_metrics, daemon=True).start()
    threading.Thread(target=report_loop, args=(CAPTURE,), daemon=True).start()
    threading.Thread(target=policy_loop, args=(CAPTURE,), daemon=True).start()
    print("[dns-shadow-ai] v2 metrics:%d capture:%s console:%s interval:%ds"
          % (LISTEN_PORT, INTERFACE, CONSOLE_BASE, REPORT_INTERVAL), flush=True)
    # 启动即同步一次策略（让阻断规则立即生效）
    try:
        status, body = http_json(CONSOLE_BASE.rstrip("/") + "/v1/shadow-ai/dns-policy", {}, "GET")
        if status == 200:
            data = json.loads(body)["data"]
            with CAPTURE.policy_lock:
                CAPTURE.policy_mode = data.get("mode", "monitoring")
                CAPTURE.policy_authorized = set(data.get("authorizedDomains") or [])
            sync_block_rules(CAPTURE.policy_mode, CAPTURE.policy_authorized)
    except Exception as e:
        print("[policy] initial sync failed: %s" % e, flush=True)
    CAPTURE.run()


if __name__ == "__main__":
    sys.exit(main())
