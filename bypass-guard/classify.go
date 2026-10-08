package main

import (
	"strings"
	"sync"
)

// CategoryRule 动态分类规则：来自 Console dns-policy 下发的 categories，
// 与网关 ai-shadow-detect 插件配置同源（IR-001 分类口径对齐）。
type CategoryRule struct {
	Name      string   `json:"name"`
	Label     string   `json:"label"`
	RiskLevel string   `json:"risk_level"`
	Domains   []string `json:"domains"`
	Suffixes  []string `json:"suffixes"`
}

// 影子AI 域名分类兜底库：**已清空**（产品决策：分类唯一权威源为 Console/KB）。
// 数据流：KB(active) → ai-shadow-detect WasmPlugin CR categories → dns-policy →
// SetDynamicCategories，与网关内联检测同源同口径（saas_ai/embedded_ai/ai_agent 等）。
// 保留本变量与 ClassifyFull 静态回退分支作为扩展点，但默认为空：Console 不可达的冷启动
// 窗口内域名归类为 unknown/low（不参与 enforcement 非授权阻断判定）；冷启动阻断仍由
// config.yaml 的 domain_blacklist 独立兜底，不依赖本静态库。
var categoryRules = []struct {
	category string
	domains  []string
}{}

// 动态分类库（Console 策略轮询更新，并发读）
var (
	catMu       sync.RWMutex
	dynamicCats []CategoryRule
)

// SetDynamicCategories 更新动态分类库（仅非空时调用方应传入）
func SetDynamicCategories(rules []CategoryRule) {
	catMu.Lock()
	defer catMu.Unlock()
	dynamicCats = rules
}

// DynamicCategoryCount 当前动态分类库规则数（诊断/日志用）
func DynamicCategoryCount() int {
	catMu.RLock()
	defer catMu.RUnlock()
	return len(dynamicCats)
}

// matchIn 分类命中辅助：精确 + 子域名（".example.com" 后缀）
func matchIn(domain string, list []string) bool {
	for _, d := range list {
		d = strings.TrimPrefix(d, ".")
		if d == "" {
			continue
		}
		if domain == d || strings.HasSuffix(domain, "."+d) {
			return true
		}
	}
	return false
}

// ClassifyFull 分类 + 风险等级 + 是否 AI 域名命中（IR-001 分级对齐）：
//  1. 动态库优先（Console dns-policy categories，与网关同源同口径），
//     命中返回分类名与其配置的 risk_level（saas_ai=high / embedded_ai=medium / ai_agent=critical）；
//  2. 动态库未命中时回退本地静态兜底库（categoryRules 现已清空，见其注释；保留为扩展点）；
//  3. 均未命中 → ("unknown", "low", false)。
//
// matched=false（unknown）不参与 enforcement 非授权阻断判定。
func ClassifyFull(domain string) (category, risk string, matched bool) {
	catMu.RLock()
	cats := dynamicCats
	catMu.RUnlock()
	for _, rule := range cats {
		if matchIn(domain, rule.Domains) || matchIn(domain, rule.Suffixes) {
			r := rule.RiskLevel
			if r == "" {
				r = "medium"
			}
			return rule.Name, r, true
		}
	}
	for _, rule := range categoryRules {
		if matchIn(domain, rule.domains) {
			if rule.category == "opensource" {
				return rule.category, "medium", true
			}
			return rule.category, "high", true
		}
	}
	return "unknown", "low", false
}

// Classify 域名分类（兼容旧调用，仅返回分类名）
func Classify(domain string) string {
	c, _, _ := ClassifyFull(domain)
	return c
}
