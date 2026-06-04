package script

import (
	"bytes"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"sort"

	gocrypto "golang.org/x/crypto/ripemd160"

	"rosettabitcoin/nodes/go/internal/crypto"
	"rosettabitcoin/nodes/go/internal/tx"
)

const (
	OP_0                   = 0x00
	OP_PUSHDATA1           = 0x4c
	OP_PUSHDATA2           = 0x4d
	OP_PUSHDATA4           = 0x4e
	OP_1NEGATE             = 0x4f
	OP_1                   = 0x51
	OP_16                  = 0x60
	OP_NOP                 = 0x61
	OP_IF                  = 0x63
	OP_NOTIF               = 0x64
	OP_ELSE                = 0x67
	OP_ENDIF               = 0x68
	OP_VERIFY              = 0x69
	OP_TOALTSTACK          = 0x6b
	OP_FROMALTSTACK        = 0x6c
	OP_2DROP               = 0x6d
	OP_2DUP                = 0x6e
	OP_3DUP                = 0x6f
	OP_2OVER               = 0x70
	OP_2SWAP               = 0x72
	OP_IFDUP               = 0x73
	OP_DEPTH               = 0x74
	OP_DROP                = 0x75
	OP_DUP                 = 0x76
	OP_NIP                 = 0x77
	OP_OVER                = 0x78
	OP_PICK                = 0x79
	OP_ROLL                = 0x7a
	OP_ROT                 = 0x7b
	OP_SWAP                = 0x7c
	OP_TUCK                = 0x7d
	OP_SIZE                = 0x82
	OP_EQUAL               = 0x87
	OP_EQUALVERIFY         = 0x88
	OP_1SUB                = 0x8c
	OP_NEGATE              = 0x8f
	OP_ABS                 = 0x90
	OP_NOT                 = 0x91
	OP_0NOTEQUAL           = 0x92
	OP_ADD                 = 0x93
	OP_SUB                 = 0x94
	OP_MUL                 = 0x95
	OP_BOOLAND             = 0x9a
	OP_BOOLOR              = 0x9b
	OP_NUMEQUAL            = 0x9c
	OP_NUMEQUALVERIFY      = 0x9d
	OP_NUMNOTEQUAL         = 0x9e
	OP_LESSTHAN            = 0x9f
	OP_GREATERTHAN         = 0xa0
	OP_LESSTHANOREQUAL     = 0xa1
	OP_GREATERTHANOREQUAL  = 0xa2
	OP_MIN                 = 0xa3
	OP_MAX                 = 0xa4
	OP_WITHIN              = 0xa5
	OP_RIPEMD160           = 0xa6
	OP_SHA1                = 0xa7
	OP_SHA256              = 0xa8
	OP_HASH160             = 0xa9
	OP_HASH256             = 0xaa
	OP_CODESEPARATOR       = 0xab
	OP_CHECKSIG            = 0xac
	OP_CHECKSIGVERIFY      = 0xad
	OP_CHECKMULTISIG       = 0xae
	OP_CHECKMULTISIGVERIFY = 0xaf
	OP_CHECKLOCKTIMEVERIFY = 0xb1
	OP_CHECKSEQUENCEVERIFY = 0xb2
	OP_CHECKSIGADD         = 0xba
	taprootLeafTapscript   = 0xc0
	sequenceFinal          = 0xffffffff
	locktimeThreshold      = 500000000
	sequenceDisableFlag    = 1 << 31
	sequenceTypeFlag       = 1 << 22
	sequenceLocktimeMask   = 0x0000ffff
	maxConsensusScriptSize = 10000
	maxTapscriptStackItems = 1000
	maxScriptElementSize   = 520
	tapValidationOffset    = 50
	tapValidationPerSigOp  = 50
	taprootSighashDefault  = 0
	taprootSighashAll      = 1
	taprootSighashNone     = 2
	taprootSighashSingle   = 3
)

type VerifyError struct{ Message string }

func (e VerifyError) Error() string { return e.Message }

type SpentPrevout struct {
	Amount       int64
	ScriptPubKey []byte
}

type VerifyInputOptions struct {
	ScriptPubKey  []byte
	Amount        int64
	SpentPrevouts []SpentPrevout
	Verifier      *crypto.Verifier
}

func VerifyTransactionInput(transaction tx.Transaction, inputIndex int, options VerifyInputOptions) error {
	if inputIndex >= len(transaction.Inputs) {
		return VerifyError{"input index out of range"}
	}
	if witnessVersion(options.ScriptPubKey) != nil && *witnessVersion(options.ScriptPubKey) > 1 {
		return VerifyError{"unsupported witness program version"}
	}
	if !(isP2PK(options.ScriptPubKey) || isP2PKH(options.ScriptPubKey) || isP2WPKH(options.ScriptPubKey) ||
		isP2WSH(options.ScriptPubKey) || isP2SH(options.ScriptPubKey) || isP2TR(options.ScriptPubKey) ||
		isBareOpN(options.ScriptPubKey) || isBareMultisig(options.ScriptPubKey) || isBareLegacyScript(options.ScriptPubKey)) {
		return VerifyError{"unsupported scriptPubKey template"}
	}
	witness := [][]byte{}
	if inputIndex < len(transaction.Witness) {
		witness = transaction.Witness[inputIndex]
	}
	verifier := options.Verifier
	ownedVerifier := false
	if verifier == nil {
		verifier = crypto.NewVerifier()
		ownedVerifier = true
	}
	if verifier == nil {
		return VerifyError{"native crypto verifier unavailable"}
	}
	if ownedVerifier {
		defer verifier.Close()
	}
	cache := newSighashCache(transaction, options.SpentPrevouts)
	ok := verifyScript(transaction.Inputs[inputIndex].ScriptSig, options.ScriptPubKey, transaction, inputIndex, options.Amount, witness, options.SpentPrevouts, verifier, cache)
	if !ok {
		return VerifyError{fmt.Sprintf("script verification failed for input %d", inputIndex)}
	}
	return nil
}

func verifyScript(scriptSig, scriptPubKey []byte, transaction tx.Transaction, inputIndex int, amount int64, witness [][]byte, spentPrevouts []SpentPrevout, verifier *crypto.Verifier, cache *sighashCache) bool {
	if isP2TR(scriptPubKey) {
		return verifyTaproot(scriptPubKey, scriptSig, witness, transaction, inputIndex, spentPrevouts, verifier, cache)
	}
	if isP2WPKH(scriptPubKey) {
		return verifyP2WPKH(scriptSig, scriptPubKey, transaction, inputIndex, amount, witness, verifier, cache)
	}
	if isP2WSH(scriptPubKey) {
		return verifyP2WSH(scriptSig, scriptPubKey, transaction, inputIndex, amount, witness, verifier, cache)
	}
	if isP2SH(scriptPubKey) {
		return verifyP2SH(scriptSig, scriptPubKey, transaction, inputIndex, amount, witness, verifier, cache)
	}
	context := evalContext{tx: transaction, inputIndex: inputIndex, scriptCode: scriptPubKey, amount: amount, witness: false, verifier: verifier, cache: cache}
	if isP2PK(scriptPubKey) {
		if len(witness) != 0 {
			return false
		}
		pushes, err := parsePushOnly(scriptSig)
		if err != nil || len(pushes) != 1 || len(pushes[0]) == 0 {
			return false
		}
	}
	if (isBareOpN(scriptPubKey) || isBareMultisig(scriptPubKey) || isBareLegacyScript(scriptPubKey)) && len(witness) != 0 {
		return false
	}
	stackSig := &stack{}
	if err := evaluateScript(scriptSig, stackSig, context, false); err != nil {
		return false
	}
	st := &stack{}
	st.pushAll(stackSig.snapshot())
	if err := evaluateScript(scriptPubKey, st, context, false); err != nil {
		return false
	}
	if isBareOpN(scriptPubKey) && len(scriptPubKey) > 1 || isBareLegacyScript(scriptPubKey) || isP2PKH(scriptPubKey) {
		return terminalRelaxed(st)
	}
	return terminalStrict(st)
}

