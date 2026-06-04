package blocker

type Diagnostic struct {
	Implementation     string `json:"implementation"`
	Chain              string `json:"chain"`
	Height             int    `json:"height"`
	BlockHash          string `json:"block_hash"`
	TxID               string `json:"txid"`
	InputIndex         int    `json:"input_index"`
	PrevTxID           string `json:"prev_txid"`
	PrevVout           uint32 `json:"prev_vout"`
	SpentScriptPubKey  string `json:"spent_script_pubkey"`
	SpentValue         int64  `json:"spent_value"`
	SpentHeight        int    `json:"spent_height"`
	SpentCoinbase      bool   `json:"spent_coinbase"`
	Template           string `json:"template"`
	WitnessItemCount   int    `json:"witness_item_count"`
	TaprootSpendType   string `json:"taproot_spend_type"`
	TapscriptLength    int    `json:"tapscript_length"`
	ControlBlockLength int    `json:"control_block_length"`
	LeafVersion        string `json:"leaf_version"`
	Failure            string `json:"failure"`
	MissingRule        string `json:"missing_rule"`
	Source             string `json:"source"`
	RawJSONVersion     int    `json:"raw_json_version"`
}

func Empty(height, input int, txid string) Diagnostic {
	return Diagnostic{
		Implementation: "GoNode",
		Chain:          "testnet4",
		Height:         height,
		TxID:           txid,
		InputIndex:     input,
		MissingRule:    "not_inspected",
		RawJSONVersion: 1,
	}
}

func FromCurrent(current map[string]any, requestedHeight int, requestedInput int, requestedTxID string) Diagnostic {
	height := intFromAny(current["height"])
	txid := stringFromAny(current["txid"])
	input := intFromAny(current["input"])
	if requestedHeight != 0 && requestedHeight != height {
		return Empty(requestedHeight, requestedInput, requestedTxID)
	}
	if requestedTxID != "" && requestedTxID != txid {
		return Empty(requestedHeight, requestedInput, requestedTxID)
	}
	if requestedInput != 0 && requestedInput != input {
		return Empty(requestedHeight, requestedInput, requestedTxID)
	}
	script := stringFromAny(current["spent_script_pubkey"])
	return Diagnostic{
		Implementation:    "GoNode",
		Chain:             "testnet4",
		Height:            height,
		BlockHash:         stringFromAny(current["block_hash"]),
		TxID:              txid,
		InputIndex:        input,
		PrevTxID:          stringFromAny(current["prev_txid"]),
		PrevVout:          uint32(intFromAny(current["prev_vout"])),
		SpentScriptPubKey: script,
		SpentValue:        int64FromAny(current["spent_value"]),
		SpentHeight:       intFromAny(current["spent_height"]),
		SpentCoinbase:     boolFromAny(current["spent_coinbase"]),
		Template:          classify(script),
		Failure:           stringFromAny(current["failure"]),
		MissingRule:       stringFromAny(current["missing_rule"]),
		Source:            stringFromAny(current["source"]),
		RawJSONVersion:    1,
	}
}

func classify(script string) string {
	if len(script) == 44 && script[:4] == "0014" {
		return "p2wpkh"
	}
	if len(script) == 68 && script[:4] == "0020" {
		return "p2wsh"
	}
	if len(script) == 50 && script[:6] == "76a914" && script[46:] == "88ac" {
		return "p2pkh"
	}
	return "unknown"
}

func stringFromAny(value any) string {
	if s, ok := value.(string); ok {
		return s
	}
	return ""
}

func intFromAny(value any) int {
	switch v := value.(type) {
	case int:
		return v
	case int64:
		return int(v)
	case uint32:
		return int(v)
	case float64:
		return int(v)
	default:
		return 0
	}
}

func int64FromAny(value any) int64 {
	switch v := value.(type) {
	case int:
		return int64(v)
	case int64:
		return v
	case float64:
		return int64(v)
	default:
		return 0
	}
}

func boolFromAny(value any) bool {
	if b, ok := value.(bool); ok {
		return b
	}
	return false
}
