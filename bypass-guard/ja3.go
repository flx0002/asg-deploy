package main

// JA3/JA4 TLS 客户端指纹（从 ClientHello 计算）
// - JA3: salesforce/ja3 规范（MD5 of version,ciphers,extensions,curves,formats）
// - JA4: FoxIO JA4 规范（t + 版本 + sni + 计数 + alpn _ cipher哈希 _ 扩展哈希）
// 用途：以 TLS 客户端特征辅助识别 AI 工具/CLI 流量（浏览器/Python/Curl 指纹不同）

import (
	"crypto/md5"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"sort"
	"strings"
)

type clientHelloInfo struct {
	version uint16   // handshake legacy_version
	tlsVer  uint16   // supported_versions 最高版本（0x002b 扩展，供 JA4）
	ciphers []uint16 // cipher_suites
	exts    []uint16 // extension 类型列表
	curves  []uint16 // supported_groups (0x000a)
	formats []byte   // ec_point_formats (0x000b)
	sigAlgs []uint16 // signature_algorithms (0x000d)
	sni     string
	alpn    string // 首选 ALPN 协议（扩展 0x0010 第一项）
}

// isGREASE RFC 8701 无意义值（0x?a?a），JA4 计算需剔除
func isGREASE(v uint16) bool {
	return (v&0x0f0f) == 0x0a0a && (v&0xff00)>>8 == (v&0x00ff)
}

// parseClientHello 解析 ClientHello（b 从 TLS record 起始）
// 结构：record(5) + handshake(4) + version(2) + random(32) + sessionID + ciphers + comp + extensions
func parseClientHello(b []byte) (*clientHelloInfo, bool) {
	if len(b) < 44 || b[0] != 0x16 || b[5] != 0x01 {
		return nil, false
	}
	c := &clientHelloInfo{version: binary.BigEndian.Uint16(b[9:11])}
	pos := 43
	sessionIDLen := int(b[pos])
	pos += 1 + sessionIDLen
	if pos+2 > len(b) {
		return nil, false
	}
	cipherLen := int(binary.BigEndian.Uint16(b[pos : pos+2]))
	pos += 2
	for i := 0; i+2 <= cipherLen && pos+2 <= len(b); i, pos = i+2, pos+2 {
		c.ciphers = append(c.ciphers, binary.BigEndian.Uint16(b[pos:pos+2]))
	}
	if pos+1 > len(b) {
		return nil, false
	}
	compLen := int(b[pos])
	pos += 1 + compLen
	if pos+2 > len(b) {
		return nil, false
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
		bodyStart := pos + 4
		bodyEnd := bodyStart + extLen
		if bodyEnd > end {
			bodyEnd = end
		}
		body := b[bodyStart:bodyEnd]
		c.exts = append(c.exts, extType)
		switch extType {
		case 0x0000: // server_name
			if len(body) >= 5 && body[2] == 0x00 { // listLen(2) + nameType(host_name)
				nameLen := int(binary.BigEndian.Uint16(body[3:5]))
				if 5+nameLen <= len(body) {
					c.sni = string(body[5 : 5+nameLen])
				}
			}
		case 0x000a: // supported_groups
			if len(body) >= 2 {
				listLen := int(binary.BigEndian.Uint16(body[0:2]))
				for i := 2; i+2 <= 2+listLen && i+2 <= len(body); i, _ = i+2, 0 {
					c.curves = append(c.curves, binary.BigEndian.Uint16(body[i:i+2]))
				}
			}
		case 0x000b: // ec_point_formats
			if len(body) >= 1 {
				listLen := int(body[0])
				for i := 1; i < 1+listLen && i < len(body); i++ {
					c.formats = append(c.formats, body[i])
				}
			}
		case 0x002b: // supported_versions：取最高非 GREASE/非草案版本（JA4 用）
			if len(body) >= 1 {
				listLen := int(body[0])
				for i := 1; i+2 <= 1+listLen && i+2 <= len(body); i += 2 {
					v := binary.BigEndian.Uint16(body[i : i+2])
					if !isGREASE(v) && v&0xff00 != 0x7f00 && v > c.tlsVer {
						c.tlsVer = v
					}
				}
			}
		case 0x000d: // signature_algorithms
			if len(body) >= 2 {
				listLen := int(binary.BigEndian.Uint16(body[0:2]))
				for i := 2; i+2 <= 2+listLen && i+2 <= len(body); i += 2 {
					c.sigAlgs = append(c.sigAlgs, binary.BigEndian.Uint16(body[i:i+2]))
				}
			}
		case 0x0010: // ALPN
			if len(body) >= 2 {
				listLen := int(binary.BigEndian.Uint16(body[0:2]))
				i := 2
				for i < listLen && i < len(body) {
					nameLen := int(body[i])
					i++
					if i+nameLen > len(body) {
						break
					}
					if c.alpn == "" && nameLen > 0 {
						c.alpn = string(body[i : i+nameLen])
					}
					i += nameLen
				}
			}
		}
		pos = bodyStart + extLen
	}
	return c, true
}