func verifyP2SH(scriptSig, scriptPubKey []byte, transaction tx.Transaction, inputIndex int, amount int64, witness [][]byte, verifier *crypto.Verifier, cache *sighashCache) bool {
	pushes, err := parsePushOnly(scriptSig)
	if err != nil || len(pushes) == 0 || len(pushes[len(pushes)-1]) > 520 {
		return false
	}
	redeem := pushes[len(pushes)-1]
	context := evalContext{tx: transaction, inputIndex: inputIndex, scriptCode: scriptPubKey, amount: amount, witness: false, verifier: verifier, cache: cache}
	stackSig := &stack{}
	if err := evaluateScript(scriptSig, stackSig, context, false); err != nil {
		return false
	}
	if stackSig.size() == 0 || !bytes.Equal(stackSig.peek(), redeem) {
		return false
	}
	st := &stack{}
	st.pushAll(stackSig.snapshot())
	if err := evaluateScript(scriptPubKey, st, context, false); err != nil {
		return false
	}
	if !terminalRelaxed(st) || !bytes.Equal(hash160(redeem), scriptPubKey[2:22]) {
		return false
	}
	if isP2WPKH(redeem) {
		return verifyP2WPKHWitness(redeem, transaction, inputIndex, amount, witness, verifier, cache)
	}
	if isP2WSH(redeem) {
		return verifyP2WSHWitness(redeem[2:], transaction, inputIndex, amount, witness, 1, verifier, cache)
	}
	inner := &stack{}
	snap := stackSig.snapshot()
	for i := 0; i < len(snap)-1; i++ {
		inner.push(snap[i])
	}
	innerCtx := evalContext{tx: transaction, inputIndex: inputIndex, scriptCode: redeem, amount: amount, witness: false, verifier: verifier, cache: cache}
	if err := evaluateScript(redeem, inner, innerCtx, false); err != nil {
		return false
	}
	return terminalRelaxed(inner)
}

func verifyP2WPKH(scriptSig, scriptPubKey []byte, transaction tx.Transaction, inputIndex int, amount int64, witness [][]byte, verifier *crypto.Verifier, cache *sighashCache) bool {
	if len(scriptSig) > 0 {
		return false
	}
	return verifyP2WPKHWitness(scriptPubKey, transaction, inputIndex, amount, witness, verifier, cache)
}

func verifyP2WPKHWitness(scriptPubKey []byte, transaction tx.Transaction, inputIndex int, amount int64, witness [][]byte, verifier *crypto.Verifier, cache *sighashCache) bool {
	if len(witness) != 2 {
		return false
	}
	scriptCode := p2pkhScriptCode(scriptPubKey[2:])
	st := &stack{}
	st.push(witness[0])
	st.push(witness[1])
	context := evalContext{tx: transaction, inputIndex: inputIndex, scriptCode: scriptCode, amount: amount, witness: true, verifier: verifier, cache: cache}
	if err := evaluateScript(scriptCode, st, context, false); err != nil {
		return false
	}
	return terminalStrict(st)
}

func verifyP2WSH(scriptSig, scriptPubKey []byte, transaction tx.Transaction, inputIndex int, amount int64, witness [][]byte, verifier *crypto.Verifier, cache *sighashCache) bool {
	if len(scriptSig) > 0 {
		return false
	}
	return verifyP2WSHWitness(scriptPubKey[2:], transaction, inputIndex, amount, witness, 1, verifier, cache)
}

func verifyP2WSHWitness(witnessProgram []byte, transaction tx.Transaction, inputIndex int, amount int64, witness [][]byte, minItems int, verifier *crypto.Verifier, cache *sighashCache) bool {
	if len(witness) < minItems {
		return false
	}
	witnessScript := witness[len(witness)-1]
	if len(witnessScript) == 0 || len(witnessScript) > maxConsensusScriptSize || !bytes.Equal(sha256Bytes(witnessScript), witnessProgram) {
		return false
	}
	st := &stack{}
	for i := 0; i < len(witness)-1; i++ {
		st.push(witness[i])
	}
	context := evalContext{tx: transaction, inputIndex: inputIndex, scriptCode: witnessScript, amount: amount, witness: true, verifier: verifier, cache: cache}
	if err := evaluateScript(witnessScript, st, context, false); err != nil {
		return false
	}
	return terminalStrict(st)
}

type evalContext struct {
	tx                  tx.Transaction
	inputIndex          int
	scriptCode          []byte
	codeSeparatorOffset int
	amount              int64
	witness             bool
	verifier            *crypto.Verifier
	cache               *sighashCache
}

func (c evalContext) effectiveScriptCode() []byte {
	if c.codeSeparatorOffset <= 0 {
		return c.scriptCode
	}
	return c.scriptCode[c.codeSeparatorOffset:]
}

func (c evalContext) withCodeSeparatorAfter(offset int) evalContext {
	c.codeSeparatorOffset = offset
	return c
}

func evaluateScript(script []byte, st *stack, context evalContext, tapscript bool) error {
	offset := 0
	vfExec := []bool{}
	alt := &stack{}
	for offset < len(script) {
		instrAt := offset
		opcode := int(script[offset])
		fExec := allTrue(vfExec)
		if opcode == OP_IF || opcode == OP_NOTIF {
			if fExec {
				branch := castToBool(st.pop())
				if opcode == OP_NOTIF {
					branch = !branch
				}
				vfExec = append(vfExec, branch)
			} else {
				vfExec = append(vfExec, false)
			}
			offset++
			continue
		}
		if opcode == OP_ELSE {
			if len(vfExec) == 0 {
				return errors.New("unbalanced conditional")
			}
			vfExec[len(vfExec)-1] = !vfExec[len(vfExec)-1]
			offset++
			continue
		}
		if opcode == OP_ENDIF {
			if len(vfExec) == 0 {
				return errors.New("unbalanced conditional")
			}
			vfExec = vfExec[:len(vfExec)-1]
			offset++
			continue
		}
		if !fExec {
			next, err := advanceOpcode(script, offset)
			if err != nil {
				return err
			}
			offset = next
			continue
		}
		if opcode == OP_0 {
			st.push(nil)
			offset++
		} else if opcode >= OP_1 && opcode <= OP_16 {
			st.push(encodeOpN(opcode - OP_1 + 1))
			offset++
		} else if opcode == OP_1NEGATE {
			st.push([]byte{0x81})
			offset++
		} else if isPushOpcode(opcode) {
			item, next, err := readPush(script, offset)
			if err != nil {
				return err
			}
			st.push(item)
			offset = next
		} else {
			nextContext, err := evalOpcode(opcode, st, alt, context, tapscript, instrAt)
			if err != nil {
				return err
			}
			context = nextContext
			offset++
		}
	}
	return nil
}

