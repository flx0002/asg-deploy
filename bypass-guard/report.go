package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Reporter Console 事件上报（批量窗口） + Prometheus 指标
type Reporter struct {
	cfg    *Config
	client *http.Client
	queue  chan EventBody
	done   chan struct{}
}

// EventBody 与 Console DetectEventReportRequest.DetectEvent 对齐
// 上报体: {"events": [DetectEvent, ...]}，POST /v1/shadow-ai/detect-events
type EventBody struct {
	DetectType string `json:"detectType"`
	Domain     string `json:"domain"`
	Category   string `json:"category"`
	RiskLevel  string `json:"riskLevel"`
	Status     string `json:"status"`
	Source     string `json:"source"`
	SrcIP      string `json:"srcIp"`
	SessionID  string `json:"sessionId,omitempty"`
	Detail     string `json:"detail"`
	EventTime  int64  `json:"eventTime"`
}

type eventBatch struct {
	Events []EventBody `json:"events"`
}

const reportQueueSize = 4096

func NewReporter(cfg *Config) *Reporter {
	r := &Reporter{
		cfg:    cfg,
		client: &http.Client{Timeout: 8 * time.Second},
		queue:  make(chan EventBody, reportQueueSize),
		done:   make(chan struct{}),
	}
	go r.sendLoop()
	return r
}

func (r *Reporter) Close() {
	close(r.done)
}

// Report 入队上报（异步批量，不阻塞抓包循环）
// risk：分类库对齐后的风险等级（saas_ai=high / embedded_ai=medium / ai_agent=critical /
// 兜底库 official/proxy=high opensource=medium / unknown=low）；阻断事件恒 critical
func (r *Reporter) Report(ev *ParsedEvent, category string, risk string, blocked bool) {
	status := "monitored"
	if blocked {
		status = "blocked"
		risk = "critical"
	}
	// Prometheus 指标
	bypassRequests.WithLabelValues(ev.Protocol, ev.Domain, category, status).Inc()
	if blocked {
		bypassBlocked.WithLabelValues(ev.Protocol).Inc()
	}
	// detail：基础字段 + TLS 指纹（HTTPS 场景）
	detail := fmt.Sprintf(`{"protocol":"%s","srcPort":%d,"dstPort":%d,"method":"%s","uri":"%s"}`, ev.Protocol, ev.SrcPort, ev.DstPort, ev.Method, ev.URI)
	if ev.JA3 != "" || ev.JA4 != "" {
		detail = fmt.Sprintf(`{"protocol":"%s","srcPort":%d,"dstPort":%d,"method":"%s","uri":"%s","ja3":"%s","ja4":"%s"}`,
			ev.Protocol, ev.SrcPort, ev.DstPort, ev.Method, ev.URI, ev.JA3, ev.JA4)
	}
	body := EventBody{
		DetectType: "bypass_shadow_ai",
		Domain:     ev.Domain,
		Category:   category,
		RiskLevel:  risk,
		Status:     status,
		Source:     "bypass",
		SrcIP:      ev.SrcIP.String(),
		SessionID:  "",
		Detail:     detail,
		EventTime:  time.Now().UnixMilli(),
	}
	select {
	case r.queue <- body:
	default:
		// 队列满丢弃（采集优先，指标仍计数）
		bypassDropped.Inc()
	}
}

// sendLoop 批量窗口发送：满 20 条或 5 秒超时即发
func (r *Reporter) sendLoop() {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	batch := make([]EventBody, 0, 20)
	flush := func() {
		if len(batch) == 0 {
			return
		}
		events := batch
		batch = make([]EventBody, 0, 20)
		r.postBatch(events)
	}
	for {
		select {
		case <-r.done:
			flush()
			return
		case ev := <-r.queue:
			batch = append(batch, ev)
			if len(batch) >= 20 {
				flush()
			}
		case <-ticker.C:
			flush()
		}
	}
}

func (r *Reporter) postBatch(events []EventBody) {
	data, err := json.Marshal(eventBatch{Events: events})
	if err != nil {
		return
	}
	url := r.cfg.ConsoleBase + "/v1/shadow-ai/detect-events"
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(data))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Collector-Token", r.cfg.CollectorToken)
	resp, err := r.client.Do(req)
	if err != nil {
		log.Printf("[report] 上报失败 %s: %v", url, err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		log.Printf("[report] 上报响应异常: %d (events=%d)", resp.StatusCode, len(events))
		return
	}
	log.Printf("[report] 批量上报成功: %d 条事件", len(events))
}

// ---- Prometheus 指标 ----

var (
	// shadow_ai_detect_bypass_requests_total 旁路数据面检出事件（新指标）
	bypassRequests = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "shadow_ai_detect_bypass_requests_total",
		Help: "Bypass data-plane detected requests by protocol/domain/category/status",
	}, []string{"protocol", "domain", "category", "status"})
	// shadow_ai_detect_bypass_blocked_total 旁路注入阻断次数
	bypassBlocked = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "shadow_ai_detect_bypass_blocked_total",
		Help: "Bypass injected block actions by protocol",
	}, []string{"protocol"})
	// shadow_ai_bypass_packets_total 旁路总处理包数
	bypassPackets = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "shadow_ai_bypass_packets_total",
		Help: "Total packets processed by bypass collector",
	})
	// shadow_ai_bypass_dropped_total 上报队列丢弃数
	bypassDropped = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "shadow_ai_bypass_dropped_total",
		Help: "Events dropped due to full report queue",
	})
)

func init() {
	prometheus.MustRegister(bypassRequests, bypassBlocked, bypassPackets, bypassDropped)
}

// StartMetrics 启动 Prometheus 指标服务
func StartMetrics(port int) *http.Server {
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())
	srv := &http.Server{Addr: fmt.Sprintf(":%d", port), Handler: mux}
	go func() {
		log.Printf("[metrics] Prometheus 指标服务启动 :%d", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Printf("[metrics] 服务异常: %v", err)
		}
	}()
	return srv
}
