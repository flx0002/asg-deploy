// asg-bypass-guard 旁路数据面采集与阻断引擎
//
// 定位：IR-079 模式3（旁路流量接入）生产级实现
// - 采集：AF_PACKET 抓包 + 任意端口协议识别（DNS/HTTP/HTTPS-TLS-SNI），
//   不依赖默认端口 53/443/80——用户改端口仍可检出
// - 阻断：注入式（业界成熟方案：TCP RST / DNS 污染响应），
//   替代 iptables（旁路场景业务流量不经本机，iptables 无效）
// - 联动：Console detect-events 上报 + Prometheus 9102 + 策略轮询
package main

import (
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	cfgPath := flag.String("config", "config.yaml", "配置文件路径")
	flag.Parse()

	cfg, err := LoadConfig(*cfgPath)
	if err != nil {
		log.Fatalf("配置加载失败: %v", err)
	}
	log.Printf("[init] asg-bypass-guard 启动: iface=%s mode=%s port_policy=%s",
		cfg.Interface, cfg.Mode, cfg.PortPolicy)

	// 1. 指标服务
	StartMetrics(cfg.MetricsPort)

	// 2. 注入器（AF_PACKET 发包）
	injectIface := cfg.ControlInterface
	if injectIface == "" {
		injectIface = cfg.Interface
	}
	injector, err := NewInjector(injectIface)
	if err != nil {
		log.Fatalf("注入器初始化失败: %v", err)
	}
	defer injector.Close()

	// 3. 引擎
	sessions := NewSessionTable()
	reporter := NewReporter(cfg)
	defer reporter.Close()
	engine := NewEngine(cfg, sessions, reporter, injector)

	// 4. 策略联动
	pm := NewPolicyManager(cfg, engine)
	go pm.Run()
	defer pm.Close()

	// 5. 采集主循环
	capture, err := OpenCapture(cfg)
	if err != nil {
		log.Fatalf("抓包初始化失败: %v", err)
	}
	defer capture.Close()
	go capture.Run(engine)

	// 6. 信号处理
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	log.Printf("[init] 收到退出信号，优雅停止")
	engine.Close()
}
