package refsync

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"sync/atomic"
)

type Client struct {
	URL      string
	User     string
	Password string
	counter  uint64
}

func (c *Client) Call(method string, params []any, out any) error {
	id := atomic.AddUint64(&c.counter, 1)
	payload, _ := json.Marshal(map[string]any{
		"jsonrpc": "1.0",
		"id":      id,
		"method":  method,
		"params":  params,
	})
	req, err := http.NewRequest(http.MethodPost, c.URL, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.SetBasicAuth(c.User, c.Password)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("rpc %s returned HTTP %s", method, resp.Status)
	}
	var envelope struct {
		Result json.RawMessage `json:"result"`
		Error  any             `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&envelope); err != nil {
		return err
	}
	if envelope.Error != nil {
		return fmt.Errorf("rpc %s error: %v", method, envelope.Error)
	}
	return json.Unmarshal(envelope.Result, out)
}

func (c *Client) BlockHash(height int) (string, error) {
	var hash string
	err := c.Call("getblockhash", []any{height}, &hash)
	return hash, err
}

func (c *Client) RawBlock(hash string) ([]byte, error) {
	var hexBlock string
	if err := c.Call("getblock", []any{hash, 0}, &hexBlock); err != nil {
		return nil, err
	}
	return hex.DecodeString(hexBlock)
}