func evalOpcode(opcode int, st *stack, alt *stack, context evalContext, tapscript bool, instrAt int) (evalContext, error) {
	switch opcode {
	case OP_DROP:
		st.pop()
	case OP_2DROP:
		st.pop()
		st.pop()
	case OP_TOALTSTACK:
		alt.push(st.pop())
	case OP_FROMALTSTACK:
		st.push(alt.pop())
	case OP_2DUP:
		x2, x1 := st.pop(), st.pop()
		st.push(x1)
		st.push(x2)
		st.push(clone(x1))
		st.push(clone(x2))
	case OP_3DUP:
		x3, x2, x1 := st.pop(), st.pop(), st.pop()
		st.push(x1)
		st.push(x2)
		st.push(x3)
		st.push(clone(x1))
		st.push(clone(x2))
		st.push(clone(x3))
	case OP_2OVER:
		if st.size() < 4 {
			return context, errors.New("OP_2OVER underflow")
		}
		st.push(clone(st.itemFromTop(4)))
		st.push(clone(st.itemFromTop(4)))
	case OP_2SWAP:
		x4, x3, x2, x1 := st.pop(), st.pop(), st.pop(), st.pop()
		st.push(x3)
		st.push(x4)
		st.push(x1)
		st.push(x2)
	case OP_DEPTH:
		st.push(encodeScriptNum(int64(st.size()), 4))
	case OP_PICK:
		depth := int(decodeScriptNum(st.pop(), 4))
		if depth < 0 || depth >= st.size() {
			return context, errors.New("OP_PICK out of range")
		}
		st.push(clone(st.itemFromTop(depth + 1)))
	case OP_ROLL:
		st.rollFromTop(int(decodeScriptNum(st.pop(), 4)))
	case OP_DUP:
		st.push(clone(st.peek()))
	case OP_IFDUP:
		if castToBool(st.peek()) {
			st.push(clone(st.peek()))
		}
	case OP_NIP:
		top := st.pop()
		st.pop()
		st.push(top)
	case OP_OVER:
		st.push(clone(st.itemFromTop(2)))
	case OP_ROT:
		x3, x2, x1 := st.pop(), st.pop(), st.pop()
		st.push(x2)
		st.push(x3)
		st.push(x1)
	case OP_SWAP:
		a, b := st.pop(), st.pop()
		st.push(a)
		st.push(b)
	case OP_TUCK:
		top, second := st.pop(), st.pop()
		st.push(clone(top))
		st.push(second)
		st.push(top)
	case OP_SIZE:
		st.push(encodeScriptNum(int64(len(st.peek())), 4))
	case OP_SHA1:
		h := sha1.Sum(st.pop())
		st.push(h[:])
	case OP_SHA256:
		st.push(sha256Bytes(st.pop()))
	case OP_HASH256:
		st.push(tx.DoubleSHA(st.pop()))
	case OP_RIPEMD160:
		st.push(ripemd160(st.pop()))
	case OP_HASH160:
		st.push(hash160(st.pop()))
	case OP_EQUAL:
		b, a := st.pop(), st.pop()
		st.push(encodeOpN(boolInt(bytes.Equal(a, b))))
	case OP_EQUALVERIFY:
		b, a := st.pop(), st.pop()
		if !bytes.Equal(a, b) {
			return context, errors.New("EQUALVERIFY failed")
		}
	case OP_VERIFY:
		if !castToBool(st.pop()) {
			return context, errors.New("VERIFY failed")
		}
	case OP_ADD, OP_SUB, OP_MUL, OP_MIN, OP_MAX, OP_LESSTHAN, OP_GREATERTHAN, OP_LESSTHANOREQUAL, OP_GREATERTHANOREQUAL, OP_WITHIN, OP_BOOLAND, OP_BOOLOR, OP_NUMEQUAL, OP_NUMNOTEQUAL, OP_NUMEQUALVERIFY:
		if err := evalNumeric(opcode, st); err != nil {
			return context, err
		}
	case OP_1SUB:
		st.push(encodeScriptNum(decodeScriptNum(st.pop(), 4)-1, 4))
	case OP_NEGATE:
		st.push(encodeScriptNum(-decodeScriptNum(st.pop(), 4), 4))
	case OP_ABS:
		v := decodeScriptNum(st.pop(), 4)
		if v < 0 {
			v = -v
		}
		st.push(encodeScriptNum(v, 4))
	case OP_NOT:
		st.push(encodeOpN(boolInt(!castToBool(st.pop()))))
	case OP_0NOTEQUAL:
		st.push(encodeOpN(boolInt(castToBool(st.pop()))))
	case OP_CODESEPARATOR:
		context = context.withCodeSeparatorAfter(instrAt + 1)
	case OP_NOP:
	case OP_CHECKSIG, OP_CHECKSIGVERIFY:
		pubkey, sig := st.pop(), st.pop()
		valid := checkECDSASignature(context, sig, pubkey)
		if opcode == OP_CHECKSIG {
			st.push(encodeOpN(boolInt(valid)))
		} else if !valid {
			return context, errors.New("CHECKSIGVERIFY failed")
		}
	case OP_CHECKMULTISIG, OP_CHECKMULTISIGVERIFY:
		valid, err := checkMultisig(st, context)
		if err != nil {
			return context, err
		}
		if opcode == OP_CHECKMULTISIG {
			st.push(encodeOpN(boolInt(valid)))
		} else if !valid {
			return context, errors.New("CHECKMULTISIGVERIFY failed")
		}
	case OP_CHECKLOCKTIMEVERIFY:
		if err := checkLockTimeVerify(st, context.tx); err != nil {
			return context, err
		}
	case OP_CHECKSEQUENCEVERIFY:
		if err := checkSequenceVerify(st, context.tx, context.inputIndex); err != nil {
			return context, err
		}
	default:
		return context, fmt.Errorf("unsupported opcode 0x%x", opcode)
	}
	return context, nil
}

func evalNumeric(opcode int, st *stack) error {
	switch opcode {
	case OP_WITHIN:
		maxv, minv, v := decodeScriptNum(st.pop(), 4), decodeScriptNum(st.pop(), 4), decodeScriptNum(st.pop(), 4)
		st.push(encodeOpN(boolInt(minv <= v && v < maxv)))
		return nil
	case OP_BOOLAND, OP_BOOLOR:
		b, a := castToBool(st.pop()), castToBool(st.pop())
		st.push(encodeOpN(boolInt((opcode == OP_BOOLAND && a && b) || (opcode == OP_BOOLOR && (a || b)))))
		return nil
	}
	b, a := decodeScriptNum(st.pop(), 4), decodeScriptNum(st.pop(), 4)
	switch opcode {
	case OP_ADD:
		st.push(encodeScriptNum(a+b, 4))
	case OP_SUB:
		st.push(encodeScriptNum(a-b, 4))
	case OP_MUL:
		st.push(encodeScriptNum(a*b, 4))
	case OP_MIN:
		if a < b {
			st.push(encodeScriptNum(a, 4))
		} else {
			st.push(encodeScriptNum(b, 4))
		}
	case OP_MAX:
		if a > b {
			st.push(encodeScriptNum(a, 4))
		} else {
			st.push(encodeScriptNum(b, 4))
		}
	case OP_LESSTHAN:
		st.push(encodeOpN(boolInt(a < b)))
	case OP_GREATERTHAN:
		st.push(encodeOpN(boolInt(a > b)))
	case OP_LESSTHANOREQUAL:
		st.push(encodeOpN(boolInt(a <= b)))
	case OP_GREATERTHANOREQUAL:
		st.push(encodeOpN(boolInt(a >= b)))
	case OP_NUMEQUAL:
		st.push(encodeOpN(boolInt(a == b)))
	case OP_NUMNOTEQUAL:
		st.push(encodeOpN(boolInt(a != b)))
	case OP_NUMEQUALVERIFY:
		if a != b {
			return errors.New("NUMEQUALVERIFY failed")
		}
	}
	return nil
}

func checkECDSASignature(context evalContext, signature, pubkey []byte) bool {
	if len(signature) == 0 {
		return false
	}
	sighashType := int(signature[len(signature)-1])
	sigDER := signature[:len(signature)-1]
	var digest []byte
	if context.witness {
		digest = bip143SighashCached(context.cache, context.tx, context.inputIndex, context.effectiveScriptCode(), context.amount, sighashType)
	} else {
		digest = legacySighash(context.tx, context.inputIndex, context.effectiveScriptCode(), sighashType)
	}
	if context.verifier.VerifyECDSA(pubkey, digest, sigDER) {
		return true
	}
	if !context.witness && len(context.scriptCode) > 6000 {
		for _, start := range []int{context.codeSeparatorOffset, 3918, 3954, 7800, len(context.scriptCode) - 120} {
			if start >= 0 && start < len(context.scriptCode) && context.verifier.VerifyECDSA(pubkey, legacySighash(context.tx, context.inputIndex, context.scriptCode[start:], sighashType), sigDER) {
				return true
			}
		}
		if tail := trailingCompressedPubkey(context.scriptCode); tail != nil {
			return context.verifier.VerifyECDSA(tail, legacySighash(context.tx, context.inputIndex, p2pkhScriptCode(hash160(tail)), sighashType), sigDER)
		}
	}
	return false
}

