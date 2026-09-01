package main

import (
	"os"
	"sync"

	"gopkg.in/yaml.v3"
)

// Config 旁路采集与阻断引擎配置
type Config struct {
	Interface         string       `yaml:"interface"`
	ControlInterface  string       `yaml:"control_interface"`
	SnapLen           int          `yaml:"snap_len"`
	Promisc           bool         `yaml:"promisc"`
	Protocols         Protocols    `yaml:"protocols"`
	PortPolicy        string       `yaml:"port_policy"`
	FixedPorts        []uint16     `yaml:"fixed_ports"`
	Mode              string       `yaml:"mode"`
	ConsoleBase       string       `yaml:"console_base"`
	CollectorToken    string       `yaml:"collector_token"`
	PolicyPollSeconds int          `yaml:"policy_poll_seconds"`
	MetricsPort       int          `yaml:"metrics_port"`
	DomainBlacklist   []string     `yaml:"domain_blacklist"`
	DNSPoison         string       `yaml:"dns_poison"`
	// 运行时状态（由策略轮询更新，非配置）
	mu           sync.RWMutex
	blacklistMap map[string]bool
	authorizedMap map[string]bool // Console 授权放行清单（dns-policy authorizedDomains）
	policyActive  bool            // Console 策略是否已联动（authorized 清单生效）
}

type Protocols struct {
	DNS   bool `yaml:"dns"`
	HTTP  bool `yaml:"http"`
	HTTPS bool `yaml:"https"`
}

// LoadConfig 加载 yaml 配置并填充默认值
func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	cfg := &Config{}
	if err := yaml.Unmarshal(data, cfg); err != nil {
		return nil, err
	}
	if cfg.Interface == "" {
		cfg.Interface = "enp3s0"
	}
	if cfg.SnapLen == 0 {
		cfg.SnapLen = 65535
	}
	if cfg.PolicyPollSeconds == 0 {
		cfg.PolicyPollSeconds = 30
	}
	if cfg.MetricsPort == 0 {
		cfg.MetricsPort = 9102
	}
	if cfg.Mode != "enforcement" {
		cfg.Mode = "monitoring"
	}
	if cfg.DNSPoison != "blackhole" {
		cfg.DNSPoison = "nxdomain"
	}
	cfg.blacklistMap = make(map[string]bool)
	for _, d := range cfg.DomainBlacklist {
		cfg.blacklistMap[d] = true
	}
	cfg.authorizedMap = make(map[string]bool)
	return cfg, nil
}

// IsBlocked 判断域名是否应阻断：本地黑名单（精确+子域）∪ Console 策略（AI 域名非授权）
// aiMatched：分类库（动态/兜底）命中标志，unknown 域名不参与非授权阻断判定
func (c *Config) IsBlocked(domain, category string, aiMatched bool) bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	domain = normalizeDomain(domain)
	// 1. 本地兜底黑名单（精确 + 子域）
	if c.blacklistMap[domain] || subdomainIn(domain, c.blacklistMap) {
		return true
	}
	// 2. Console 策略已联动：授权清单优先放行，AI 分类命中且非授权即阻断
	if c.policyActive {
		if c.authorizedMap[domain] || subdomainIn(domain, c.authorizedMap) {
			return false
		}
		if aiMatched {
			return true
		}
	}
	return false
}

// subdomainIn 子域兜底匹配：xxx.chat.openai.com 命中 chat.openai.com
func subdomainIn(domain string, m map[string]bool) bool {
	for i := 0; i < len(domain); i++ {
		if domain[i] == '.' {
			if m[domain[i+1:]] {
				return true
			}
		}
	}
	return false
}

// SetBlacklist 由策略轮询更新阻断清单（合并兜底）
func (c *Config) SetBlacklist(domains []string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	m := make(map[string]bool)
	for _, d := range c.DomainBlacklist {
		m[d] = true
	}
	for _, d := range domains {
		m[d] = true
	}
	c.blacklistMap = m
}

// SetAuthorized 由策略轮询更新授权放行清单（dns-policy authorizedDomains）
func (c *Config) SetAuthorized(domains []string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	m := make(map[string]bool)
	for _, d := range domains {
		if d = normalizeDomain(d); d != "" {
			m[d] = true
		}
	}
	c.authorizedMap = m
	c.policyActive = true
}

// IsProtocolEnabled 协议开关
func (c *Config) IsProtocolEnabled(p string) bool {
	switch p {
	case "dns":
		return c.Protocols.DNS
	case "http":
		return c.Protocols.HTTP
	case "https":
		return c.Protocols.HTTPS
	}
	return false
}
