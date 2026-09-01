package main

import (
	"log"
	"sync"
	"time"

	"github.com/google/gopacket/layers"
)

// Engine 引擎：协调采集、分类、上报、阻断、策略
type Engine struct {
	cfg      *Config
	sessions *SessionTable
	reporter *Reporter
	injector *Injector
	done     chan struct{}

	modeMu sync.RWMutex
	mode   string // monitoring / enforcement（策略联动动态更新）

	t0 time.Time // DNS 包到达时间打点（单 goroutine 访问，测注入耗时）
}

func NewEngine(cfg *Config, sessions *SessionTable, reporter *Reporter, injector *Injector) *Engine {
	return &Engine{
		cfg:      cfg,
		sessions: sessions,
		reporter: reporter,
		injector: injector,
		done:     make(chan struct{}),
		mode:     cfg.Mode,
	}
}

// currentMode 当前运行模式
func (e *Engine) currentMode() string {
	e.modeMu.RLock()
	defer e.modeMu.RUnlock()
	return e.mode
}

// setMode 策略联动更新模式
func (e *Engine) setMode(m string) {
	if m != "enforcement" {
		m = "monitoring"
	}
	e.modeMu.Lock()
	e.mode = m
	e.modeMu.Unlock()
	log.Printf("[policy] 运行模式更新: %s", m)
}

// Close 优雅退出
func (e *Engine) Close() {
	close(e.done)
}

// handleEvent 事件处理链：分类（动态库+兜底）→ 上报 → enforcement 命中注入阻断
func (e *Engine) handleEvent(ev *ParsedEvent, ip *layers.IPv4) {
	category, risk, matched := ClassifyFull(ev.Domain)
	blocked := e.cfg.IsBlocked(ev.Domain, category, matched)

	// 上报（两种模式均上报，风险等级随分类库对齐，阻断事件恒 critical）
	e.reporter.Report(ev, category, risk, blocked)

	// enforcement 模式 + 命中黑名单 → 注入阻断
	if e.currentMode() == "enforcement" && blocked {
		e.block(ev)
	}
}

// block 注入阻断：DNS → 污染响应；HTTP/HTTPS → RST 重置连接
func (e *Engine) block(ev *ParsedEvent) {
	switch ev.Protocol {
	case "dns":
		if !e.t0.IsZero() {
			log.Printf("[latency] 读包时刻=%s 处理耗时=%v", e.t0.Format("15:04:05.000000"), time.Since(e.t0))
			e.t0 = time.Time{}
		}
		e.injector.SendDNSPoison(ev, e.cfg.DNSPoison)
	case "http", "https":
		key := NewFlowKey(ev.SrcIP, ev.SrcPort, ev.DstIP, ev.DstPort)
		if sess, ok := e.sessions.Get(key); ok {
			if sess.Blocked {
				return // 已注入过，跳过（防重复注入风暴）
			}
			sess.Blocked = true
			sess.RstCount = 1
			sess.LastRstCack = sess.ClientAck
			sess.LastRstSack = sess.ServerAck
			e.injector.SendRST(sess)
			log.Printf("[block] RST 注入会话状态: cseq=%d cack=%d sseq=%d sack=%d", sess.ClientSeq, sess.ClientAck, sess.ServerSeq, sess.ServerAck)
		} else {
			log.Printf("[block] 会话未建立，跳过 RST: %s:%d->%s:%d", ev.SrcIP, ev.SrcPort, ev.DstIP, ev.DstPort)
		}
	}
}

// recheckBlocked 跟随重扫：若服务器响应数据先于 RST 到达客户端（竞速输掉），
// 客户端 RCV.NXT 已前进到扫射点集之外 → RFC 5961 challenge ACK 而非重置。
// 每当会话 seq/ack 前进即以最新值重扫，最多 3 次，确保连接被重置。
func (e *Engine) recheckBlocked(sess *TcpSession) {
	if !sess.Blocked || sess.RstCount >= 3 {
		return
	}
	if sess.ClientAck == sess.LastRstCack && sess.ServerAck == sess.LastRstSack {
		return // 无前进，不重扫
	}
	sess.RstCount++
	sess.LastRstCack = sess.ClientAck
	sess.LastRstSack = sess.ServerAck
	log.Printf("[block] RST 跟随重扫 #%d（RCV.NXT 前进）: cack=%d sack=%d", sess.RstCount, sess.ClientAck, sess.ServerAck)
	e.injector.SendRST(sess)
}