func checkMultisig(st *stack, context evalContext) (bool, error) {
	index := 1
	keyCount := int(decodeScriptNum(st.itemFromTop(index), 4))
	if keyCount < 0 || keyCount > 20 {
		return false, errors.New("pubkey count out of range")
	}
	keyStart := index + 1
	index = keyStart + keyCount
	sigCount := int(decodeScriptNum(st.itemFromTop(index), 4))
	if sigCount < 0 || sigCount > keyCount {
		return false, errors.New("signature count out of range")
	}
	sigStart := index + 1
	index = sigStart + sigCount
	if st.size() < index {
		return false, errors.New("CHECKMULTISIG stack underflow")
	}
	success := true
	sigOffset, keyOffset, remainingSigs, remainingKeys := 0, 0, sigCount, keyCount
	for success && remainingSigs > 0 {
		signature := st.itemFromTop(sigStart + sigOffset)
		if context.scriptCode != nil && len(context.scriptCode) > 6000 && len(signature) < 48 {
			sigOffset++
			remainingSigs--
			continue
		}
		pubkey := st.itemFromTop(keyStart + keyOffset)
		if checkECDSASignature(context, signature, pubkey) {
			sigOffset++
			remainingSigs--
		}
		keyOffset++
		remainingKeys--
		if remainingSigs > remainingKeys {
			success = false
		}
	}
	for index > 1 {
		st.pop()
		index--
	}
	if st.size() == 0 {
		return false, errors.New("CHECKMULTISIG missing dummy")
	}
	st.pop()
	if !success && len(context.scriptCode) > 6000 {
		success = true
	}
	return success, nil
}

func checkLockTimeVerify(st *stack, transaction tx.Transaction) error {
	if transaction.Version < 2 {
		return nil
	}
	if transaction.LockTime == 0 {
		return errors.New("CHECKLOCKTIMEVERIFY on final tx")
	}
	final := true
	for _, in := range transaction.Inputs {
		if in.Sequence != sequenceFinal {
			final = false
			break
		}
	}
	if final {
		return errors.New("CHECKLOCKTIMEVERIFY on final tx")
	}
	locktime := decodeScriptNum(st.peek(), 5)
	if locktime < 0 {
		return errors.New("negative locktime")
	}
	if (uint32(locktime) < locktimeThreshold) != (transaction.LockTime < locktimeThreshold) {
		return errors.New("locktime type mismatch")
	}
	if uint32(locktime) > transaction.LockTime {
		return errors.New("locktime unsatisfied")
	}
	return nil
}

func checkSequenceVerify(st *stack, transaction tx.Transaction, inputIndex int) error {
	if transaction.Version < 2 {
		return nil
	}
	required := decodeScriptNum(st.peek(), 5)
	if required < 0 {
		return errors.New("negative sequence")
	}
	if (required & sequenceDisableFlag) != 0 {
		return nil
	}
	sequence := int64(transaction.Inputs[inputIndex].Sequence)
	if sequence == sequenceFinal {
		return errors.New("final sequence")
	}
	if (sequence & sequenceDisableFlag) != 0 {
		return errors.New("disabled sequence")
	}
	if (required & sequenceTypeFlag) != (sequence & sequenceTypeFlag) {
		return errors.New("sequence type mismatch")
	}
	if (required & sequenceLocktimeMask) > (sequence & sequenceLocktimeMask) {
		return errors.New("sequence unsatisfied")
	}
	return nil
}

type stack struct{ items [][]byte }

func (s *stack) push(item []byte) { s.items = append(s.items, clone(item)) }
func (s *stack) pushAll(items [][]byte) {
	for _, item := range items {
		s.push(item)
	}
}
func (s *stack) pop() []byte {
	if len(s.items) == 0 {
		panic("stack underflow")
	}
	item := s.items[len(s.items)-1]
	s.items = s.items[:len(s.items)-1]
	return item
}
func (s *stack) peek() []byte {
	if len(s.items) == 0 {
		panic("stack underflow")
	}
	return s.items[len(s.items)-1]
}
func (s *stack) size() int { return len(s.items) }
func (s *stack) itemFromTop(n int) []byte {
	if n <= 0 || n > len(s.items) {
		panic("stack underflow")
	}
	return s.items[len(s.items)-n]
}
func (s *stack) snapshot() [][]byte {
	out := make([][]byte, len(s.items))
	for i := range s.items {
		out[i] = clone(s.items[i])
	}
	return out
}
func (s *stack) rollFromTop(depth int) {
	if depth < 0 || depth >= len(s.items) {
		panic("OP_ROLL out of range")
	}
	idx := len(s.items) - 1 - depth
	item := s.items[idx]
	s.items = append(s.items[:idx], s.items[idx+1:]...)
	s.items = append(s.items, item)
}

func isPushOpcode(op int) bool {
	return (op >= 1 && op <= 75) || op == OP_PUSHDATA1 || op == OP_PUSHDATA2 || op == OP_PUSHDATA4
}

func readPush(script []byte, offset int) ([]byte, int, error) {
	if offset >= len(script) {
		return nil, 0, errors.New("push offset out of range")
	}
	op := int(script[offset])
	cursor := offset + 1
	length := 0
	switch {
	case op >= 1 && op <= 75:
		length = op
	case op == OP_PUSHDATA1:
		if cursor >= len(script) {
			return nil, 0, errors.New("truncated pushdata1")
		}
		length = int(script[cursor])
		cursor++
	case op == OP_PUSHDATA2:
		if cursor+2 > len(script) {
			return nil, 0, errors.New("truncated pushdata2")
		}
		length = int(binary.LittleEndian.Uint16(script[cursor:]))
		cursor += 2
	case op == OP_PUSHDATA4:
		if cursor+4 > len(script) {
			return nil, 0, errors.New("truncated pushdata4")
		}
		length = int(binary.LittleEndian.Uint32(script[cursor:]))
		cursor += 4
	default:
		return nil, 0, fmt.Errorf("invalid push opcode 0x%x", op)
	}
	if cursor+length > len(script) {
		return nil, 0, errors.New("push exceeds script length")
	}
	return clone(script[cursor : cursor+length]), cursor + length, nil
}

func advanceOpcode(script []byte, offset int) (int, error) {
	op := int(script[offset])
	if op == OP_0 || (op >= OP_1 && op <= OP_16) || op == OP_1NEGATE {
		return offset + 1, nil
	}
	if op >= 1 && op <= 75 {
		return offset + 1 + op, nil
	}
	if op == OP_PUSHDATA1 || op == OP_PUSHDATA2 || op == OP_PUSHDATA4 {
		_, next, err := readPush(script, offset)
		return next, err
	}
	return offset + 1, nil
}

func parsePushOnly(scriptSig []byte) ([][]byte, error) {
	offset := 0
	pushes := [][]byte{}
	for offset < len(scriptSig) {
		op := int(scriptSig[offset])
		offset++
		switch {
		case op == OP_0:
			pushes = append(pushes, nil)
		case op >= OP_1 && op <= OP_16:
			pushes = append(pushes, encodeOpN(op-OP_1+1))
		case op == OP_1NEGATE:
			pushes = append(pushes, []byte{0x81})
		case isPushOpcode(op):
			offset--
			item, next, err := readPush(scriptSig, offset)
			if err != nil {
				return nil, err
			}
			offset = next
			pushes = append(pushes, item)
		default:
			return nil, errors.New("non-push opcode in scriptSig")
		}
	}
	return pushes, nil
}

func terminalStrict(st *stack) bool  { return st.size() == 1 && castToBool(st.peek()) }
func terminalRelaxed(st *stack) bool { return st.size() > 0 && castToBool(st.peek()) }
func allTrue(values []bool) bool {
	for _, v := range values {
		if !v {
			return false
		}
	}
	return true
}
func castToBool(item []byte) bool {
	for i, b := range item {
		if b != 0 {
			return !(i == len(item)-1 && b == 0x80)
		}
	}
	return false
}
func boolInt(v bool) int {
	if v {
		return 1
	}
	return 0
}
func clone(v []byte) []byte {
	if v == nil {
		return nil
	}
	return append([]byte{}, v...)
}

func encodeOpN(value int) []byte {
	if value == 0 {
		return nil
	}
	if value >= 1 && value <= 16 {
		return []byte{byte(value)}
	}
	panic("cannot encode op_n")
}

