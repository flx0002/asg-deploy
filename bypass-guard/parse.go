package main

import (
	"bytes"
	"encoding/binary"
	"net"
	"strings"

	"github.com/google/gopacket"
	"github.com/google/gopacket/layers"
)

// ParsedEvent 从数据包中提取的检测事件
type ParsedEvent struct {
	Protocol string // dns / http / https
	Domain   string // SNI / HTTP Host / DNS qname
	Host     string // 原始主机头（HTTP 场景，含端口）
	Method   string // HTTP 方法（HTTP 场景）
	Query    string // DNS qname（DNS 场景）
	SrcIP    net.IP
	DstIP    net.IP
	SrcPort  uint16
	DstPort  uint16
	// DNS 污染注入所需
	DnsTxID   uint16
	DnsServer netIP4
	DnsClient netIP4
	DnsServerPort uint16
	DnsClientPort uint16
	ClientMAC [6]byte // 客户端 MAC（注入目标，同网段学习）
	// HTTP 场景 URI
	URI string
	// TLS 客户端指纹（HTTPS 场景，由 ClientHello 计算）
	JA3 string
	JA4 string
}

type netIP4 [4]byte

// ParseResult 解析结果
type ParseResult struct {
	Event  *ParsedEvent
	Pkt    gopacket.Packet
	IsDNSQuery bool
}

var httpMethods = []string{"GET ", "POST ", "PUT ", "DELETE ", "HEAD ", "OPTIONS ", "PATCH ", "CONNECT ", "TRACE "}

// ParsePacket 任意端口协议识别：DNS / HTTP / HTTPS(TLS-SNI)
// 核心原则：按协议特征识别，不依赖默认端口（53/443/80 改掉也能识别）
func ParsePacket(pkt gopacket.Packet) *ParsedEvent {
	ethLayer := pkt.Layer(layers.LayerTypeEthernet)
	var srcMAC, dstMAC [6]byte
	if ethLayer != nil {
		eth := ethLayer.(*layers.Ethernet)
		copy(srcMAC[:], eth.SrcMAC)
		copy(dstMAC[:], eth.DstMAC)
	}

	ipLayer := pkt.Layer(layers.LayerTypeIPv4)
	if ipLayer == nil {
		return nil
	}
	ip := ipLayer.(*layers.IPv4)

	var ev *ParsedEvent
	switch l := pkt.Layer(layers.LayerTypeUDP).(type) {
	case *layers.UDP:
		ev = parseUDP(ip, l, srcMAC, dstMAC)
	default:
	}
	if ev == nil {
		if l, ok := pkt.Layer(layers.LayerTypeTCP).(*layers.TCP); ok {
			ev = parseTCP(ip, l)
		}
	}
	return ev
}

func parseUDP(ip *layers.IPv4, udp *layers.UDP, srcMAC, dstMAC [6]byte) *ParsedEvent {
	payload := udp.Payload
	// DNS 启发式识别（任意端口）：Header(12B) + qname 结构校验
	if len(payload) >= 12 {
		if isDNSQuery(payload) {
			qname, ok := extractQName(payload[12:])
			if !ok || qname == "" {
				return nil
			}
			domain := normalizeDomain(qname)
			var sip, dip netIP4
			copy(sip[:], ip.SrcIP.To4())
			copy(dip[:], ip.DstIP.To4())
			return &ParsedEvent{
				Protocol: "dns",
				Domain:   domain,
				Query:    qname,
				SrcIP:    ip.SrcIP,
				DstIP:    ip.DstIP,
				SrcPort:  uint16(udp.SrcPort),
				DstPort:  uint16(udp.DstPort),
				DnsTxID:  binary.BigEndian.Uint16(payload[0:2]),
				DnsClient: sip,
				DnsServer: dip,
				DnsClientPort: uint16(udp.SrcPort),
				DnsServerPort: uint16(udp.DstPort),
				ClientMAC: srcMAC,
			}
		}
	}
	return nil
}

// isDNSQuery DNS 查询包校验：QR=0（查询）+ qdcount=1 + qname 合法
func isDNSQuery(p []byte) bool {
	if len(p) < 12 {
		return false
	}
	flags := binary.BigEndian.Uint16(p[2:4])
	if flags&0x8000 != 0 { // QR=1 是响应，跳过
		return false
	}
	qdcount := binary.BigEndian.Uint16(p[4:6])
	if qdcount != 1 {
		return false
	}
	if _, ok := extractQName(p[12:]); !ok {
		return false
	}
	return true
}

// extractQName 解析 DNS qname（长度前缀格式），校验合法性
func extractQName(b []byte) (string, bool) {
	var labels []string
	pos := 0
	total := len(b)
	for {
		if pos >= total {
			return "", false
		}
		l := int(b[pos])
		if l == 0 {
			break
		}
		if l > 63 || pos+1+l > total {
			return "", false
		}
		labels = append(labels, string(b[pos+1:pos+1+l]))
		pos += 1 + l
		if len(labels) > 20 {
			return "", false
		}
	}
	if len(labels) == 0 {
		return "", false
	}
	return strings.Join(labels, "."), true
}

