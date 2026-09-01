package main

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
)

// PolicyManager Console 策略联动轮询：
// - detect-mode：运行模式（monitoring/enforcement）
// - dns-policy：域名授权策略（提取 blocked 域名清单）
// Console 不可达时保持本地兜底配置，不中断采集
type PolicyManager struct {
	cfg    *Config
	engine *Engine
	client *http.Client
	done   chan struct{}
}

func NewPolicyManager(cfg *Config, engine *Engine) *PolicyManager {
	return &PolicyManager{
		cfg:    cfg,
		engine: engine,
		client: &http.Client{Timeout: 5 * time.Second},
		done:   make(chan struct{}),
	}
}

// Run 轮询循环
func (p *PolicyManager) Run() {
	interval := time.Duration(p.cfg.PolicyPollSeconds) * time.Second
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	p.sync()
	for {
		select {
		case <-p.done:
			return
		case <-ticker.C:
			p.sync()
		}
	}
}

func (p *PolicyManager) Close() {
	close(p.done)
}

// sync 拉取一次策略
func (p *PolicyManager) sync() {
	// 1. 运行模式
	if mode, ok := p.fetchMode(); ok {
		p.engine.setMode(mode)
	}
	// 2. 域名策略（阻断清单 + 授权清单 + AI 分类库）
	if blocked, authorized, cats, ok := p.fetchPolicy(); ok {
		p.cfg.SetBlacklist(blocked)
		p.cfg.SetAuthorized(authorized)
		if len(cats) > 0 {
			SetDynamicCategories(cats)
			log.Printf("[policy] 策略更新: blocked=%d authorized=%d categories=%d（与网关同源）",
				len(blocked), len(authorized), len(cats))
		} else {
			log.Printf("[policy] 策略更新: blocked=%d authorized=%d categories=未下发（保留现有，当前=%d）",
				len(blocked), len(authorized), DynamicCategoryCount())
		}
	}
}

// fetchMode 拉取 detect-mode（兼容 JSON 与裸字符串两种返回）
func (p *PolicyManager) fetchMode() (string, bool) {
	url := p.cfg.ConsoleBase + "/v1/shadow-ai/detect-mode"
	resp, err := p.client.Get(url)
	if err != nil {
		log.Printf("[policy] detect-mode 拉取失败: %v", err)
		return "", false
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", false
	}
	// 结构 1：{"mode":"enforcement"}
	var r struct {
		Mode string `json:"mode"`
	}
	if err := json.Unmarshal(data, &r); err == nil && r.Mode != "" {
		return r.Mode, true
	}
	// 结构 2：裸字符串（Console 当前实现）
	mode := strings.TrimSpace(string(data))
	if mode != "" {
		return mode, true
	}
	return "", false
}

// fetchPolicy 拉取域名策略：返回 (blocked 清单, authorized 清单, AI 分类库)
// 兼容三种返回结构：{data:{authorizedDomains, categories}} / {data:[{domain,authorized}]} / 直接数组
func (p *PolicyManager) fetchPolicy() (blocked, authorized []string, cats []CategoryRule, ok bool) {
	url := p.cfg.ConsoleBase + "/v1/shadow-ai/dns-policy"
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, nil, nil, false
	}
	req.Header.Set("X-Collector-Token", p.cfg.CollectorToken)
	resp, err := p.client.Do(req)
	if err != nil {
		log.Printf("[policy] dns-policy 拉取失败: %v", err)
		return nil, nil, nil, false
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, nil, nil, false
	}
	// 结构 1：{data: {mode, authorizedDomains, categories}}（Console 当前实现，categories 可选）
	var r1 struct {
		Data *struct {
			AuthorizedDomains []string       `json:"authorizedDomains"`
			Categories        []CategoryRule `json:"categories"`
		} `json:"data"`
	}
	if err := json.Unmarshal(data, &r1); err == nil && r1.Data != nil {
		return nil, r1.Data.AuthorizedDomains, r1.Data.Categories, true
	}
	// 结构 2：{data: [{domain, authorized}]}
	var r2 struct {
		Data []policyEntry `json:"data"`
	}
	if err := json.Unmarshal(data, &r2); err == nil && len(r2.Data) > 0 {
		b, a := splitAuthorized(r2.Data)
		return b, a, nil, true
	}
	// 结构 3：直接数组
	var arr []policyEntry
	if err := json.Unmarshal(data, &arr); err == nil && len(arr) > 0 {
		b, a := splitAuthorized(arr)
		return b, a, nil, true
	}
	return nil, nil, nil, false
}

type policyEntry struct {
	Domain     string `json:"domain"`
	Authorized bool   `json:"authorized"`
}

// splitAuthorized 按授权标记拆分清单
func splitAuthorized(list []policyEntry) (blocked, authorized []string) {
	for _, e := range list {
		if e.Authorized {
			authorized = append(authorized, e.Domain)
		} else {
			blocked = append(blocked, e.Domain)
		}
	}
	return
}