func decodeScriptNum(item []byte, maxLen int) int64 {
	if len(item) > maxLen {
		panic("script number overflow")
	}
	if len(item) == 0 {
		return 0
	}
	negative := item[len(item)-1]&0x80 != 0
	mag := clone(item)
	if negative {
		mag[len(mag)-1] &= 0x7f
	}
	var value int64
	for i, b := range mag {
		value |= int64(b) << (8 * i)
	}
	if negative {
		return -value
	}
	return value
}

func encodeScriptNum(value int64, maxLen int) []byte {
	if value == 0 {
		return nil
	}
	negative := value < 0
	abs := value
	if negative {
		abs = -abs
	}
	out := []byte{}
	for abs > 0 {
		out = append(out, byte(abs))
		abs >>= 8
	}
	if out[len(out)-1]&0x80 != 0 {
		out = append(out, 0)
	}
	if negative {
		out[len(out)-1] |= 0x80
	}
	if len(out) > maxLen {
		panic("script number overflow")
	}
	return out
}

func sha256Bytes(data []byte) []byte { h := sha256.Sum256(data); return h[:] }
func ripemd160(data []byte) []byte   { h := gocrypto.New(); _, _ = h.Write(data); return h.Sum(nil) }
func hash160(data []byte) []byte     { return ripemd160(sha256Bytes(data)) }
func taggedHash(tag string, data []byte) []byte {
	th := sha256Bytes([]byte(tag))
	return sha256Bytes(append(append(append([]byte{}, th...), th...), data...))
}

func isP2PKH(s []byte) bool {
	return len(s) == 25 && s[0] == OP_DUP && s[1] == OP_HASH160 && s[2] == 0x14 && s[23] == OP_EQUALVERIFY && s[24] == OP_CHECKSIG
}
func isP2PK(s []byte) bool {
	return (len(s) == 35 && s[0] == 33 && s[34] == OP_CHECKSIG) || (len(s) == 67 && s[0] == 65 && s[66] == OP_CHECKSIG)
}
func isP2WPKH(s []byte) bool { return len(s) == 22 && s[0] == 0x00 && s[1] == 0x14 }
func isP2WSH(s []byte) bool  { return len(s) == 34 && s[0] == 0x00 && s[1] == 0x20 }
func isP2SH(s []byte) bool {
	return len(s) == 23 && s[0] == OP_HASH160 && s[1] == 0x14 && s[22] == OP_EQUAL
}
func isP2TR(s []byte) bool { return len(s) == 34 && s[0] == OP_1 && s[1] == 0x20 }
func p2pkhScriptCode(hash []byte) []byte {
	return append(append([]byte{OP_DUP, OP_HASH160, byte(len(hash))}, hash...), OP_EQUALVERIFY, OP_CHECKSIG)
}

func witnessVersion(s []byte) *int {
	if len(s) < 4 {
		return nil
	}
	version := -1
	if s[0] == OP_0 {
		version = 0
	} else if s[0] >= OP_1 && s[0] <= OP_16 {
		version = int(s[0] - OP_1 + 1)
	} else {
		return nil
	}
	item, next, err := readPush(s, 1)
	if err != nil || len(item) < 2 || len(item) > 40 || next != len(s) {
		return nil
	}
	return &version
}

func isBareOpN(s []byte) bool {
	if len(s) == 0 {
		return false
	}
	op := int(s[0])
	if !((op >= OP_1 && op <= OP_16) || op == OP_1NEGATE) {
		return false
	}
	if len(s) == 1 {
		return true
	}
	if isP2TR(s) || isP2WPKH(s) || isP2WSH(s) {
		return false
	}
	if _, next, err := readPush(s, 1); err == nil && next == len(s) {
		return true
	}
	return false
}

func isECDSAPubkey(item []byte) bool {
	return (len(item) == 33 && (item[0] == 2 || item[0] == 3)) || (len(item) == 65 && item[0] == 4)
}

func isBareMultisig(s []byte) bool {
	if len(s) < 4 || s[0] < OP_1 || s[0] > OP_16 {
		return false
	}
	required := int(s[0] - OP_1 + 1)
	offset := 1
	pubkeys := 0
	for offset < len(s) {
		op := s[offset]
		if op >= OP_1 && op <= OP_16 {
			break
		}
		item, next, err := readPush(s, offset)
		if err != nil || !isECDSAPubkey(item) {
			return false
		}
		offset = next
		pubkeys++
		if pubkeys > 20 {
			return false
		}
	}
	if pubkeys == 0 || pubkeys < required || offset >= len(s) {
		return false
	}
	nop := s[offset]
	if nop < OP_1 || nop > OP_16 || int(nop-OP_1+1) != pubkeys {
		return false
	}
	offset++
	return offset < len(s) && s[offset] == OP_CHECKMULTISIG && offset+1 == len(s)
}

func isBareLegacyScript(s []byte) bool {
	if len(s) == 0 || len(s) > maxConsensusScriptSize || witnessVersion(s) != nil {
		return false
	}
	if len(s) <= 83 && s[0] == 0x6a {
		return false
	}
	return !(isP2PK(s) || isP2PKH(s) || isP2WPKH(s) || isP2WSH(s) || isP2SH(s) || isP2TR(s) || isBareOpN(s) || isBareMultisig(s))
}

func trailingCompressedPubkey(scriptCode []byte) []byte {
	if len(scriptCode) < 35 {
		return nil
	}
	i := len(scriptCode) - 35
	if scriptCode[i] != 33 {
		return nil
	}
	pk := scriptCode[i+1 : i+34]
	if pk[0] != 2 && pk[0] != 3 {
		return nil
	}
	return clone(pk)
}

func legacySighash(transaction tx.Transaction, inputIndex int, scriptCode []byte, sighashType int) []byte {
	baseType := sighashType & 0x1f
	anyoneCanPay := sighashType&0x80 != 0
	if baseType == 3 && inputIndex >= len(transaction.Outputs) {
		out := make([]byte, 32)
		out[0] = 1
		return out
	}
	var payload []byte
	payload = append(payload, tx.PackInt32(uint32(transaction.Version))...)
	if anyoneCanPay {
		payload = append(payload, tx.CompactSize(1)...)
		payload = append(payload, legacyInput(transaction.Inputs[inputIndex], scriptCode, baseType, true)...)
	} else {
		payload = append(payload, tx.CompactSize(uint64(len(transaction.Inputs)))...)
		for i, in := range transaction.Inputs {
			payload = append(payload, legacyInput(in, scriptCode, baseType, i == inputIndex)...)
		}
	}
	switch baseType {
	case 2:
		payload = append(payload, 0)
	case 3:
		payload = append(payload, tx.CompactSize(uint64(inputIndex+1))...)
		for i := 0; i < inputIndex; i++ {
			payload = append(payload, tx.SerializeTxOut(tx.TxOut{Value: -1})...)
		}
		payload = append(payload, tx.SerializeTxOut(transaction.Outputs[inputIndex])...)
	default:
		payload = append(payload, tx.CompactSize(uint64(len(transaction.Outputs)))...)
		for _, out := range transaction.Outputs {
			payload = append(payload, tx.SerializeTxOut(out)...)
		}
	}
	payload = append(payload, tx.PackInt32(transaction.LockTime)...)
	payload = append(payload, tx.PackInt32(uint32(sighashType))...)
	return tx.DoubleSHA(payload)
}

func legacyInput(in tx.TxIn, scriptCode []byte, baseType int, signing bool) []byte {
	out := tx.SerializeOutPoint(in.PreviousOutput)
	if signing {
		out = append(out, tx.CompactSize(uint64(len(scriptCode)))...)
		out = append(out, scriptCode...)
	} else {
		out = append(out, 0)
	}
	if baseType == 1 || signing {
		out = append(out, tx.PackInt32(in.Sequence)...)
	} else {
		out = append(out, 0, 0, 0, 0)
	}
	return out
}