// JA3String salesforce/ja3 规范串（十进制逗号分隔）
func (c *clientHelloInfo) JA3String() string {
	u16s := func(v []uint16) string {
		parts := make([]string, len(v))
		for i, x := range v {
			parts[i] = fmt.Sprintf("%d", x)
		}
		return strings.Join(parts, "-")
	}
	b1 := make([]string, len(c.formats))
	for i, x := range c.formats {
		b1[i] = fmt.Sprintf("%d", x)
	}
	return strings.Join([]string{
		fmt.Sprintf("%d", c.version),
		u16s(c.ciphers),
		u16s(c.exts),
		u16s(c.curves),
		strings.Join(b1, "-"),
	}, ",")
}

// JA3 MD5(JA3String)
func (c *clientHelloInfo) JA3() string {
	sum := md5.Sum([]byte(c.JA3String()))
	return fmt.Sprintf("%x", sum)
}

// ja4TLSVersion 取协商 TLS 版本（supported_versions 最高值优先，否则 legacy_version）
func (c *clientHelloInfo) ja4TLSVersion() string {
	best := c.version
	if c.tlsVer != 0 {
		best = c.tlsVer
	}
	switch best {
	case 0x0304:
		return "13"
	case 0x0303:
		return "12"
	case 0x0302:
		return "11"
	case 0x0301:
		return "10"
	}
	return fmt.Sprintf("%x", best>>8&0xf) + fmt.Sprintf("%x", best&0xf)
}

// JA4 FoxIO JA4 指纹（TCP 场景前缀 't'）
// 格式：t<ver><d|i><cipher数2位><ext数2位><alpn>_<cipher哈希12>_<ext+sig哈希12>
func (c *clientHelloInfo) JA4() string {
	hex4 := func(v uint16) string { return fmt.Sprintf("%04x", v) }
	ciphers := make([]uint16, 0, len(c.ciphers))
	for _, x := range c.ciphers {
		if !isGREASE(x) {
			ciphers = append(ciphers, x)
		}
	}
	exts := make([]uint16, 0, len(c.exts))
	for _, x := range c.exts {
		if !isGREASE(x) && x != 0x0000 && x != 0x0010 { // 去除 GREASE/SNI/ALPN
			exts = append(exts, x)
		}
	}
	sort.Slice(ciphers, func(i, j int) bool { return ciphers[i] < ciphers[j] })
	sort.Slice(exts, func(i, j int) bool { return exts[i] < exts[j] })
	sig := make([]uint16, len(c.sigAlgs))
	copy(sig, c.sigAlgs)
	sort.Slice(sig, func(i, j int) bool { return sig[i] < sig[j] })

	sniFlag := "d"
	if c.sni == "" {
		sniFlag = "i"
	}
	alpnCode := "00"
	if c.alpn != "" {
		s := c.alpn
		if len(s) == 1 {
			alpnCode = s + "0"
		} else {
			alpnCode = s[:1] + s[len(s)-1:]
		}
	}
	segA := fmt.Sprintf("t%s%s%02d%02d%s", c.ja4TLSVersion(), sniFlag, len(ciphers), len(exts), alpnCode)

	ch := make([]string, len(ciphers))
	for i, x := range ciphers {
		ch[i] = hex4(x)
	}
	hB := sha256.Sum256([]byte(strings.Join(ch, ",")))
	segB := fmt.Sprintf("%x", hB[:])[:12]

	eh := make([]string, len(exts))
	for i, x := range exts {
		eh[i] = hex4(x)
	}
	sh := make([]string, len(sig))
	for i, x := range sig {
		sh[i] = hex4(x)
	}
	hC := sha256.Sum256([]byte(strings.Join(eh, ",") + "_" + strings.Join(sh, ",")))
	segC := fmt.Sprintf("%x", hC[:])[:12]

	return segA + "_" + segB + "_" + segC
}
