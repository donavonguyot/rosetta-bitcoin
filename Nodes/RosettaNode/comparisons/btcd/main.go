// Evaluator-only comparison witness. Never package this in reconstruction arms.
package main
import("bufio";"bytes";"encoding/hex";"encoding/json";"fmt";"os";"github.com/btcsuite/btcd/wire")
type Request struct {Bytes string `json:"bytes"`; Mode string `json:"mode"`}
func main(){s:=bufio.NewScanner(os.Stdin);s.Buffer(make([]byte,4096),20*1024*1024);for s.Scan(){var q Request;r:=map[string]any{};err:=json.Unmarshal(s.Bytes(),&q);var b []byte;if err==nil {b,err=hex.DecodeString(q.Bytes)};if err==nil {reader:=bytes.NewReader(b);var tx wire.MsgTx;if q.Mode=="legacy" {err=tx.DeserializeNoWitness(reader)}else{err=tx.Deserialize(reader)};r["consumed"]=fmt.Sprint(len(b)-reader.Len());if err==nil{r["txid_display_order"]=tx.TxHash().String();r["wtxid_display_order"]=tx.WitnessHash().String()}};if err!=nil{r["status"]="error";r["error"]=err.Error()}else{r["status"]="ok"};json.NewEncoder(os.Stdout).Encode(r)}}
