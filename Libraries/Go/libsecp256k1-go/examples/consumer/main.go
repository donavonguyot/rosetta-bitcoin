// A separate module using only the package's public API. Hex arguments are public data.
package main
import("encoding/hex";"fmt";"os"; secp "github.com/donavonguyot/rosetta-bitcoin/Libraries/Go/libsecp256k1-go")
func main(){
 if len(os.Args)!=5{panic("usage: consumer ecdsa|schnorr|tweak KEY MESSAGE_OR_TWEAK SIGNATURE")}
 var b [3][]byte;for i:=range b{var e error;b[i],e=hex.DecodeString(os.Args[i+2]);if e!=nil{panic(e)}}
 var ok bool;var err error
 switch os.Args[1]{case "ecdsa":ok,err=secp.VerifyECDSA(b[0],b[1],b[2]);case "schnorr":ok,err=secp.VerifySchnorr(b[0],b[1],b[2]);case "tweak":var r secp.TweakResult;r,err=secp.AddXOnlyTweak(b[0],b[1]);if err==nil{fmt.Printf("%x:%d\n",r.XOnly,r.Parity);return};default:panic("unknown operation")}
 if err!=nil{fmt.Println("malformed_input")}else if ok{fmt.Println("valid")}else{fmt.Println("consensus_invalid")}
}