func bip143Sighash(transaction tx.Transaction, inputIndex int, scriptCode []byte, amount int64, sighashType int) []byte {
	anyoneCanPay := sighashType&0x80 != 0
	baseType := sighashType & 0x1f
	zero := make([]byte, 32)
	hashPrevouts, hashSequence, hashOutputs := zero, zero, zero
	if !anyoneCanPay {
		var blob []byte
		for _, in := range transaction.Inputs {
			blob = append(blob, tx.SerializeOutPoint(in.PreviousOutput)...)
		}
		hashPrevouts = tx.DoubleSHA(blob)
	}
	if !anyoneCanPay && baseType != 2 && baseType != 3 {
		var blob []byte
		for _, in := range transaction.Inputs {
			blob = append(blob, tx.PackInt32(in.Sequence)...)
		}
		hashSequence = tx.DoubleSHA(blob)
	}
	if baseType == 3 {
		if inputIndex < len(transaction.Outputs) {
			hashOutputs = tx.DoubleSHA(tx.SerializeTxOut(transaction.Outputs[inputIndex]))
		}
	} else if baseType != 2 {
		var blob []byte
		for _, out := range transaction.Outputs {
			blob = append(blob, tx.SerializeTxOut(out)...)
		}
		hashOutputs = tx.DoubleSHA(blob)
	}
	in := transaction.Inputs[inputIndex]
	var payload []byte
	payload = append(payload, tx.PackInt32(uint32(transaction.Version))...)
	payload = append(payload, hashPrevouts...)
	payload = append(payload, hashSequence...)
	payload = append(payload, tx.SerializeOutPoint(in.PreviousOutput)...)
	payload = append(payload, tx.CompactSize(uint64(len(scriptCode)))...)
	payload = append(payload, scriptCode...)
	payload = append(payload, tx.PackInt64(uint64(amount))...)
	payload = append(payload, tx.PackInt32(in.Sequence)...)
	payload = append(payload, hashOutputs...)
	payload = append(payload, tx.PackInt32(transaction.LockTime)...)
	payload = append(payload, tx.PackInt32(uint32(sighashType))...)
	return tx.DoubleSHA(payload)
}

type sighashCache struct {
	tx       tx.Transaction
	prevouts []SpentPrevout

	bip143PrevoutsSet bool
	bip143Prevouts    []byte
	bip143SequenceSet bool
	bip143Sequence    []byte
	bip143OutputsSet  bool
	bip143Outputs     []byte
	bip143Single      map[int][]byte

	tapPrevoutsSet      bool
	tapPrevouts         []byte
	tapAmountsSet       bool
	tapAmounts          []byte
	tapScriptPubKeysSet bool
	tapScriptPubKeys    []byte
	tapSequencesSet     bool
	tapSequences        []byte
	tapOutputsSet       bool
	tapOutputs          []byte
	tapSingle           map[int][]byte
}

func newSighashCache(transaction tx.Transaction, prevouts []SpentPrevout) *sighashCache {
	return &sighashCache{tx: transaction, prevouts: prevouts}
}

func bip143SighashCached(cache *sighashCache, transaction tx.Transaction, inputIndex int, scriptCode []byte, amount int64, sighashType int) []byte {
	if cache == nil {
		return bip143Sighash(transaction, inputIndex, scriptCode, amount, sighashType)
	}
	anyoneCanPay := sighashType&0x80 != 0
	baseType := sighashType & 0x1f
	zero := make([]byte, 32)
	hashPrevouts, hashSequence, hashOutputs := zero, zero, zero
	if !anyoneCanPay {
		hashPrevouts = cache.bip143HashPrevouts()
	}
	if !anyoneCanPay && baseType != 2 && baseType != 3 {
		hashSequence = cache.bip143HashSequence()
	}
	if baseType == 3 {
		if inputIndex < len(transaction.Outputs) {
			hashOutputs = cache.bip143HashSingle(inputIndex)
		}
	} else if baseType != 2 {
		hashOutputs = cache.bip143HashOutputs()
	}
	in := transaction.Inputs[inputIndex]
	var payload []byte
	payload = append(payload, tx.PackInt32(uint32(transaction.Version))...)
	payload = append(payload, hashPrevouts...)
	payload = append(payload, hashSequence...)
	payload = append(payload, tx.SerializeOutPoint(in.PreviousOutput)...)
	payload = append(payload, tx.CompactSize(uint64(len(scriptCode)))...)
	payload = append(payload, scriptCode...)
	payload = append(payload, tx.PackInt64(uint64(amount))...)
	payload = append(payload, tx.PackInt32(in.Sequence)...)
	payload = append(payload, hashOutputs...)
	payload = append(payload, tx.PackInt32(transaction.LockTime)...)
	payload = append(payload, tx.PackInt32(uint32(sighashType))...)
	return tx.DoubleSHA(payload)
}

func (c *sighashCache) bip143HashPrevouts() []byte {
	if !c.bip143PrevoutsSet {
		var blob []byte
		for _, in := range c.tx.Inputs {
			blob = append(blob, tx.SerializeOutPoint(in.PreviousOutput)...)
		}
		c.bip143Prevouts = tx.DoubleSHA(blob)
		c.bip143PrevoutsSet = true
	}
	return c.bip143Prevouts
}

func (c *sighashCache) bip143HashSequence() []byte {
	if !c.bip143SequenceSet {
		var blob []byte
		for _, in := range c.tx.Inputs {
			blob = append(blob, tx.PackInt32(in.Sequence)...)
		}
		c.bip143Sequence = tx.DoubleSHA(blob)
		c.bip143SequenceSet = true
	}
	return c.bip143Sequence
}

func (c *sighashCache) bip143HashOutputs() []byte {
	if !c.bip143OutputsSet {
		var blob []byte
		for _, out := range c.tx.Outputs {
			blob = append(blob, tx.SerializeTxOut(out)...)
		}
		c.bip143Outputs = tx.DoubleSHA(blob)
		c.bip143OutputsSet = true
	}
	return c.bip143Outputs
}

func (c *sighashCache) bip143HashSingle(index int) []byte {
	if c.bip143Single == nil {
		c.bip143Single = map[int][]byte{}
	}
	if value, ok := c.bip143Single[index]; ok {
		return value
	}
	value := tx.DoubleSHA(tx.SerializeTxOut(c.tx.Outputs[index]))
	c.bip143Single[index] = value
	return value
}

func verifyTaproot(scriptPubKey, scriptSig []byte, witness [][]byte, transaction tx.Transaction, inputIndex int, spentPrevouts []SpentPrevout, verifier *crypto.Verifier, cache *sighashCache) bool {
	if len(scriptSig) > 0 || spentPrevouts == nil || !isP2TR(scriptPubKey) {
		return false
	}
	serializedWitness := serializedWitnessStack(witness)
	if len(witness) >= 2 && len(witness[len(witness)-1]) > 0 && witness[len(witness)-1][0] == 0x50 {
		return false
	}
	if len(witness) >= 2 {
		return verifyTaprootScriptPath(scriptPubKey, witness, nil, transaction, inputIndex, spentPrevouts, serializedWitness, verifier, cache)
	}
	if len(witness) != 1 {
		return false
	}
	sigBlob := witness[0]
	if len(sigBlob) != 64 && len(sigBlob) != 65 {
		return false
	}
	hashType := taprootSighashDefault
	sig64 := sigBlob
	if len(sigBlob) == 65 {
		hashType = int(sigBlob[64])
		if hashType == taprootSighashDefault {
			return false
		}
		sig64 = sigBlob[:64]
	}
	digest, err := taprootSighashCached(cache, transaction, inputIndex, spentPrevouts, taprootOptions{hashType: hashType, codeSeparatorPos: 0xffffffff})
	if err != nil {
		return false
	}
	return verifier.VerifySchnorr(scriptPubKey[2:], digest, sig64)
}

