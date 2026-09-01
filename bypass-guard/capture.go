package main

import (
	"log"
	"os"
	"time"

	"github.com/google/gopacket"
	"github.com/google/gopacket/afpacket"
	"github.com/google/gopacket/layers"
)

// Capture 旁路流量采集器（AF_PACKET 零拷贝收包）
type Capture struct {
	handle *afpacket.TPacket
	cfg    *Config
}

// OpenCapture 打开镜像口抓包
func OpenCapture(cfg *Config) (*Capture, error) {
	// afpacket 限制：block size 必须能被 page size(4096) 整除，
	// 且 block size 必须是 frame size 的整数倍。
	// 默认组合：frame=65536 (2^16)，block=1MB = 65536*16 = 4096*256
	frameSize := cfg.SnapLen
	if frameSize <= 0 || frameSize%4096 != 0 || (1<<20)%frameSize != 0 {
		frameSize = 65536
	}
	blockSize := frameSize * (1<<20 / frameSize)
	h, err := afpacket.NewTPacket(
		afpacket.OptInterface(cfg.Interface),
		afpacket.OptFrameSize(frameSize),
		afpacket.OptBlockSize(blockSize),
		afpacket.OptPollTimeout(1*time.Millisecond),
		// TPacketV3 的 poll 是 block retire 语义：默认 block timeout 下
		// 新包要等内核 retire 后才对用户可见（实测 26~58ms 抖动），
		// DNS 污染竞速、RST 注入时效都依赖低收包延迟，故压到 1ms。
		afpacket.OptBlockTimeout(1*time.Millisecond),
	)
	if err != nil {
		return nil, err
	}
	return &Capture{handle: h, cfg: cfg}, nil
}

func (c *Capture) Close() {
	c.handle.Close()
}

func containsPort(ports []uint16, p uint16) bool {
	for _, x := range ports {
		if x == p {
			return true
		}
	}
	return false
}

// Run 主采集循环
// 处理链：抓包 → 协议识别 → 命中策略（黑名单）→ 上报 + enforcement 注入阻断
// 同时维护 TCP 会话表（seq/ack 跟踪，供 RST 注入）
func (c *Capture) Run(engine *Engine) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-engine.done:
			return
		default:
		}
		// 同步读包循环（绕过 PacketSource 的 goroutine+channel 转发，
		// 消除调度延迟——注入阻断对处理路径延迟敏感）
		data, _, err := c.handle.ZeroCopyReadPacketData()
		if err != nil {
			time.Sleep(1 * time.Millisecond)
			continue
		}
		pkt := gopacket.NewPacket(data, layers.LayerTypeEthernet, gopacket.DecodeOptions{NoCopy: true, Lazy: true})
		c.handlePacket(pkt, engine)
		select {
		case <-ticker.C:
			engine.sessions.Cleanup(2 * time.Minute)
		default:
		}
	}
}

func (c *Capture) handlePacket(pkt gopacket.Packet, engine *Engine) {
	ipLayer := pkt.Layer(layers.LayerTypeIPv4)
	if ipLayer == nil {
		return
	}
	ip := ipLayer.(*layers.IPv4)

	// DNS 包到达打点（测注入耗时链路）
	if ip.Protocol == layers.IPProtocolUDP {
		engine.t0 = time.Now()
	}

	var sess *TcpSession
	var key FlowKey
	// TCP 会话跟踪（供 RST 注入 + 跨包首部提取）
	if tcpLayer, ok := pkt.Layer(layers.LayerTypeTCP).(*layers.TCP); ok {
		var srcMAC [6]byte
		if eth, ok := pkt.Layer(layers.LayerTypeEthernet).(*layers.Ethernet); ok {
			copy(srcMAC[:], eth.SrcMAC)
		}
		key = NewFlowKey(ip.SrcIP, uint16(tcpLayer.SrcPort), ip.DstIP, uint16(tcpLayer.DstPort))
		sess = engine.sessions.GetOrCreate(key, ip.SrcIP, uint16(tcpLayer.SrcPort), ip.DstIP, uint16(tcpLayer.DstPort), srcMAC)
		// 服务器方向学习服务器 MAC（服务器方向 RST 注入直发目标，避免伪造包绕网关被丢弃）
		if uint16(tcpLayer.SrcPort) == sess.ServerPort && sess.ServerMAC == [6]byte{} {
			sess.ServerMAC = srcMAC
		}
		engine.sessions.UpdateSeq(sess, uint16(tcpLayer.SrcPort), tcpLayer.Seq, tcpLayer.Ack, len(tcpLayer.Payload))
		// blocked 会话跟随重扫：客户端 RCV.NXT 前进（如服务器响应先于 RST 到达）时补扫
		engine.recheckBlocked(sess)
		// 仅客户端→服务器方向拼接首部缓冲（避免服务器响应污染提取）
		if len(tcpLayer.Payload) > 0 && uint16(tcpLayer.SrcPort) == sess.ClientPort {
			sess.AppendPayload(tcpLayer.Payload)
		}
		// DEBUG：31511 端口包跟踪（BYPASS_DEBUG=1 时开启）
		if os.Getenv("BYPASS_DEBUG") != "" && (uint16(tcpLayer.SrcPort) == 31511 || uint16(tcpLayer.DstPort) == 31511) {
			head := tcpLayer.Payload
			if len(head) > 12 {
				head = head[:12]
			}
			log.Printf("[dbg] tcp src=%s:%d dst=%s:%d syn=%v ack=%v psh=%v payload=%d head=%x client=%s:%d server=%s:%d cseq=%d cack=%d sseq=%d sack=%d",
				ip.SrcIP, tcpLayer.SrcPort, ip.DstIP, tcpLayer.DstPort,
				tcpLayer.SYN, tcpLayer.ACK, tcpLayer.PSH, len(tcpLayer.Payload), head,
				sess.ClientIP, sess.ClientPort, sess.ServerIP, sess.ServerPort,
				sess.ClientSeq, sess.ClientAck, sess.ServerSeq, sess.ServerAck)
		}
	}

	// 协议识别：先单包，跨包 HTTP/TLS 回退会话 buffer（仅客户端方向，防服务器响应触发重复检出）
	ev := ParsePacket(pkt)
	if ev == nil {
		if tcpLayer, ok := pkt.Layer(layers.LayerTypeTCP).(*layers.TCP); ok && sess != nil && uint16(tcpLayer.SrcPort) == sess.ClientPort && len(sess.payloadBuf) > 0 {
			ev = parseTCPPayload(sess.payloadBuf, ip.SrcIP, ip.DstIP, uint16(tcpLayer.SrcPort), uint16(tcpLayer.DstPort))
		}
	}
	if ev == nil {
		return
	}
	// 端口策略过滤
	if c.cfg.PortPolicy == "fixed" && !containsPort(c.cfg.FixedPorts, ev.SrcPort) && !containsPort(c.cfg.FixedPorts, ev.DstPort) {
		return
	}
	// 协议开关过滤
	if !c.cfg.IsProtocolEnabled(ev.Protocol) {
		return
	}
	engine.handleEvent(ev, ip)
}
