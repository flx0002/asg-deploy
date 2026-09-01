package main

import (
	"net"
	"sync"
	"time"
)

// FlowKey TCP 会话键（方向无关）
type FlowKey struct {
	IP1, IP2         [4]byte
	Port1, Port2     uint16
}

func NewFlowKey(ip1 net.IP, p1 uint16, ip2 net.IP, p2 uint16) FlowKey {
	var k FlowKey
	a := ip1.To4()
	b := ip2.To4()
	if a == nil || b == nil {
		return k
	}
	// 按 (IP,Port) 排序保证方向无关
	if string(a) > string(b) || (string(a) == string(b) && p1 > p2) {
		copy(k.IP1[:], b)
		copy(k.IP2[:], a)
		k.Port1, k.Port2 = p2, p1
	} else {
		copy(k.IP1[:], a)
		copy(k.IP2[:], b)
		k.Port1, k.Port2 = p1, p2
	}
	return k
}

// TcpSession TCP 会话状态：用于 RST 注入的 seq/ack 跟踪 + HTTP/TLS 跨包首部提取
type TcpSession struct {
	ClientIP   net.IP
	ServerIP   net.IP
	ClientPort uint16
	ServerPort uint16
	ClientMAC  [6]byte // 客户端 MAC（同网段学习，RST 注入目标）
	ServerMAC  [6]byte // 服务器 MAC（服务器方向 RST 注入直发目标）

	ClientSeq uint32 // 客户端→服务器 方向最后观察 seq
	ClientAck uint32
	ServerSeq uint32 // 服务器→客户端 方向最后观察 seq
	ServerAck uint32

	payloadBuf  []byte // 首部缓冲（≤8KB，跨包拼 Host/SNI）
	payloadFull bool
	Blocked     bool   // 会话是否已注入阻断（防重复注入风暴）
	RstCount    int    // RST 扫射已执行次数（跟随重扫上限内）
	LastRstCack uint32 // 上次扫射时的 ClientAck（重扫触发条件：RCV.NXT 前进）
	LastRstSack uint32 // 上次扫射时的 ServerAck
	lastSeen    time.Time
}

const maxPayloadBuf = 8192

// AppendPayload 追加载荷到首部缓冲，返回是否已满
func (s *TcpSession) AppendPayload(b []byte) bool {
	if s.payloadFull {
		return true
	}
	room := maxPayloadBuf - len(s.payloadBuf)
	if len(b) >= room {
		s.payloadBuf = append(s.payloadBuf, b[:room]...)
		s.payloadFull = true
	} else {
		s.payloadBuf = append(s.payloadBuf, b...)
	}
	return s.payloadFull
}

// SessionTable TCP 会话表
type SessionTable struct {
	mu       sync.Mutex
	sessions map[FlowKey]*TcpSession
}

func NewSessionTable() *SessionTable {
	return &SessionTable{sessions: make(map[FlowKey]*TcpSession)}
}

// GetOrCreate 获取或创建会话（方向无关键）
func (t *SessionTable) GetOrCreate(key FlowKey, srcIP net.IP, srcPort uint16, dstIP net.IP, dstPort uint16, srcMAC [6]byte) *TcpSession {
	t.mu.Lock()
	defer t.mu.Unlock()
	if s, ok := t.sessions[key]; ok {
		return s
	}
	s := &TcpSession{
		ClientIP:   srcIP,
		ServerIP:   dstIP,
		ClientPort: srcPort,
		ServerPort: dstPort,
		ClientMAC:  srcMAC,
		lastSeen:   time.Now(),
	}
	t.sessions[key] = s
	return s
}

// Get 查询会话
func (t *SessionTable) Get(key FlowKey) (*TcpSession, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	s, ok := t.sessions[key]
	return s, ok
}

// UpdateSeq 更新 seq/ack（src→dst 方向）
// 注意：带 payload 段的 seq+len 采用单调修正（max 语义）——乱序到达/重传的旧段
// 不得回退确认位置，否则 RST 注入的 seq 会偏离 RCV.NXT 导致 RFC 5961 拒绝
func (t *SessionTable) UpdateSeq(s *TcpSession, srcPort uint16, seq, ack uint32, payloadLen int) {
	if srcPort == s.ClientPort {
		s.ClientSeq = seq
		s.ClientAck = ack
		if payloadLen > 0 {
			want := seq + uint32(payloadLen)
			if s.ServerAck == 0 || int32(want-s.ServerAck) > 0 {
				s.ServerAck = want
			}
		}
	} else {
		s.ServerSeq = seq
		s.ServerAck = ack
		if payloadLen > 0 {
			want := seq + uint32(payloadLen)
			if s.ClientAck == 0 || int32(want-s.ClientAck) > 0 {
				s.ClientAck = want
			}
		}
	}
	s.lastSeen = time.Now()
}

// Cleanup 清理超时会话（防内存膨胀）
func (t *SessionTable) Cleanup(olderThan time.Duration) {
	t.mu.Lock()
	defer t.mu.Unlock()
	cutoff := time.Now().Add(-olderThan)
	for k, s := range t.sessions {
		if s.lastSeen.Before(cutoff) {
			delete(t.sessions, k)
		}
	}
}