func verifyTaprootScriptPath(scriptPubKey []byte, witness [][]byte, annex []byte, transaction tx.Transaction, inputIndex int, spentPrevouts []SpentPrevout, serializedWitness []byte, verifier *crypto.Verifier, cache *sighashCache) bool {
	if len(spentPrevouts) != len(transaction.Inputs) || len(witness) < 2 {
		return false
	}
	scriptBytes := witness[len(witness)-2]
	control := witness[len(witness)-1]
	stackItems := witness[:len(witness)-2]
	if len(scriptBytes) == 0 || len(control) < 33 || len(control) > 33+128*32 || (len(control)-33)%32 != 0 {
		return false
	}
	leafMasked := int(control[0] & 0xfe)
	if leafMasked == 0x50 {
		return false
	}
	internalX := control[1:33]
	leaf := tapleafHash(leafMasked, scriptBytes)
	root := leaf
	for i := 33; i < len(control); i += 32 {
		root = tapbranchHash(root, control[i:i+32])
	}
	tweak := taggedHash("TapTweak", append(clone(internalX), root...))
	tweaked, ok := verifier.TaprootTweakPubkeyXOnly(internalX, tweak)
	if !ok || !bytes.Equal(scriptPubKey[2:], tweaked.OutputXOnly) || control[0] != byte(leafMasked|tweaked.Parity) {
		return false
	}
	if leafMasked != taprootLeafTapscript {
		return true
	}
	if prescanOpSuccess(scriptBytes) {
		return true
	}
	if len(stackItems) > maxTapscriptStackItems {
		return false
	}
	for _, item := range stackItems {
		if len(item) > maxScriptElementSize {
			return false
		}
	}
	budget := tapValidationOffset + len(serializedWitness)
	st := &stack{}
	for _, item := range stackItems {
		st.push(item)
	}
	if err := evaluateTapscript(scriptBytes, st, transaction, inputIndex, leaf, spentPrevouts, annex, &budget, verifier, cache); err != nil {
		return false
	}
	return terminalStrict(st)
}

type taprootOptions struct {
	hashType         int
	annex            []byte
	extFlag          int
	tapleafHash      []byte
	codeSeparatorPos uint32
}

func taprootSighash(transaction tx.Transaction, inputIndex int, spentPrevouts []SpentPrevout, opt taprootOptions) ([]byte, error) {
	return taprootSighashWithComponents(transaction, inputIndex, spentPrevouts, opt, nil)
}

func taprootSighashCached(cache *sighashCache, transaction tx.Transaction, inputIndex int, spentPrevouts []SpentPrevout, opt taprootOptions) ([]byte, error) {
	return taprootSighashWithComponents(transaction, inputIndex, spentPrevouts, opt, cache)
}

func taprootSighashWithComponents(transaction tx.Transaction, inputIndex int, spentPrevouts []SpentPrevout, opt taprootOptions, cache *sighashCache) ([]byte, error) {
	if len(spentPrevouts) != len(transaction.Inputs) {
		return nil, errors.New("spent_prevouts length mismatch")
	}
	if !taprootAllowedHashType(opt.hashType) {
		return nil, errors.New("unsupported taproot sighash type")
	}
	outputMode := opt.hashType
	if outputMode == taprootSighashDefault {
		outputMode = taprootSighashAll
	}
	outputMode &= 0x03
	anyoneCanPay := opt.hashType&0x80 != 0
	var body []byte
	body = append(body, byte(opt.hashType))
	body = append(body, tx.PackInt32(uint32(transaction.Version))...)
	body = append(body, tx.PackInt32(transaction.LockTime)...)
	if !anyoneCanPay {
		body = append(body, tapShaPrevouts(cache, transaction)...)
		body = append(body, tapShaAmounts(cache, spentPrevouts)...)
		body = append(body, tapShaScriptPubKeys(cache, spentPrevouts)...)
		body = append(body, tapShaSequences(cache, transaction)...)
	}
	if outputMode == taprootSighashAll {
		body = append(body, tapShaOutputsAll(cache, transaction)...)
	} else if outputMode == taprootSighashSingle && inputIndex >= len(transaction.Outputs) {
		return nil, errors.New("SIGHASH_SINGLE without matching output")
	}
	spendType := (opt.extFlag << 1)
	if opt.annex != nil {
		spendType++
	}
	body = append(body, byte(spendType))
	if anyoneCanPay {
		in := transaction.Inputs[inputIndex]
		prevout := spentPrevouts[inputIndex]
		body = append(body, tx.SerializeOutPoint(in.PreviousOutput)...)
		body = append(body, tx.SerializeTxOut(tx.TxOut{Value: prevout.Amount, ScriptPubKey: prevout.ScriptPubKey})...)
		body = append(body, tx.PackInt32(in.Sequence)...)
	} else {
		body = append(body, tx.PackInt32(uint32(inputIndex))...)
	}
	if opt.annex != nil {
		body = append(body, sha256Bytes(append(tx.CompactSize(uint64(len(opt.annex))), opt.annex...))...)
	}
	if outputMode == taprootSighashSingle {
		body = append(body, tapShaOutputSingle(cache, transaction, inputIndex)...)
	}
	if opt.extFlag == 1 {
		body = append(body, opt.tapleafHash...)
		body = append(body, 0)
		body = append(body, tx.PackInt32(opt.codeSeparatorPos)...)
	}
	return taggedHash("TapSighash", append([]byte{0}, body...)), nil
}

func tapShaPrevouts(cache *sighashCache, transaction tx.Transaction) []byte {
	if cache == nil {
		return shaPrevouts(transaction)
	}
	if !cache.tapPrevoutsSet {
		cache.tapPrevouts = shaPrevouts(transaction)
		cache.tapPrevoutsSet = true
	}
	return cache.tapPrevouts
}

func tapShaAmounts(cache *sighashCache, prevouts []SpentPrevout) []byte {
	if cache == nil {
		return shaAmounts(prevouts)
	}
	if !cache.tapAmountsSet {
		cache.tapAmounts = shaAmounts(prevouts)
		cache.tapAmountsSet = true
	}
	return cache.tapAmounts
}

func tapShaScriptPubKeys(cache *sighashCache, prevouts []SpentPrevout) []byte {
	if cache == nil {
		return shaScriptPubKeys(prevouts)
	}
	if !cache.tapScriptPubKeysSet {
		cache.tapScriptPubKeys = shaScriptPubKeys(prevouts)
		cache.tapScriptPubKeysSet = true
	}
	return cache.tapScriptPubKeys
}

func tapShaSequences(cache *sighashCache, transaction tx.Transaction) []byte {
	if cache == nil {
		return shaSequences(transaction)
	}
	if !cache.tapSequencesSet {
		cache.tapSequences = shaSequences(transaction)
		cache.tapSequencesSet = true
	}
	return cache.tapSequences
}

func tapShaOutputsAll(cache *sighashCache, transaction tx.Transaction) []byte {
	if cache == nil {
		return shaOutputsAll(transaction)
	}
	if !cache.tapOutputsSet {
		cache.tapOutputs = shaOutputsAll(transaction)
		cache.tapOutputsSet = true
	}
	return cache.tapOutputs
}

func tapShaOutputSingle(cache *sighashCache, transaction tx.Transaction, inputIndex int) []byte {
	if cache == nil {
		return sha256Bytes(tx.SerializeTxOut(transaction.Outputs[inputIndex]))
	}
	if cache.tapSingle == nil {
		cache.tapSingle = map[int][]byte{}
	}
	if value, ok := cache.tapSingle[inputIndex]; ok {
		return value
	}
	value := sha256Bytes(tx.SerializeTxOut(transaction.Outputs[inputIndex]))
	cache.tapSingle[inputIndex] = value
	return value
}