// parseTCP TCP 载荷协议识别（任意端口）
func parseTCP(ip *layers.IPv4, tcp *layers.TCP) *ParsedEvent {
	return parseTCPPayload(tcp.Payload, ip.SrcIP, ip.DstIP, uint16(tcp.SrcPort), uint16(tcp.DstPort))
}

// parseTCPPayload 从 TCP 载荷识别 HTTP/TLS（支持跨包拼接后的 buffer 重试）
func parseTCPPayload(payload []byte, srcIP, dstIP net.IP, srcPort, dstPort uint16) *ParsedEvent {
	if len(payload) == 0 {
		return nil
	}
	// 1. TLS ClientHello 特征：0x16 0x03 0x0x 长度 0x01
	if len(payload) >= 6 && payload[0] == 0x16 && payload[1] == 0x03 && payload[5] == 0x01 {
		if ch, ok := parseClientHello(payload); ok && normalizeDomain(ch.sni) != "" {
			return &ParsedEvent{
				Protocol: "https",
				Domain:   normalizeDomain(ch.sni),
				SrcIP:    srcIP,
				DstIP:    dstIP,
				SrcPort:  srcPort,
				DstPort:  dstPort,
				JA3:      ch.JA3(),
				JA4:      ch.JA4(),
			}
		}
	}
	// 2. HTTP 请求特征：方法 + 空格开头
	head := payload
	if len(head) > 16 {
		head = head[:16]
	}
	for _, m := range httpMethods {
		if bytes.HasPrefix(head, []byte(m)) {
			host, uri := extractHTTPHost(payload)
			domain := normalizeDomain(host)
			if domain == "" {
				return nil
			}
			return &ParsedEvent{
				Protocol: "http",
				Domain:   domain,
				Host:     host,
				Method:   strings.TrimSpace(m),
				URI:      uri,
				SrcIP:    srcIP,
				DstIP:    dstIP,
				SrcPort:  srcPort,
				DstPort:  dstPort,
			}
		}
	}
	return nil
}

// extractSNI 从 ClientHello 中提取 SNI（扩展类型 0x0000）
func extractSNI(b []byte) (string, bool) {
	// record hdr 5B + handshake hdr 4B = 9；handshake body: version(2) + random(32)
	// 故 sessionID 长度字节位于偏移 9+2+32=43
	pos := 43
	if len(b) < 44 {
		return "", false
	}
	sessionIDLen := int(b[pos])
	pos += 1 + sessionIDLen
	if pos+2 > len(b) {
		return "", false
	}
	cipherLen := int(binary.BigEndian.Uint16(b[pos : pos+2]))
	pos += 2 + cipherLen
	if pos+2 > len(b) {
		return "", false
	}
	compLen := int(b[0+pos])
	pos += 1 + compLen
	if pos+2 > len(b) {
		return "", false
	}
	extTotal := int(binary.BigEndian.Uint16(b[pos : pos+2]))
	pos += 2
	end := pos + extTotal
	if end > len(b) {
		end = len(b)
	}
	for pos+4 <= end {
		extType := binary.BigEndian.Uint16(b[pos : pos+2])
		extLen := int(binary.BigEndian.Uint16(b[pos+2 : pos+4]))
		if extType == 0 { // server_name
			pos += 4
			if pos+2 > len(b) {
				return "", false
			}
			_ = binary.BigEndian.Uint16(b[pos : pos+2]) // Server Name list length
			pos += 2
			if pos+1 > len(b) {
				return "", false
			}
			_ = b[pos] // Server Name Type（host_name = 0），跳 1 字节
			pos += 1
			if pos+2 > len(b) {
				return "", false
			}
			nameLen := int(binary.BigEndian.Uint16(b[pos : pos+2]))
			pos += 2
			if pos+nameLen > len(b) || nameLen == 0 {
				return "", false
			}
			return string(b[pos : pos+nameLen]), true
		}
		pos += 4 + extLen
	}
	return "", false
}

// extractHTTPHost 从 HTTP 请求中提取 Host 头与 URI
func extractHTTPHost(payload []byte) (host, uri string) {
	// 找第一个 CRLF 行 = 请求行：METHOD SP URI SP HTTP/x
	lineEnd := bytes.Index(payload, []byte("\r\n"))
	if lineEnd < 0 {
		lineEnd = len(payload)
	}
	reqLine := payload[:lineEnd]
	parts := bytes.SplitN(reqLine, []byte(" "), 3)
	if len(parts) >= 2 {
		uri = string(parts[1])
	}
	// Host 头：不区分大小写 "host:"
	lower := bytes.ToLower(payload)
	idx := bytes.Index(lower, []byte("\r\nhost:"))
	if idx < 0 {
		return "", uri
	}
	valStart := idx + len("\r\nhost:")
	valEnd := bytes.Index(payload[valStart:], []byte("\r\n"))
	if valEnd < 0 {
		return "", uri
	}
	return strings.TrimSpace(string(payload[valStart : valStart+valEnd])), uri
}

// normalizeDomain 去掉端口与尾点，转小写
func normalizeDomain(s string) string {
	s = strings.TrimSpace(s)
	s = strings.ToLower(s)
	if i := strings.IndexByte(s, ':'); i >= 0 {
		s = s[:i]
	}
	s = strings.TrimSuffix(s, ".")
	return s
}
