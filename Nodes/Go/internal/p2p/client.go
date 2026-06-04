package p2p

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"time"

	"rosettabitcoin/nodes/go/internal/refsync"
)

const (
	protocolVersion = int32(70016)
	services        = uint64(1 | 8) // NODE_NETWORK | NODE_WITNESS
	testnet4Magic   = uint32(0x283f161c)
	msgBlock        = uint32(2)
	msgWitnessBlock = uint32(1<<30) | msgBlock
	genesisHash     = "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043"
)

type FetchedBlock struct {
	Height int
	Hash   string
	Raw    []byte
	Info   refsync.BlockInfo
	Err    error
}

type FetchOptions struct {
	Peer     string
	Target   int
	Prefetch int
}

func FetchBlocks(opts FetchOptions) <-chan FetchedBlock {
	out := make(chan FetchedBlock, maxInt(1, opts.Prefetch))
	go func() {
		defer close(out)
		if opts.Target < 0 {
			out <- FetchedBlock{Err: errors.New("target must be >= 0")}
			return
		}
		prefetch := maxInt(1, opts.Prefetch)
		if prefetch > 64 {
			prefetch = 64
		}
		client, err := dial(opts.Peer)
		if err != nil {
			out <- FetchedBlock{Err: err}
			return
		}
		defer client.close()
		if err := client.handshake(); err != nil {
			out <- FetchedBlock{Err: err}
			return
		}
		hashes, err := client.headersThrough(opts.Target)
		if err != nil {
			out <- FetchedBlock{Err: err}
			return
		}
		for start := 0; start <= opts.Target; start += prefetch {
			end := minInt(opts.Target+1, start+prefetch)
			rawBlocks, err := client.requestBlocks(hashes[start:end])
			if err != nil {
				out <- FetchedBlock{Height: start, Err: err}
				return
			}
			for index, raw := range rawBlocks {
				height := start + index
				expectedHash := displayHash(hashes[height])
				expectedPrev := ""
				if height > 0 {
					expectedPrev = displayHash(hashes[height-1])
				}
				info, err := refsync.ValidateBlock(raw, expectedHash, expectedPrev)
				if err != nil {
					out <- FetchedBlock{Height: height, Err: err}
					return
				}
				out <- FetchedBlock{Height: height, Hash: info.Hash, Raw: raw, Info: info}
			}
		}
	}()
	return out
}

type client struct {
	conn net.Conn
}

type message struct {
	command string
	payload []byte
}

func dial(peer string) (*client, error) {
	host, port, err := splitPeer(peer)
	if err != nil {
		return nil, err
	}
	conn, err := net.DialTimeout("tcp", net.JoinHostPort(host, port), 30*time.Second)
	if err != nil {
		return nil, err
	}
	return &client{conn: conn}, nil
}

func splitPeer(peer string) (string, string, error) {
	host, port, err := net.SplitHostPort(peer)
	if err == nil {
		return host, port, nil
	}
	index := strings.LastIndex(peer, ":")
	if index <= 0 || index == len(peer)-1 {
		return "", "", fmt.Errorf("peer must be host:port, got %q", peer)
	}
	if _, err := strconv.Atoi(peer[index+1:]); err != nil {
		return "", "", fmt.Errorf("peer must be host:port, got %q", peer)
	}
	return peer[:index], peer[index+1:], nil
}

func (c *client) close() {
	_ = c.conn.Close()
}

func (c *client) handshake() error {
	if err := c.send("version", versionPayload()); err != nil {
		return err
	}
	seenVersion := false
	seenVerack := false
	deadline := time.Now().Add(30 * time.Second)
	for !seenVersion || !seenVerack {
		msg, err := c.readUntil(deadline)
		if err != nil {
			return err
		}
		switch msg.command {
		case "version":
			seenVersion = true
			if err := c.send("verack", nil); err != nil {
				return err
			}
		case "verack":
			seenVerack = true
		case "ping":
			if err := c.send("pong", msg.payload); err != nil {
				return err
			}
		}
	}
	return c.send("sendheaders", nil)
}

func (c *client) headersThrough(target int) ([][]byte, error) {
	hashes := [][]byte{hashFromDisplay(genesisHash)}
	for len(hashes)-1 < target {
		locator := hashes[len(hashes)-1]
		if err := c.send("getheaders", getHeadersPayload(locator)); err != nil {
			return nil, err
		}
		msg, err := c.readCommand("headers", 120*time.Second)
		if err != nil {
			return nil, err
		}
		headers, err := parseHeaders(msg.payload)
		if err != nil {
			return nil, err
		}
		if len(headers) == 0 {
			return nil, fmt.Errorf("peer returned no headers at height %d", len(hashes)-1)
		}
		for _, header := range headers {
			if len(hashes)-1 >= target {
				break
			}
			prev := header[4:36]
			if !bytes.Equal(prev, hashes[len(hashes)-1]) {
				return nil, fmt.Errorf("header prev mismatch at height %d", len(hashes))
			}
			hashes = append(hashes, doubleSHA(header))
		}
	}
	return hashes, nil
}