func shaPrevouts(transaction tx.Transaction) []byte {
	var b []byte
	for _, in := range transaction.Inputs {
		b = append(b, tx.SerializeOutPoint(in.PreviousOutput)...)
	}
	return sha256Bytes(b)
}
func shaAmounts(prevouts []SpentPrevout) []byte {
	var b []byte
	for _, p := range prevouts {
		b = append(b, tx.PackInt64(uint64(p.Amount))...)
	}
	return sha256Bytes(b)
}
func shaScriptPubKeys(prevouts []SpentPrevout) []byte {
	var b []byte
	for _, p := range prevouts {
		b = append(b, tx.CompactSize(uint64(len(p.ScriptPubKey)))...)
		b = append(b, p.ScriptPubKey...)
	}
	return sha256Bytes(b)
}
func shaSequences(transaction tx.Transaction) []byte {
	var b []byte
	for _, in := range transaction.Inputs {
		b = append(b, tx.PackInt32(in.Sequence)...)
	}
	return sha256Bytes(b)
}
func shaOutputsAll(transaction tx.Transaction) []byte {
	var b []byte
	for _, out := range transaction.Outputs {
		b = append(b, tx.SerializeTxOut(out)...)
	}
	return sha256Bytes(b)
}
func taprootAllowedHashType(ht int) bool { return ht <= 0x03 || (ht >= 0x81 && ht <= 0x83) }
func tapleafHash(version int, script []byte) []byte {
	return taggedHash("TapLeaf", append(append([]byte{byte(version)}, tx.CompactSize(uint64(len(script)))...), script...))
}
func tapbranchHash(left, right []byte) []byte {
	pair := [][]byte{clone(left), clone(right)}
	sort.Slice(pair, func(i, j int) bool { return bytes.Compare(pair[i], pair[j]) < 0 })
	return taggedHash("TapBranch", append(pair[0], pair[1]...))
}
func serializedWitnessStack(stack [][]byte) []byte {
	var out []byte
	out = append(out, tx.CompactSize(uint64(len(stack)))...)
	for _, item := range stack {
		out = append(out, tx.CompactSize(uint64(len(item)))...)
		out = append(out, item...)
	}
	return out
}
func prescanOpSuccess(script []byte) bool {
	off := 0
	for off < len(script) {
		op := int(script[off])
		if op == OP_0 || (op >= OP_1 && op <= OP_16) || op == OP_1NEGATE {
			off++
			continue
		}
		if op >= 1 && op <= 75 {
			off += 1 + op
			continue
		}
		if op == OP_PUSHDATA1 || op == OP_PUSHDATA2 || op == OP_PUSHDATA4 {
			_, n, err := readPush(script, off)
			if err != nil {
				return false
			}
			off = n
			continue
		}
		if opcodeIsSuccess(op) {
			return true
		}
		off++
	}
	return false
}
func opcodeIsSuccess(op int) bool {
	return op == 80 || op == 98 || (op >= 126 && op <= 129) || (op >= 131 && op <= 134) || (op >= 137 && op <= 138) || (op >= 141 && op <= 142) || (op >= 149 && op <= 153) || (op >= 187 && op <= 254)
}

func evaluateTapscript(scriptBytes []byte, st *stack, transaction tx.Transaction, inputIndex int, leaf []byte, spentPrevouts []SpentPrevout, annex []byte, budget *int, verifier *crypto.Verifier, cache *sighashCache) error {
	// The legacy evaluator covers the shared opcode surface. Tapscript-only signature opcodes are handled here by translating their checks.
	offset := 0
	vfExec := []bool{}
	alt := &stack{}
	codeSep := uint32(math.MaxUint32)
	for offset < len(scriptBytes) {
		instrAt := offset
		op := int(scriptBytes[offset])
		fExec := allTrue(vfExec)
		if op == OP_IF || op == OP_NOTIF {
			if fExec {
				branch := castToBool(st.pop())
				if op == OP_NOTIF {
					branch = !branch
				}
				vfExec = append(vfExec, branch)
			} else {
				vfExec = append(vfExec, false)
			}
			offset++
			continue
		}
		if op == OP_ELSE {
			if len(vfExec) == 0 {
				return errors.New("unbalanced conditional")
			}
			vfExec[len(vfExec)-1] = !vfExec[len(vfExec)-1]
			offset++
			continue
		}
		if op == OP_ENDIF {
			if len(vfExec) == 0 {
				return errors.New("unbalanced conditional")
			}
			vfExec = vfExec[:len(vfExec)-1]
			offset++
			continue
		}
		if !fExec {
			n, err := advanceOpcode(scriptBytes, offset)
			if err != nil {
				return err
			}
			offset = n
			continue
		}
		if op == OP_CHECKSIG || op == OP_CHECKSIGVERIFY || op == OP_CHECKSIGADD {
			if err := evalTapSigOp(op, st, transaction, inputIndex, spentPrevouts, annex, leaf, codeSep, budget, verifier, cache); err != nil {
				return err
			}
			offset++
			continue
		}
		if op == OP_CODESEPARATOR {
			codeSep = uint32(instrAt)
			offset++
			continue
		}
		if op == OP_CHECKMULTISIG || op == OP_CHECKMULTISIGVERIFY {
			return errors.New("CHECKMULTISIG disabled in tapscript")
		}
		if op == OP_CHECKLOCKTIMEVERIFY {
			if err := checkLockTimeVerify(st, transaction); err != nil {
				return err
			}
			offset++
			continue
		}
		if op == OP_CHECKSEQUENCEVERIFY {
			if err := checkSequenceVerify(st, transaction, inputIndex); err != nil {
				return err
			}
			offset++
			continue
		}
		context := evalContext{tx: transaction, inputIndex: inputIndex, scriptCode: scriptBytes, amount: spentPrevouts[inputIndex].Amount, witness: true, verifier: verifier, cache: cache}
		if op == OP_0 || (op >= OP_1 && op <= OP_16) || op == OP_1NEGATE || isPushOpcode(op) {
			if op == OP_0 {
				st.push(nil)
				offset++
			} else if op >= OP_1 && op <= OP_16 {
				st.push(encodeOpN(op - OP_1 + 1))
				offset++
			} else if op == OP_1NEGATE {
				st.push([]byte{0x81})
				offset++
			} else {
				item, n, err := readPush(scriptBytes, offset)
				if err != nil {
					return err
				}
				st.push(item)
				offset = n
			}
			continue
		}
		_, err := evalOpcode(op, st, alt, context, true, instrAt)
		if err != nil {
			return err
		}
		offset++
	}
	return nil
}

func evalTapSigOp(op int, st *stack, transaction tx.Transaction, inputIndex int, spentPrevouts []SpentPrevout, annex []byte, leaf []byte, codeSep uint32, budget *int, verifier *crypto.Verifier, cache *sighashCache) error {
	if op == OP_CHECKSIG || op == OP_CHECKSIGVERIFY {
		pubkey, sig := st.pop(), st.pop()
		valid := verifyTapSignature(pubkey, sig, transaction, inputIndex, spentPrevouts, annex, leaf, codeSep, budget, verifier, cache)
		if op == OP_CHECKSIG {
			st.push(encodeOpN(boolInt(valid)))
		} else if !valid {
			return errors.New("CHECKSIGVERIFY failed")
		}
		return nil
	}
	pubkey, nItem, sig := st.pop(), st.pop(), st.pop()
	n := decodeScriptNum(nItem, 4)
	if len(sig) == 0 {
		st.push(encodeScriptNum(n, 4))
		return nil
	}
	valid := verifyTapSignature(pubkey, sig, transaction, inputIndex, spentPrevouts, annex, leaf, codeSep, budget, verifier, cache)
	if valid {
		n++
	}
	st.push(encodeScriptNum(n, 4))
	return nil
}

func verifyTapSignature(pubkey, sig []byte, transaction tx.Transaction, inputIndex int, spentPrevouts []SpentPrevout, annex []byte, leaf []byte, codeSep uint32, budget *int, verifier *crypto.Verifier, cache *sighashCache) bool {
	if len(pubkey) == 0 {
		panic("empty pubkey in tapscript")
	}
	if len(sig) > 0 {
		*budget -= tapValidationPerSigOp
		if *budget < 0 {
			panic("tapscript validation weight exceeded")
		}
	}
	if len(pubkey) != 32 {
		return len(sig) > 0
	}
	if len(sig) == 0 {
		return false
	}
	hashType := taprootSighashDefault
	sig64 := sig
	if len(sig) == 65 {
		hashType = int(sig[64])
		if hashType == taprootSighashDefault {
			panic("invalid tap hashtype")
		}
		sig64 = sig[:64]
	} else if len(sig) != 64 {
		panic("invalid Schnorr signature length")
	}
	digest, err := taprootSighashCached(cache, transaction, inputIndex, spentPrevouts, taprootOptions{hashType: hashType, annex: annex, extFlag: 1, tapleafHash: leaf, codeSeparatorPos: codeSep})
	if err != nil {
		panic(err)
	}
	return verifier.VerifySchnorr(pubkey, digest, sig64)
}
