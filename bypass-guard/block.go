package main

import (
	"encoding/binary"
	"fmt"
	"log"
	"net"

	"github.com/google/gopacket"
	"github.com/google/gopacket/layers"
	"golang.org/x/sys/unix"
)

// Injector 注入式阻断发包器（AF_PACKET 原始套接字，业界旁路阻断标准做法：
// 山石网科旁路控制口 / 斗象 OBS / Suricata reject 均基于主动响应注入）
type Injector struct {
	fd         int
	ifaceName  string
	localMAC   [6]byte
	serializer gopacket.SerializeBuffer
}

// NewInjector 打开 AF_PACKET 发包套接字
func NewInjector(ifaceName string) (*Injector, error) {
	fd, err := unix.Socket(unix.AF_PACKET, unix.SOCK_RAW, int(htons(unix.ETH_P_ALL)))
	if err != nil {
		return nil, fmt.Errorf("AF_PACKET socket: %w", err)
	}
	iface, err := net.InterfaceByName(ifaceName)
	if err != nil {
		return nil, fmt.Errorf("interface %s: %w", ifaceName, err)
	}
	var mac [6]byte
	copy(mac[:], iface.HardwareAddr)
	// 绑定到指定接口（仅该接口收发）
	sa := &unix.SockaddrLinklayer{
		Protocol: htons(unix.ETH_P_ALL),
		Ifindex:  iface.Index,
	}
	if err := unix.Bind(fd, sa); err != nil {
		unix.Close(fd)
		return nil, fmt.Errorf("AF_PACKET bind %s: %w", ifaceName, err)
	}
	return &Injector{
		fd:         fd,
		ifaceName:  ifaceName,
		localMAC:   mac,
		serializer: gopacket.NewSerializeBuffer(),
	}, nil
}

func htons(v uint16) uint16 {
	return (v << 8) | (v >> 8)
}

func (inj *Injector) Close() {
	if inj.fd >= 0 {
		unix.Close(inj.fd)
	}
}

// sendFrame 发送完整 L2 帧
func (inj *Injector) sendFrame(dstMAC [6]byte, ipLayer gopacket.SerializableLayer, l4 gopacket.SerializableLayer, payload []byte) error {
	eth := &layers.Ethernet{
		SrcMAC:       net.HardwareAddr(inj.localMAC[:]),
		DstMAC:       net.HardwareAddr(dstMAC[:]),
		EthernetType: layers.EthernetTypeIPv4,
	}
	opts := gopacket.SerializeOptions{FixLengths: true, ComputeChecksums: true}
	inj.serializer.Clear()
	if err := gopacket.SerializeLayers(inj.serializer, opts, eth, ipLayer, l4, gopacket.Payload(payload)); err != nil {
		return err
	}
	sa := &unix.SockaddrLinklayer{
		Protocol: htons(unix.ETH_P_ALL),
		Ifindex:  ifIndexByName(inj.ifaceName),
	}
	err := unix.Sendto(inj.fd, inj.serializer.Bytes(), 0, sa)
	return err
}

var cachedIfIndex = -1

func ifIndexByName(name string) int {
	if cachedIfIndex >= 0 {
		return cachedIfIndex
	}
	iface, err := net.InterfaceByName(name)
	if err != nil {
		return 0
	}
	cachedIfIndex = iface.Index
	return iface.Index
}

// rstSeqSet 生成 RST 注入扫射序号序列（业界旁路阻断标准做法：Suricata reject /
// 山石 OBS 均以多 seq 覆盖 RFC 5961 严格匹配偏差——注入时对端 RCV.NXT 可能因
// 未观察到的分段/乱序/重传而偏离基准值，单点注入可靠性不足）
func rstSeqSet(base uint32) []uint32 {
	offs := []int32{0, 1, -1, 2, -2, 4, -4, 8, -8, 16, -16, 32, -32,
		64, -64, 128, -128, 256, -256, 512, -512,
		1024, -1024, 1460, -1460, 2048, -2048, 2920, -2920, 4096}
	out := make([]uint32, 0, len(offs))
	for _, o := range offs {
		out = append(out, uint32(int64(base)+int64(o)))
	}
	return out
}

// sendRSTBurst 对指定方向扫射注入 RST（伪造 src → dst，目标 MAC 直发）
func (inj *Injector) sendRSTBurst(dstMAC [6]byte, srcIP, dstIP net.IP, srcPort, dstPort uint16, baseSeq, ack uint32) int {
	ip := &layers.IPv4{
		SrcIP:    srcIP,
		DstIP:    dstIP,
		Version:  4,
		TTL:      64,
		Protocol: layers.IPProtocolTCP,
	}
	sent := 0
	for _, seq := range rstSeqSet(baseSeq) {
		tcp := &layers.TCP{
			SrcPort: layers.TCPPort(srcPort),
			DstPort: layers.TCPPort(dstPort),
			Seq:     seq,
			Ack:     ack,
			RST:     true,
			ACK:     true,
			Window:  0,
		}
		_ = tcp.SetNetworkLayerForChecksum(ip)
		if err := inj.sendFrame(dstMAC, ip, tcp, nil); err != nil {
			log.Printf("RST 注入失败: %v", err)
			continue
		}
		sent++
	}
	return sent
}