func (c *client) requestBlocks(hashes [][]byte) ([][]byte, error) {
	if len(hashes) == 0 {
		return nil, nil
	}
	if err := c.send("getdata", getDataPayload(hashes, msgWitnessBlock)); err != nil {
		return nil, err
	}
	result := make([][]byte, len(hashes))
	pending := map[string]int{}
	for index, hash := range hashes {
		pending[hex.EncodeToString(hash)] = index
	}
	deadline := time.Now().Add(120 * time.Second)
	for len(pending) > 0 {
		msg, err := c.readUntil(deadline)
		if err != nil {
			return nil, err
		}
		switch msg.command {
		case "block":
			hash := hex.EncodeToString(doubleSHA(msg.payload[:80]))
			index, ok := pending[hash]
			if !ok {
				continue
			}
			result[index] = msg.payload
			delete(pending, hash)
		case "notfound":
			return nil, errors.New("peer returned notfound for requested block")
		case "ping":
			if err := c.send("pong", msg.payload); err != nil {
				return nil, err
			}
		}
	}
	return result, nil
}

func (c *client) readCommand(command string, timeout time.Duration) (message, error) {
	deadline := time.Now().Add(timeout)
	for {
		msg, err := c.readUntil(deadline)
		if err != nil {
			return message{}, err
		}
		if msg.command == command {
			return msg, nil
		}
		if msg.command == "ping" {
			if err := c.send("pong", msg.payload); err != nil {
				return message{}, err
			}
		}
	}
}

func (c *client) readUntil(deadline time.Time) (message, error) {
	if err := c.conn.SetReadDeadline(deadline); err != nil {
		return message{}, err
	}
	header := make([]byte, 24)
	if _, err := io.ReadFull(c.conn, header); err != nil {
		return message{}, err
	}
	if binary.LittleEndian.Uint32(header[0:4]) != testnet4Magic {
		return message{}, errors.New("unexpected network magic")
	}
	command := strings.TrimRight(string(header[4:16]), "\x00")
	length := binary.LittleEndian.Uint32(header[16:20])
	checksum := header[20:24]
	payload := make([]byte, length)
	if _, err := io.ReadFull(c.conn, payload); err != nil {
		return message{}, err
	}
	if !bytes.Equal(messageChecksum(payload), checksum) {
		return message{}, fmt.Errorf("checksum mismatch for %s", command)
	}
	return message{command: command, payload: payload}, nil
}

func (c *client) send(command string, payload []byte) error {
	if payload == nil {
		payload = []byte{}
	}
	frame := make([]byte, 24+len(payload))
	binary.LittleEndian.PutUint32(frame[0:4], testnet4Magic)
	copy(frame[4:16], []byte(command))
	binary.LittleEndian.PutUint32(frame[16:20], uint32(len(payload)))
	copy(frame[20:24], messageChecksum(payload))
	copy(frame[24:], payload)
	_, err := c.conn.Write(frame)
	return err
}

func versionPayload() []byte {
	var out []byte
	out = appendInt32(out, protocolVersion)
	out = appendUint64(out, services)
	out = appendInt64(out, time.Now().Unix())
	out = appendNetAddr(out)
	out = appendNetAddr(out)
	out = appendUint64(out, uint64(time.Now().UnixNano()))
	out = appendVarBytes(out, []byte("/gobitnode:0.1.0/"))
	out = appendInt32(out, 0)
	out = append(out, 0)
	return out
}

func getHeadersPayload(locator []byte) []byte {
	var out []byte
	out = appendInt32(out, protocolVersion)
	out = appendVarInt(out, 1)
	out = append(out, locator...)
	out = append(out, make([]byte, 32)...)
	return out
}

func getDataPayload(hashes [][]byte, invType uint32) []byte {
	var out []byte
	out = appendVarInt(out, uint64(len(hashes)))
	for _, hash := range hashes {
		out = appendUint32(out, invType)
		out = append(out, hash...)
	}
	return out
}

func parseHeaders(payload []byte) ([][]byte, error) {
	count, offset, err := readVarInt(payload, 0)
	if err != nil {
		return nil, err
	}
	headers := make([][]byte, 0, count)
	for i := uint64(0); i < count; i++ {
		if offset+80 > len(payload) {
			return nil, errors.New("truncated headers payload")
		}
		header := append([]byte{}, payload[offset:offset+80]...)
		offset += 80
		txCount, next, err := readVarInt(payload, offset)
		if err != nil {
			return nil, err
		}
		if txCount != 0 {
			return nil, errors.New("headers message had nonzero tx count")
		}
		offset = next
		headers = append(headers, header)
	}
	return headers, nil
}

func appendNetAddr(out []byte) []byte {
	out = appendUint64(out, services)
	out = append(out, make([]byte, 10)...)
	out = append(out, 0xff, 0xff, 0, 0, 0, 0)
	return appendUint16BE(out, 0)
}

func appendVarBytes(out []byte, value []byte) []byte {
	out = appendVarInt(out, uint64(len(value)))
	return append(out, value...)
}

func appendVarInt(out []byte, value uint64) []byte {
	switch {
	case value < 0xfd:
		return append(out, byte(value))
	case value <= 0xffff:
		out = append(out, 0xfd)
		tmp := make([]byte, 2)
		binary.LittleEndian.PutUint16(tmp, uint16(value))
		return append(out, tmp...)
	case value <= 0xffffffff:
		out = append(out, 0xfe)
		tmp := make([]byte, 4)
		binary.LittleEndian.PutUint32(tmp, uint32(value))
		return append(out, tmp...)
	default:
		out = append(out, 0xff)
		tmp := make([]byte, 8)
		binary.LittleEndian.PutUint64(tmp, value)
		return append(out, tmp...)
	}
}

func readVarInt(data []byte, offset int) (uint64, int, error) {
	if offset >= len(data) {
		return 0, offset, errors.New("truncated varint")
	}
	first := data[offset]
	offset++
	switch first {
	case 0xfd:
		if offset+2 > len(data) {
			return 0, offset, errors.New("truncated varint16")
		}
		return uint64(binary.LittleEndian.Uint16(data[offset : offset+2])), offset + 2, nil
	case 0xfe:
		if offset+4 > len(data) {
			return 0, offset, errors.New("truncated varint32")
		}
		return uint64(binary.LittleEndian.Uint32(data[offset : offset+4])), offset + 4, nil
	case 0xff:
		if offset+8 > len(data) {
			return 0, offset, errors.New("truncated varint64")
		}
		return binary.LittleEndian.Uint64(data[offset : offset+8]), offset + 8, nil
	default:
		return uint64(first), offset, nil
	}
}

func appendInt32(out []byte, value int32) []byte {
	tmp := make([]byte, 4)
	binary.LittleEndian.PutUint32(tmp, uint32(value))
	return append(out, tmp...)
}

func appendInt64(out []byte, value int64) []byte {
	tmp := make([]byte, 8)
	binary.LittleEndian.PutUint64(tmp, uint64(value))
	return append(out, tmp...)
}

func appendUint16BE(out []byte, value uint16) []byte {
	tmp := make([]byte, 2)
	binary.BigEndian.PutUint16(tmp, value)
	return append(out, tmp...)
}

func appendUint32(out []byte, value uint32) []byte {
	tmp := make([]byte, 4)
	binary.LittleEndian.PutUint32(tmp, value)
	return append(out, tmp...)
}

func appendUint64(out []byte, value uint64) []byte {
	tmp := make([]byte, 8)
	binary.LittleEndian.PutUint64(tmp, value)
	return append(out, tmp...)
}

func doubleSHA(data []byte) []byte {
	first := sha256.Sum256(data)
	second := sha256.Sum256(first[:])
	return append([]byte{}, second[:]...)
}

func messageChecksum(payload []byte) []byte {
	return doubleSHA(payload)[:4]
}

func hashFromDisplay(value string) []byte {
	raw, _ := hex.DecodeString(value)
	for i, j := 0, len(raw)-1; i < j; i, j = i+1, j-1 {
		raw[i], raw[j] = raw[j], raw[i]
	}
	return raw
}

func displayHash(internal []byte) string {
	raw := append([]byte{}, internal...)
	for i, j := 0, len(raw)-1; i < j; i, j = i+1, j-1 {
		raw[i], raw[j] = raw[j], raw[i]
	}
	return hex.EncodeToString(raw)
}

func minInt(left, right int) int {
	if left < right {
		return left
	}
	return right
}

func maxInt(left, right int) int {
	if left > right {
		return left
	}
	return right
}