// SendRST 向客户端与服务端双方向扫射注入 RST，中断 TCP 连接（对 HTTP/HTTPS 均有效，
// 端口无关——任意端口连接都能重置）
func (inj *Injector) SendRST(s *TcpSession) {
	// 向客户端方向：伪造服务器发 RST（seq 基准 = 客户端期望的下一个序号 ClientAck）
	n1 := inj.sendRSTBurst(s.ClientMAC, s.ServerIP, s.ClientIP, s.ServerPort, s.ClientPort, s.ClientAck, s.ClientSeq)
	log.Printf("[block] RST 扫射 -> 客户端 %s:%d (%d 包, seq基准=%d ack=%d, 域名会话 %s:%d)",
		s.ClientIP, s.ClientPort, n1, s.ClientAck, s.ClientSeq, s.ServerIP, s.ServerPort)

	// 向服务器方向：伪造客户端发 RST（seq 基准 = 服务器期望的下一个序号 ServerAck）
	// 服务器 MAC 直发（服务器=采集器宿主同网段时不经网关，避免伪造包被网关丢弃）
	dstMAC := s.ServerMAC
	if dstMAC == [6]byte{} {
		dstMAC = s.ClientMAC // 回退：经网关转发
	}
	n2 := inj.sendRSTBurst(dstMAC, s.ClientIP, s.ServerIP, s.ClientPort, s.ServerPort, s.ServerAck, s.ServerSeq)
	log.Printf("[block] RST 扫射 -> 服务器 %s:%d (%d 包, seq基准=%d ack=%d)",
		s.ServerIP, s.ServerPort, n2, s.ServerAck, s.ServerSeq)
}

// SendDNSPoison 注入伪造 DNS 响应（污染）：nxdomain 或黑洞 IP
// 业界方案：DNS Sinkhole/响应污染（斗象 OBS DNS 阻断、企业 DNS 安全设备）
func (inj *Injector) SendDNSPoison(ev *ParsedEvent, poisonMode string) {
	query := ev.Query
	if query == "" {
		return
	}
	// 构造 DNS 响应
	resp := buildDNSResponse(ev.DnsTxID, query, poisonMode)
	ip := &layers.IPv4{
		SrcIP:    net.IP(ev.DnsServer[:]),
		DstIP:    net.IP(ev.DnsClient[:]),
		Version:  4,
		TTL:      64,
		Protocol: layers.IPProtocolUDP,
	}
	udp := &layers.UDP{
		SrcPort: layers.UDPPort(ev.DnsServerPort),
		DstPort: layers.UDPPort(ev.DnsClientPort),
	}
	_ = udp.SetNetworkLayerForChecksum(ip)
	if err := inj.sendFrame(ev.ClientMAC, ip, udp, resp); err != nil {
		log.Printf("DNS 污染注入失败: %v", err)
		return
	}
	log.Printf("[block] DNS 污染注入 -> %s:%d (txid=%d, %s, mode=%s)", net.IP(ev.DnsClient[:]), ev.DnsClientPort, ev.DnsTxID, query, poisonMode)
}

// buildDNSResponse 构造伪造 DNS 响应
func buildDNSResponse(txid uint16, qname string, mode string) []byte {
	// qname 编码
	q := encodeQName(qname)
	buf := make([]byte, 0, 12+len(q)+4+16)
	var b [2]byte

	// Header
	binary.BigEndian.PutUint16(b[:], txid)
	buf = append(buf, b[:]...)
	if mode == "blackhole" {
		binary.BigEndian.PutUint16(b[:], 0x8180) // QR=1 RD=1 RA=1
	} else {
		binary.BigEndian.PutUint16(b[:], 0x8183) // + RCODE=3 NXDOMAIN
	}
	buf = append(buf, b[:]...)
	qdcount := uint16(1)
	ancount := uint16(0)
	if mode == "blackhole" {
		ancount = 1
	}
	binary.BigEndian.PutUint16(b[:], qdcount)
	buf = append(buf, b[:]...)
	binary.BigEndian.PutUint16(b[:], ancount)
	buf = append(buf, b[:]...)
	binary.BigEndian.PutUint16(b[:], 0) // ns
	buf = append(buf, b[:]...)
	binary.BigEndian.PutUint16(b[:], 0) // ar
	buf = append(buf, b[:]...)

	// Question
	buf = append(buf, q...)
	binary.BigEndian.PutUint16(b[:], 1) // qtype A
	buf = append(buf, b[:]...)
	binary.BigEndian.PutUint16(b[:], 1) // qclass IN
	buf = append(buf, b[:]...)

	// Answer（blackhole 模式：A 127.0.0.1）
	if mode == "blackhole" {
		buf = append(buf, 0xC0, 0x0C) // 压缩指针指向 qname
		binary.BigEndian.PutUint16(b[:], 1) // type A
		buf = append(buf, b[:]...)
		binary.BigEndian.PutUint16(b[:], 1) // class IN
		buf = append(buf, b[:]...)
		binary.BigEndian.PutUint32(b[:], 60) // ttl
		buf = append(buf, b[:]...)
		binary.BigEndian.PutUint16(b[:], 4) // rdlength
		buf = append(buf, b[:]...)
		buf = append(buf, 127, 0, 0, 1)
	}
	return buf
}

// encodeQName 域名 → DNS 长度前缀格式
func encodeQName(domain string) []byte {
	out := make([]byte, 0, len(domain)+2)
	for _, label := range splitLabels(domain) {
		out = append(out, byte(len(label)))
		out = append(out, label...)
	}
	out = append(out, 0)
	return out
}

func splitLabels(domain string) []string {
	var labels []string
	start := 0
	for i := 0; i <= len(domain); i++ {
		if i == len(domain) || domain[i] == '.' {
			if i > start {
				labels = append(labels, domain[start:i])
			}
			start = i + 1
		}
	}
	return labels
}
