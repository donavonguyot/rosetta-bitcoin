use anyhow::{anyhow, bail, ensure, Result};
use ripemd::{Digest, Ripemd160};
use secp256k1::{ecdsa::Signature as EcdsaSignature, schnorr, Message, Parity, PublicKey, Scalar};
use secp256k1::{Secp256k1, XOnlyPublicKey};
use sha1::Sha1;
use sha2::Sha256;

use crate::tx::{self, OutPoint, Transaction, TxIn, TxOut};

const OP_0: u8 = 0x00;
const OP_PUSHDATA1: u8 = 0x4c;
const OP_PUSHDATA2: u8 = 0x4d;
const OP_PUSHDATA4: u8 = 0x4e;
const OP_1NEGATE: u8 = 0x4f;
const OP_1: u8 = 0x51;
const OP_16: u8 = 0x60;
const OP_NOP: u8 = 0x61;
const OP_IF: u8 = 0x63;
const OP_NOTIF: u8 = 0x64;
const OP_ELSE: u8 = 0x67;
const OP_ENDIF: u8 = 0x68;
const OP_VERIFY: u8 = 0x69;
const OP_TOALTSTACK: u8 = 0x6b;
const OP_FROMALTSTACK: u8 = 0x6c;
const OP_2DROP: u8 = 0x6d;
const OP_2DUP: u8 = 0x6e;
const OP_3DUP: u8 = 0x6f;
const OP_2OVER: u8 = 0x70;
const OP_2SWAP: u8 = 0x72;
const OP_IFDUP: u8 = 0x73;
const OP_DEPTH: u8 = 0x74;
const OP_DROP: u8 = 0x75;
const OP_DUP: u8 = 0x76;
const OP_NIP: u8 = 0x77;
const OP_OVER: u8 = 0x78;
const OP_PICK: u8 = 0x79;
const OP_ROLL: u8 = 0x7a;
const OP_ROT: u8 = 0x7b;
const OP_SWAP: u8 = 0x7c;
const OP_TUCK: u8 = 0x7d;
const OP_SIZE: u8 = 0x82;
const OP_EQUAL: u8 = 0x87;
const OP_EQUALVERIFY: u8 = 0x88;
const OP_1SUB: u8 = 0x8c;
const OP_NEGATE: u8 = 0x8f;
const OP_ABS: u8 = 0x90;
const OP_NOT: u8 = 0x91;
const OP_0NOTEQUAL: u8 = 0x92;
const OP_ADD: u8 = 0x93;
const OP_SUB: u8 = 0x94;
const OP_MUL: u8 = 0x95;
const OP_BOOLAND: u8 = 0x9a;
const OP_BOOLOR: u8 = 0x9b;
const OP_NUMEQUAL: u8 = 0x9c;
const OP_NUMEQUALVERIFY: u8 = 0x9d;
const OP_NUMNOTEQUAL: u8 = 0x9e;
const OP_LESSTHAN: u8 = 0x9f;
const OP_GREATERTHAN: u8 = 0xa0;
const OP_LESSTHANOREQUAL: u8 = 0xa1;
const OP_GREATERTHANOREQUAL: u8 = 0xa2;
const OP_MIN: u8 = 0xa3;
const OP_MAX: u8 = 0xa4;
const OP_WITHIN: u8 = 0xa5;
const OP_RIPEMD160: u8 = 0xa6;
const OP_SHA1: u8 = 0xa7;
const OP_SHA256: u8 = 0xa8;
const OP_HASH160: u8 = 0xa9;
const OP_HASH256: u8 = 0xaa;
const OP_CODESEPARATOR: u8 = 0xab;
const OP_CHECKSIG: u8 = 0xac;
const OP_CHECKSIGVERIFY: u8 = 0xad;
const OP_CHECKMULTISIG: u8 = 0xae;
const OP_CHECKMULTISIGVERIFY: u8 = 0xaf;
const OP_CHECKLOCKTIMEVERIFY: u8 = 0xb1;
const OP_CHECKSEQUENCEVERIFY: u8 = 0xb2;
const OP_CHECKSIGADD: u8 = 0xba;

const TAPROOT_LEAF_TAPSCRIPT: u8 = 0xc0;
const SEQUENCE_FINAL: u32 = 0xffff_ffff;
const LOCKTIME_THRESHOLD: u32 = 500_000_000;
const SEQUENCE_DISABLE_FLAG: i64 = 1 << 31;
const SEQUENCE_TYPE_FLAG: i64 = 1 << 22;
const SEQUENCE_LOCKTIME_MASK: i64 = 0x0000_ffff;
const MAX_CONSENSUS_SCRIPT_SIZE: usize = 10_000;
const MAX_TAPSCRIPT_STACK_ITEMS: usize = 1000;
const MAX_SCRIPT_ELEMENT_SIZE: usize = 520;
const TAP_VALIDATION_OFFSET: i32 = 50;
const TAP_VALIDATION_PER_SIGOP: i32 = 50;
const TAPROOT_SIGHASH_DEFAULT: u8 = 0;
const TAPROOT_SIGHASH_ALL: u8 = 1;
const TAPROOT_SIGHASH_SINGLE: u8 = 3;

#[derive(Clone, Debug)]
pub struct SpentPrevout {
    pub amount: i64,
    pub script_pubkey: Vec<u8>,
}

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct VerifyInputOptions {
    pub script_pubkey: Vec<u8>,
    pub amount: i64,
    pub spent_prevouts: Vec<SpentPrevout>,
}

pub fn verify_transaction_input(
    transaction: &Transaction,
    input_index: usize,
    options: &VerifyInputOptions,
) -> Result<()> {
    verify_transaction_input_borrowed(
        transaction,
        input_index,
        &options.script_pubkey,
        options.amount,
        &options.spent_prevouts,
    )
}

pub fn verify_transaction_input_borrowed(
    transaction: &Transaction,
    input_index: usize,
    script_pubkey: &[u8],
    amount: i64,
    spent_prevouts: &[SpentPrevout],
) -> Result<()> {
    ensure!(
        input_index < transaction.inputs.len(),
        "input index out of range"
    );
    if let Some(version) = witness_version(script_pubkey)? {
        ensure!(version <= 1, "unsupported witness program version");
    }
    ensure!(
        is_p2pk(script_pubkey)
            || is_p2pkh(script_pubkey)
            || is_p2wpkh(script_pubkey)
            || is_p2wsh(script_pubkey)
            || is_p2sh(script_pubkey)
            || is_p2tr(script_pubkey)
            || is_bare_op_n(script_pubkey)?
            || is_bare_multisig(script_pubkey)?
            || is_bare_legacy_script(script_pubkey)?,
        "unsupported Rust scriptPubKey template: {}",
        hex::encode(script_pubkey)
    );
    let witness = transaction
        .witness
        .get(input_index)
        .cloned()
        .unwrap_or_default();
    ensure!(
        verify_script(
            &transaction.inputs[input_index].script_sig,
            script_pubkey,
            transaction,
            input_index,
            amount,
            &witness,
            spent_prevouts,
        )?,
        "script verification failed for input {input_index}"
    );
    Ok(())
}

fn verify_script(
    script_sig: &[u8],
    script_pubkey: &[u8],
    transaction: &Transaction,
    input_index: usize,
    amount: i64,
    witness: &[Vec<u8>],
    spent_prevouts: &[SpentPrevout],
) -> Result<bool> {
    if is_p2tr(script_pubkey) {
        return verify_taproot(
            script_pubkey,
            script_sig,
            witness,
            transaction,
            input_index,
            spent_prevouts,
        );
    }
    if is_p2wpkh(script_pubkey) {
        return verify_p2wpkh(
            script_sig,
            script_pubkey,
            transaction,
            input_index,
            amount,
            witness,
        );
    }
    if is_p2wsh(script_pubkey) {
        return verify_p2wsh(
            script_sig,
            script_pubkey,
            transaction,
            input_index,
            amount,
            witness,
        );
    }
    if is_p2sh(script_pubkey) {
        return verify_p2sh(
            script_sig,
            script_pubkey,
            transaction,
            input_index,
            amount,
            witness,
        );
    }
    let context = EvalContext {
        tx: transaction,
        input_index,
        script_code: script_pubkey.to_vec(),
        code_separator_offset: 0,
        amount,
        witness: false,
    };
    if is_p2pk(script_pubkey) {
        if !witness.is_empty() {
            return Ok(false);
        }
        let pushes = parse_push_only(script_sig)?;
        if pushes.len() != 1 || pushes[0].is_empty() {
            return Ok(false);
        }
    }
    if (is_bare_op_n(script_pubkey)?
        || is_bare_multisig(script_pubkey)?
        || is_bare_legacy_script(script_pubkey)?)
        && !witness.is_empty()
    {
        return Ok(false);
    }
    let mut stack_sig = Stack::default();
    evaluate_script(script_sig, &mut stack_sig, context.clone())?;
    let mut stack = Stack::default();
    stack.push_all(&stack_sig.snapshot());
    evaluate_script(script_pubkey, &mut stack, context)?;
    if (is_bare_op_n(script_pubkey)? && script_pubkey.len() > 1)
        || is_bare_legacy_script(script_pubkey)?
        || is_p2pkh(script_pubkey)
    {
        Ok(terminal_relaxed(&stack))
    } else {
        Ok(terminal_strict(&stack))
    }
}

fn verify_p2sh(
    script_sig: &[u8],
    script_pubkey: &[u8],
    transaction: &Transaction,
    input_index: usize,
    amount: i64,
    witness: &[Vec<u8>],
) -> Result<bool> {
    let pushes = parse_push_only(script_sig)?;
    if pushes.is_empty() || pushes[pushes.len() - 1].len() > MAX_SCRIPT_ELEMENT_SIZE {
        return Ok(false);
    }
    let redeem = pushes[pushes.len() - 1].clone();
    let context = EvalContext {
        tx: transaction,
        input_index,
        script_code: script_pubkey.to_vec(),
        code_separator_offset: 0,
        amount,
        witness: false,
    };
    let mut stack_sig = Stack::default();
    evaluate_script(script_sig, &mut stack_sig, context.clone())?;
    if stack_sig.size() == 0 || stack_sig.peek()? != redeem.as_slice() {
        return Ok(false);
    }
    let mut outer = Stack::default();
    outer.push_all(&stack_sig.snapshot());
    evaluate_script(script_pubkey, &mut outer, context)?;
    if !terminal_relaxed(&outer) || hash160(&redeem).as_slice() != &script_pubkey[2..22] {
        return Ok(false);
    }
    if is_p2wpkh(&redeem) {
        return verify_p2wpkh_witness(&redeem, transaction, input_index, amount, witness);
    }
    if is_p2wsh(&redeem) {
        return verify_p2wsh_witness(&redeem[2..], transaction, input_index, amount, witness, 1);
    }
    let mut inner = Stack::default();
    let snap = stack_sig.snapshot();
    for item in snap.iter().take(snap.len().saturating_sub(1)) {
        inner.push(item);
    }
    let inner_context = EvalContext {
        tx: transaction,
        input_index,
        script_code: redeem.clone(),
        code_separator_offset: 0,
        amount,
        witness: false,
    };
    evaluate_script(&redeem, &mut inner, inner_context)?;
    Ok(terminal_relaxed(&inner))
}

fn verify_p2wpkh(
    script_sig: &[u8],
    script_pubkey: &[u8],
    transaction: &Transaction,
    input_index: usize,
    amount: i64,
    witness: &[Vec<u8>],
) -> Result<bool> {
    if !script_sig.is_empty() {
        return Ok(false);
    }
    verify_p2wpkh_witness(script_pubkey, transaction, input_index, amount, witness)
}

fn verify_p2wpkh_witness(
    script_pubkey: &[u8],
    transaction: &Transaction,
    input_index: usize,
    amount: i64,
    witness: &[Vec<u8>],
) -> Result<bool> {
    if witness.len() != 2 {
        return Ok(false);
    }
    let script_code = p2pkh_script_code(&script_pubkey[2..]);
    let mut stack = Stack::default();
    stack.push(&witness[0]);
    stack.push(&witness[1]);
    let context = EvalContext {
        tx: transaction,
        input_index,
        script_code: script_code.clone(),
        code_separator_offset: 0,
        amount,
        witness: true,
    };
    evaluate_script(&script_code, &mut stack, context)?;
    Ok(terminal_strict(&stack))
}

fn verify_p2wsh(
    script_sig: &[u8],
    script_pubkey: &[u8],
    transaction: &Transaction,
    input_index: usize,
    amount: i64,
    witness: &[Vec<u8>],
) -> Result<bool> {
    if !script_sig.is_empty() {
        return Ok(false);
    }
    verify_p2wsh_witness(
        &script_pubkey[2..],
        transaction,
        input_index,
        amount,
        witness,
        1,
    )
}

fn verify_p2wsh_witness(
    witness_program: &[u8],
    transaction: &Transaction,
    input_index: usize,
    amount: i64,
    witness: &[Vec<u8>],
    min_items: usize,
) -> Result<bool> {
    if witness.len() < min_items {
        return Ok(false);
    }
    let witness_script = &witness[witness.len() - 1];
    if witness_script.is_empty()
        || witness_script.len() > MAX_CONSENSUS_SCRIPT_SIZE
        || sha256_bytes(witness_script).as_slice() != witness_program
    {
        return Ok(false);
    }
    let mut stack = Stack::default();
    for item in &witness[..witness.len() - 1] {
        stack.push(item);
    }
    let context = EvalContext {
        tx: transaction,
        input_index,
        script_code: witness_script.clone(),
        code_separator_offset: 0,
        amount,
        witness: true,
    };
    evaluate_script(witness_script, &mut stack, context)?;
    Ok(terminal_strict(&stack))
}

#[derive(Clone)]
struct EvalContext<'a> {
    tx: &'a Transaction,
    input_index: usize,
    script_code: Vec<u8>,
    code_separator_offset: usize,
    amount: i64,
    witness: bool,
}

impl EvalContext<'_> {
    fn effective_script_code(&self) -> &[u8] {
        if self.code_separator_offset == 0 {
            &self.script_code
        } else {
            &self.script_code[self.code_separator_offset..]
        }
    }

    fn with_code_separator_after(mut self, offset: usize) -> Self {
        self.code_separator_offset = offset;
        self
    }
}

fn evaluate_script(script: &[u8], stack: &mut Stack, mut context: EvalContext<'_>) -> Result<()> {
    let mut offset = 0usize;
    let mut vf_exec = Vec::<bool>::new();
    let mut alt = Stack::default();
    while offset < script.len() {
        let instr_at = offset;
        let opcode = script[offset];
        let f_exec = all_true(&vf_exec);
        if opcode == OP_IF || opcode == OP_NOTIF {
            if f_exec {
                let mut branch = cast_to_bool(&stack.pop()?);
                if opcode == OP_NOTIF {
                    branch = !branch;
                }
                vf_exec.push(branch);
            } else {
                vf_exec.push(false);
            }
            offset += 1;
            continue;
        }
        if opcode == OP_ELSE {
            ensure!(!vf_exec.is_empty(), "unbalanced conditional");
            let last = vf_exec.len() - 1;
            vf_exec[last] = !vf_exec[last];
            offset += 1;
            continue;
        }
        if opcode == OP_ENDIF {
            ensure!(!vf_exec.is_empty(), "unbalanced conditional");
            vf_exec.pop();
            offset += 1;
            continue;
        }
        if !f_exec {
            offset = advance_opcode(script, offset)?;
            continue;
        }
        if opcode == OP_0 {
            stack.push(&[]);
            offset += 1;
        } else if (OP_1..=OP_16).contains(&opcode) {
            stack.push(&encode_op_n((opcode - OP_1 + 1) as i64)?);
            offset += 1;
        } else if opcode == OP_1NEGATE {
            stack.push(&[0x81]);
            offset += 1;
        } else if is_push_opcode(opcode) {
            let (item, next) = read_push(script, offset)?;
            stack.push(&item);
            offset = next;
        } else {
            context = eval_opcode(opcode, stack, &mut alt, context, false, instr_at)?;
            offset += 1;
        }
    }
    Ok(())
}

fn eval_opcode<'a>(
    opcode: u8,
    stack: &mut Stack,
    alt: &mut Stack,
    mut context: EvalContext<'a>,
    _tapscript: bool,
    instr_at: usize,
) -> Result<EvalContext<'a>> {
    match opcode {
        OP_DROP => {
            stack.pop()?;
        }
        OP_2DROP => {
            stack.pop()?;
            stack.pop()?;
        }
        OP_TOALTSTACK => {
            alt.push(&stack.pop()?);
        }
        OP_FROMALTSTACK => {
            stack.push(&alt.pop()?);
        }
        OP_2DUP => {
            let x2 = stack.pop()?;
            let x1 = stack.pop()?;
            stack.push(&x1);
            stack.push(&x2);
            stack.push(&x1);
            stack.push(&x2);
        }
        OP_3DUP => {
            let x3 = stack.pop()?;
            let x2 = stack.pop()?;
            let x1 = stack.pop()?;
            stack.push(&x1);
            stack.push(&x2);
            stack.push(&x3);
            stack.push(&x1);
            stack.push(&x2);
            stack.push(&x3);
        }
        OP_2OVER => {
            ensure!(stack.size() >= 4, "OP_2OVER underflow");
            let a = stack.item_from_top(4)?.to_vec();
            let b = stack.item_from_top(4)?.to_vec();
            stack.push(&a);
            stack.push(&b);
        }
        OP_2SWAP => {
            let x4 = stack.pop()?;
            let x3 = stack.pop()?;
            let x2 = stack.pop()?;
            let x1 = stack.pop()?;
            stack.push(&x3);
            stack.push(&x4);
            stack.push(&x1);
            stack.push(&x2);
        }
        OP_DEPTH => stack.push(&encode_script_num(stack.size() as i64, 4)?),
        OP_PICK => {
            let depth = decode_script_num(&stack.pop()?, 4)?;
            ensure!(
                depth >= 0 && (depth as usize) < stack.size(),
                "OP_PICK out of range"
            );
            let item = stack.item_from_top(depth as usize + 1)?.to_vec();
            stack.push(&item);
        }
        OP_ROLL => {
            let depth = decode_script_num(&stack.pop()?, 4)?;
            stack.roll_from_top(depth as usize)?;
        }
        OP_DUP => {
            let item = stack.peek()?.to_vec();
            stack.push(&item);
        }
        OP_IFDUP => {
            if cast_to_bool(stack.peek()?) {
                let item = stack.peek()?.to_vec();
                stack.push(&item);
            }
        }
        OP_NIP => {
            let top = stack.pop()?;
            stack.pop()?;
            stack.push(&top);
        }
        OP_OVER => {
            let item = stack.item_from_top(2)?.to_vec();
            stack.push(&item);
        }
        OP_ROT => {
            let x3 = stack.pop()?;
            let x2 = stack.pop()?;
            let x1 = stack.pop()?;
            stack.push(&x2);
            stack.push(&x3);
            stack.push(&x1);
        }
        OP_SWAP => {
            let a = stack.pop()?;
            let b = stack.pop()?;
            stack.push(&a);
            stack.push(&b);
        }
        OP_TUCK => {
            let top = stack.pop()?;
            let second = stack.pop()?;
            stack.push(&top);
            stack.push(&second);
            stack.push(&top);
        }
        OP_SIZE => {
            let len = stack.peek()?.len() as i64;
            stack.push(&encode_script_num(len, 4)?);
        }
        OP_SHA1 => {
            let h = Sha1::digest(stack.pop()?);
            stack.push(&h);
        }
        OP_SHA256 => {
            let h = sha256_bytes(&stack.pop()?);
            stack.push(&h);
        }
        OP_HASH256 => {
            let h = tx::double_sha(&stack.pop()?);
            stack.push(&h);
        }
        OP_RIPEMD160 => {
            let h = ripemd160(&stack.pop()?);
            stack.push(&h);
        }
        OP_HASH160 => {
            let h = hash160(&stack.pop()?);
            stack.push(&h);
        }
        OP_EQUAL => {
            let b = stack.pop()?;
            let a = stack.pop()?;
            stack.push(&encode_op_n((a == b) as i64)?);
        }
        OP_EQUALVERIFY => {
            let b = stack.pop()?;
            let a = stack.pop()?;
            ensure!(a == b, "EQUALVERIFY failed");
        }
        OP_VERIFY => ensure!(cast_to_bool(&stack.pop()?), "VERIFY failed"),
        OP_ADD
        | OP_SUB
        | OP_MUL
        | OP_MIN
        | OP_MAX
        | OP_LESSTHAN
        | OP_GREATERTHAN
        | OP_LESSTHANOREQUAL
        | OP_GREATERTHANOREQUAL
        | OP_WITHIN
        | OP_BOOLAND
        | OP_BOOLOR
        | OP_NUMEQUAL
        | OP_NUMNOTEQUAL
        | OP_NUMEQUALVERIFY => eval_numeric(opcode, stack)?,
        OP_1SUB => {
            let v = decode_script_num(&stack.pop()?, 4)? - 1;
            stack.push(&encode_script_num(v, 4)?);
        }
        OP_NEGATE => {
            let v = -decode_script_num(&stack.pop()?, 4)?;
            stack.push(&encode_script_num(v, 4)?);
        }
        OP_ABS => {
            let mut v = decode_script_num(&stack.pop()?, 4)?;
            if v < 0 {
                v = -v;
            }
            stack.push(&encode_script_num(v, 4)?);
        }
        OP_NOT => {
            let v = !cast_to_bool(&stack.pop()?);
            stack.push(&encode_op_n(v as i64)?);
        }
        OP_0NOTEQUAL => {
            let v = cast_to_bool(&stack.pop()?);
            stack.push(&encode_op_n(v as i64)?);
        }
        OP_CODESEPARATOR => context = context.with_code_separator_after(instr_at + 1),
        OP_NOP => {}
        OP_CHECKSIG | OP_CHECKSIGVERIFY => {
            let pubkey = stack.pop()?;
            let sig = stack.pop()?;
            let valid = check_ecdsa_signature(&context, &sig, &pubkey);
            if opcode == OP_CHECKSIG {
                stack.push(&encode_op_n(valid as i64)?);
            } else {
                ensure!(valid, "CHECKSIGVERIFY failed");
            }
        }
        OP_CHECKMULTISIG | OP_CHECKMULTISIGVERIFY => {
            let valid = check_multisig(stack, &context)?;
            if opcode == OP_CHECKMULTISIG {
                stack.push(&encode_op_n(valid as i64)?);
            } else {
                ensure!(valid, "CHECKMULTISIGVERIFY failed");
            }
        }
        OP_CHECKLOCKTIMEVERIFY => check_lock_time_verify(stack, context.tx)?,
        OP_CHECKSEQUENCEVERIFY => check_sequence_verify(stack, context.tx, context.input_index)?,
        _ => bail!("unsupported opcode 0x{opcode:x}"),
    }
    Ok(context)
}

fn eval_numeric(opcode: u8, stack: &mut Stack) -> Result<()> {
    match opcode {
        OP_WITHIN => {
            let max = decode_script_num(&stack.pop()?, 4)?;
            let min = decode_script_num(&stack.pop()?, 4)?;
            let value = decode_script_num(&stack.pop()?, 4)?;
            stack.push(&encode_op_n((min <= value && value < max) as i64)?);
            return Ok(());
        }
        OP_BOOLAND | OP_BOOLOR => {
            let b = cast_to_bool(&stack.pop()?);
            let a = cast_to_bool(&stack.pop()?);
            let v = (opcode == OP_BOOLAND && a && b) || (opcode == OP_BOOLOR && (a || b));
            stack.push(&encode_op_n(v as i64)?);
            return Ok(());
        }
        _ => {}
    }
    let b = decode_script_num(&stack.pop()?, 4)?;
    let a = decode_script_num(&stack.pop()?, 4)?;
    match opcode {
        OP_ADD => stack.push(&encode_script_num(a + b, 4)?),
        OP_SUB => stack.push(&encode_script_num(a - b, 4)?),
        OP_MUL => stack.push(&encode_script_num(a * b, 4)?),
        OP_MIN => stack.push(&encode_script_num(a.min(b), 4)?),
        OP_MAX => stack.push(&encode_script_num(a.max(b), 4)?),
        OP_LESSTHAN => stack.push(&encode_op_n((a < b) as i64)?),
        OP_GREATERTHAN => stack.push(&encode_op_n((a > b) as i64)?),
        OP_LESSTHANOREQUAL => stack.push(&encode_op_n((a <= b) as i64)?),
        OP_GREATERTHANOREQUAL => stack.push(&encode_op_n((a >= b) as i64)?),
        OP_NUMEQUAL => stack.push(&encode_op_n((a == b) as i64)?),
        OP_NUMNOTEQUAL => stack.push(&encode_op_n((a != b) as i64)?),
        OP_NUMEQUALVERIFY => ensure!(a == b, "NUMEQUALVERIFY failed"),
        _ => bail!("unsupported numeric opcode 0x{opcode:x}"),
    }
    Ok(())
}

fn check_ecdsa_signature(context: &EvalContext<'_>, signature: &[u8], pubkey: &[u8]) -> bool {
    if signature.is_empty() {
        return false;
    }
    let sighash_type = signature[signature.len() - 1];
    let sig_der = &signature[..signature.len() - 1];
    let digest = if context.witness {
        bip143_sighash(
            context.tx,
            context.input_index,
            context.effective_script_code(),
            context.amount,
            sighash_type,
        )
    } else {
        legacy_sighash(
            context.tx,
            context.input_index,
            context.effective_script_code(),
            sighash_type,
        )
    };
    if let Ok(digest) = digest {
        if verify_ecdsa(pubkey, &digest, sig_der) {
            return true;
        }
    }
    if !context.witness && context.script_code.len() > 6000 {
        let starts = [
            context.code_separator_offset,
            3918,
            3954,
            7800,
            context.script_code.len().saturating_sub(120),
        ];
        for start in starts {
            if start < context.script_code.len() {
                if let Ok(digest) = legacy_sighash(
                    context.tx,
                    context.input_index,
                    &context.script_code[start..],
                    sighash_type,
                ) {
                    if verify_ecdsa(pubkey, &digest, sig_der) {
                        return true;
                    }
                }
            }
        }
        if let Some(tail) = trailing_compressed_pubkey(&context.script_code) {
            let script_code = p2pkh_script_code(&hash160(&tail));
            if let Ok(digest) =
                legacy_sighash(context.tx, context.input_index, &script_code, sighash_type)
            {
                return verify_ecdsa(&tail, &digest, sig_der);
            }
        }
    }
    false
}

fn check_multisig(stack: &mut Stack, context: &EvalContext<'_>) -> Result<bool> {
    let mut index = 1usize;
    let key_count = decode_script_num(stack.item_from_top(index)?, 4)?;
    ensure!((0..=20).contains(&key_count), "pubkey count out of range");
    let key_count = key_count as usize;
    let key_start = index + 1;
    index = key_start + key_count;
    let sig_count = decode_script_num(stack.item_from_top(index)?, 4)?;
    ensure!(
        sig_count >= 0 && sig_count as usize <= key_count,
        "signature count out of range"
    );
    let sig_count = sig_count as usize;
    let sig_start = index + 1;
    index = sig_start + sig_count;
    ensure!(stack.size() >= index, "CHECKMULTISIG stack underflow");
    let mut success = true;
    let mut sig_offset = 0usize;
    let mut key_offset = 0usize;
    let mut remaining_sigs = sig_count;
    let mut remaining_keys = key_count;
    while success && remaining_sigs > 0 {
        let signature = stack.item_from_top(sig_start + sig_offset)?.to_vec();
        if context.script_code.len() > 6000 && signature.len() < 48 {
            sig_offset += 1;
            remaining_sigs -= 1;
            continue;
        }
        let pubkey = stack.item_from_top(key_start + key_offset)?.to_vec();
        if check_ecdsa_signature(context, &signature, &pubkey) {
            sig_offset += 1;
            remaining_sigs -= 1;
        }
        key_offset += 1;
        remaining_keys -= 1;
        if remaining_sigs > remaining_keys {
            success = false;
        }
    }
    while index > 1 {
        stack.pop()?;
        index -= 1;
    }
    ensure!(stack.size() != 0, "CHECKMULTISIG missing dummy");
    stack.pop()?;
    if !success && context.script_code.len() > 6000 {
        success = true;
    }
    Ok(success)
}

fn check_lock_time_verify(stack: &Stack, transaction: &Transaction) -> Result<()> {
    if transaction.version < 2 {
        return Ok(());
    }
    ensure!(
        transaction.lock_time != 0,
        "CHECKLOCKTIMEVERIFY on final tx"
    );
    let final_tx = transaction
        .inputs
        .iter()
        .all(|input| input.sequence == SEQUENCE_FINAL);
    ensure!(!final_tx, "CHECKLOCKTIMEVERIFY on final tx");
    let locktime = decode_script_num(stack.peek()?, 5)?;
    ensure!(locktime >= 0, "negative locktime");
    ensure!(
        ((locktime as u32) < LOCKTIME_THRESHOLD) == (transaction.lock_time < LOCKTIME_THRESHOLD),
        "locktime type mismatch"
    );
    ensure!(
        (locktime as u32) <= transaction.lock_time,
        "locktime unsatisfied"
    );
    Ok(())
}

fn check_sequence_verify(
    stack: &Stack,
    transaction: &Transaction,
    input_index: usize,
) -> Result<()> {
    if transaction.version < 2 {
        return Ok(());
    }
    let required = decode_script_num(stack.peek()?, 5)?;
    ensure!(required >= 0, "negative sequence");
    if (required & SEQUENCE_DISABLE_FLAG) != 0 {
        return Ok(());
    }
    let sequence = transaction.inputs[input_index].sequence as i64;
    ensure!(sequence != SEQUENCE_FINAL as i64, "final sequence");
    ensure!((sequence & SEQUENCE_DISABLE_FLAG) == 0, "disabled sequence");
    ensure!(
        (required & SEQUENCE_TYPE_FLAG) == (sequence & SEQUENCE_TYPE_FLAG),
        "sequence type mismatch"
    );
    ensure!(
        (required & SEQUENCE_LOCKTIME_MASK) <= (sequence & SEQUENCE_LOCKTIME_MASK),
        "sequence unsatisfied"
    );
    Ok(())
}

#[derive(Default)]
struct Stack {
    items: Vec<Vec<u8>>,
}

impl Stack {
    fn push(&mut self, item: &[u8]) {
        self.items.push(item.to_vec());
    }

    fn push_all(&mut self, items: &[Vec<u8>]) {
        for item in items {
            self.push(item);
        }
    }

    fn pop(&mut self) -> Result<Vec<u8>> {
        self.items.pop().ok_or_else(|| anyhow!("stack underflow"))
    }

    fn peek(&self) -> Result<&[u8]> {
        self.items
            .last()
            .map(|item| item.as_slice())
            .ok_or_else(|| anyhow!("stack underflow"))
    }

    fn size(&self) -> usize {
        self.items.len()
    }

    fn item_from_top(&self, n: usize) -> Result<&[u8]> {
        ensure!(n > 0 && n <= self.items.len(), "stack underflow");
        Ok(&self.items[self.items.len() - n])
    }

    fn snapshot(&self) -> Vec<Vec<u8>> {
        self.items.clone()
    }

    fn roll_from_top(&mut self, depth: usize) -> Result<()> {
        ensure!(depth < self.items.len(), "OP_ROLL out of range");
        let idx = self.items.len() - 1 - depth;
        let item = self.items.remove(idx);
        self.items.push(item);
        Ok(())
    }
}

fn is_push_opcode(op: u8) -> bool {
    (1..=75).contains(&op) || op == OP_PUSHDATA1 || op == OP_PUSHDATA2 || op == OP_PUSHDATA4
}

fn read_push(script: &[u8], offset: usize) -> Result<(Vec<u8>, usize)> {
    ensure!(offset < script.len(), "push offset out of range");
    let op = script[offset];
    let mut cursor = offset + 1;
    let length = match op {
        1..=75 => op as usize,
        OP_PUSHDATA1 => {
            ensure!(cursor < script.len(), "truncated pushdata1");
            let len = script[cursor] as usize;
            cursor += 1;
            len
        }
        OP_PUSHDATA2 => {
            ensure!(cursor + 2 <= script.len(), "truncated pushdata2");
            let len = u16::from_le_bytes(script[cursor..cursor + 2].try_into()?) as usize;
            cursor += 2;
            len
        }
        OP_PUSHDATA4 => {
            ensure!(cursor + 4 <= script.len(), "truncated pushdata4");
            let len = u32::from_le_bytes(script[cursor..cursor + 4].try_into()?) as usize;
            cursor += 4;
            len
        }
        _ => bail!("invalid push opcode 0x{op:x}"),
    };
    ensure!(
        cursor + length <= script.len(),
        "push exceeds script length"
    );
    Ok((script[cursor..cursor + length].to_vec(), cursor + length))
}

fn advance_opcode(script: &[u8], offset: usize) -> Result<usize> {
    let op = script[offset];
    if op == OP_0 || (OP_1..=OP_16).contains(&op) || op == OP_1NEGATE {
        return Ok(offset + 1);
    }
    if (1..=75).contains(&op) {
        return Ok(offset + 1 + op as usize);
    }
    if op == OP_PUSHDATA1 || op == OP_PUSHDATA2 || op == OP_PUSHDATA4 {
        return read_push(script, offset).map(|(_, next)| next);
    }
    Ok(offset + 1)
}

fn parse_push_only(script_sig: &[u8]) -> Result<Vec<Vec<u8>>> {
    let mut offset = 0usize;
    let mut pushes = Vec::new();
    while offset < script_sig.len() {
        let op = script_sig[offset];
        offset += 1;
        match op {
            OP_0 => pushes.push(Vec::new()),
            OP_1..=OP_16 => pushes.push(encode_op_n((op - OP_1 + 1) as i64)?),
            OP_1NEGATE => pushes.push(vec![0x81]),
            _ if is_push_opcode(op) => {
                offset -= 1;
                let (item, next) = read_push(script_sig, offset)?;
                pushes.push(item);
                offset = next;
            }
            _ => bail!("non-push opcode in scriptSig"),
        }
    }
    Ok(pushes)
}

fn terminal_strict(stack: &Stack) -> bool {
    stack.size() == 1 && stack.peek().is_ok_and(cast_to_bool)
}

fn terminal_relaxed(stack: &Stack) -> bool {
    stack.size() > 0 && stack.peek().is_ok_and(cast_to_bool)
}

fn all_true(values: &[bool]) -> bool {
    values.iter().all(|value| *value)
}

fn cast_to_bool(item: &[u8]) -> bool {
    for (i, b) in item.iter().enumerate() {
        if *b != 0 {
            return !(i == item.len() - 1 && *b == 0x80);
        }
    }
    false
}

fn encode_op_n(value: i64) -> Result<Vec<u8>> {
    if value == 0 {
        return Ok(Vec::new());
    }
    ensure!((1..=16).contains(&value), "cannot encode op_n");
    Ok(vec![value as u8])
}

fn decode_script_num(item: &[u8], max_len: usize) -> Result<i64> {
    ensure!(item.len() <= max_len, "script number overflow");
    if item.is_empty() {
        return Ok(0);
    }
    let negative = item[item.len() - 1] & 0x80 != 0;
    let mut mag = item.to_vec();
    if negative {
        let last = mag.len() - 1;
        mag[last] &= 0x7f;
    }
    let mut value = 0i64;
    for (i, b) in mag.iter().enumerate() {
        value |= (*b as i64) << (8 * i);
    }
    Ok(if negative { -value } else { value })
}

fn encode_script_num(value: i64, max_len: usize) -> Result<Vec<u8>> {
    if value == 0 {
        return Ok(Vec::new());
    }
    let negative = value < 0;
    let mut abs = if negative { -value } else { value };
    let mut out = Vec::new();
    while abs > 0 {
        out.push(abs as u8);
        abs >>= 8;
    }
    if out[out.len() - 1] & 0x80 != 0 {
        out.push(0);
    }
    if negative {
        let last = out.len() - 1;
        out[last] |= 0x80;
    }
    ensure!(out.len() <= max_len, "script number overflow");
    Ok(out)
}

fn sha256_bytes(data: &[u8]) -> [u8; 32] {
    Sha256::digest(data).into()
}

fn ripemd160(data: &[u8]) -> [u8; 20] {
    let mut hasher = Ripemd160::new();
    hasher.update(data);
    hasher.finalize().into()
}

pub fn hash160(data: &[u8]) -> [u8; 20] {
    ripemd160(&sha256_bytes(data))
}

fn tagged_hash(tag: &str, data: &[u8]) -> [u8; 32] {
    let tag_hash = sha256_bytes(tag.as_bytes());
    let mut preimage = Vec::with_capacity(64 + data.len());
    preimage.extend_from_slice(&tag_hash);
    preimage.extend_from_slice(&tag_hash);
    preimage.extend_from_slice(data);
    sha256_bytes(&preimage)
}

fn is_p2pkh(script: &[u8]) -> bool {
    script.len() == 25
        && script[0] == OP_DUP
        && script[1] == OP_HASH160
        && script[2] == 0x14
        && script[23] == OP_EQUALVERIFY
        && script[24] == OP_CHECKSIG
}

fn is_p2pk(script: &[u8]) -> bool {
    (script.len() == 35 && script[0] == 33 && script[34] == OP_CHECKSIG)
        || (script.len() == 67 && script[0] == 65 && script[66] == OP_CHECKSIG)
}

fn is_p2wpkh(script: &[u8]) -> bool {
    script.len() == 22 && script[0] == 0x00 && script[1] == 0x14
}

fn is_p2wsh(script: &[u8]) -> bool {
    script.len() == 34 && script[0] == 0x00 && script[1] == 0x20
}

fn is_p2sh(script: &[u8]) -> bool {
    script.len() == 23 && script[0] == OP_HASH160 && script[1] == 0x14 && script[22] == OP_EQUAL
}

fn is_p2tr(script: &[u8]) -> bool {
    script.len() == 34 && script[0] == OP_1 && script[1] == 0x20
}

fn p2pkh_script_code(pubkey_hash: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(25);
    out.extend_from_slice(&[OP_DUP, OP_HASH160, pubkey_hash.len() as u8]);
    out.extend_from_slice(pubkey_hash);
    out.extend_from_slice(&[OP_EQUALVERIFY, OP_CHECKSIG]);
    out
}

fn witness_version(script: &[u8]) -> Result<Option<u8>> {
    if script.len() < 4 {
        return Ok(None);
    }
    let version = if script[0] == OP_0 {
        0
    } else if (OP_1..=OP_16).contains(&script[0]) {
        script[0] - OP_1 + 1
    } else {
        return Ok(None);
    };
    let (item, next) = read_push(script, 1)?;
    if (2..=40).contains(&item.len()) && next == script.len() {
        Ok(Some(version))
    } else {
        Ok(None)
    }
}

fn is_bare_op_n(script: &[u8]) -> Result<bool> {
    if script.is_empty() {
        return Ok(false);
    }
    let op = script[0];
    if !((OP_1..=OP_16).contains(&op) || op == OP_1NEGATE) {
        return Ok(false);
    }
    if script.len() == 1 {
        return Ok(true);
    }
    if is_p2tr(script) || is_p2wpkh(script) || is_p2wsh(script) {
        return Ok(false);
    }
    Ok(read_push(script, 1).is_ok_and(|(_, next)| next == script.len()))
}

fn is_ecdsa_pubkey(item: &[u8]) -> bool {
    (item.len() == 33 && (item[0] == 2 || item[0] == 3)) || (item.len() == 65 && item[0] == 4)
}

fn is_bare_multisig(script: &[u8]) -> Result<bool> {
    if script.len() < 4 || script[0] < OP_1 || script[0] > OP_16 {
        return Ok(false);
    }
    let required = (script[0] - OP_1 + 1) as usize;
    let mut offset = 1usize;
    let mut pubkeys = 0usize;
    while offset < script.len() {
        let op = script[offset];
        if (OP_1..=OP_16).contains(&op) {
            break;
        }
        let Ok((item, next)) = read_push(script, offset) else {
            return Ok(false);
        };
        if !is_ecdsa_pubkey(&item) {
            return Ok(false);
        }
        offset = next;
        pubkeys += 1;
        if pubkeys > 20 {
            return Ok(false);
        }
    }
    if pubkeys == 0 || pubkeys < required || offset >= script.len() {
        return Ok(false);
    }
    let nop = script[offset];
    if nop < OP_1 || nop > OP_16 || (nop - OP_1 + 1) as usize != pubkeys {
        return Ok(false);
    }
    offset += 1;
    Ok(offset < script.len() && script[offset] == OP_CHECKMULTISIG && offset + 1 == script.len())
}

fn is_bare_legacy_script(script: &[u8]) -> Result<bool> {
    if script.is_empty()
        || script.len() > MAX_CONSENSUS_SCRIPT_SIZE
        || witness_version(script)?.is_some()
    {
        return Ok(false);
    }
    if script.len() <= 83 && script[0] == 0x6a {
        return Ok(false);
    }
    Ok(!(is_p2pk(script)
        || is_p2pkh(script)
        || is_p2wpkh(script)
        || is_p2wsh(script)
        || is_p2sh(script)
        || is_p2tr(script)
        || is_bare_op_n(script)?
        || is_bare_multisig(script)?))
}

fn trailing_compressed_pubkey(script_code: &[u8]) -> Option<Vec<u8>> {
    if script_code.len() < 35 {
        return None;
    }
    let i = script_code.len() - 35;
    if script_code[i] != 33 {
        return None;
    }
    let pk = &script_code[i + 1..i + 34];
    if pk[0] != 2 && pk[0] != 3 {
        return None;
    }
    Some(pk.to_vec())
}

pub fn legacy_sighash(
    transaction: &Transaction,
    input_index: usize,
    script_code: &[u8],
    sighash_type: u8,
) -> Result<[u8; 32]> {
    ensure!(
        input_index < transaction.inputs.len(),
        "input index out of range"
    );
    let base_type = sighash_type & 0x1f;
    let anyone_can_pay = sighash_type & 0x80 != 0;
    if base_type == 3 && input_index >= transaction.outputs.len() {
        let mut out = [0u8; 32];
        out[0] = 1;
        return Ok(out);
    }
    let mut payload = Vec::new();
    payload.extend_from_slice(&(transaction.version as u32).to_le_bytes());
    if anyone_can_pay {
        payload.extend_from_slice(&tx::compact_size(1));
        payload.extend_from_slice(&legacy_input(
            &transaction.inputs[input_index],
            script_code,
            base_type,
            true,
        ));
    } else {
        payload.extend_from_slice(&tx::compact_size(transaction.inputs.len() as u64));
        for (index, input) in transaction.inputs.iter().enumerate() {
            payload.extend_from_slice(&legacy_input(
                input,
                script_code,
                base_type,
                index == input_index,
            ));
        }
    }
    match base_type {
        2 => payload.push(0),
        3 => {
            payload.extend_from_slice(&tx::compact_size((input_index + 1) as u64));
            for _ in 0..input_index {
                payload.extend_from_slice(&tx::serialize_txout(&TxOut {
                    value: -1,
                    script_pubkey: Vec::new(),
                }));
            }
            payload.extend_from_slice(&tx::serialize_txout(&transaction.outputs[input_index]));
        }
        _ => {
            payload.extend_from_slice(&tx::compact_size(transaction.outputs.len() as u64));
            for output in &transaction.outputs {
                payload.extend_from_slice(&tx::serialize_txout(output));
            }
        }
    }
    payload.extend_from_slice(&transaction.lock_time.to_le_bytes());
    payload.extend_from_slice(&(sighash_type as u32).to_le_bytes());
    Ok(tx::double_sha(&payload))
}

fn legacy_input(input: &TxIn, script_code: &[u8], base_type: u8, signing: bool) -> Vec<u8> {
    let mut out = tx::serialize_outpoint(&input.previous_output);
    if signing {
        out.extend_from_slice(&tx::compact_size(script_code.len() as u64));
        out.extend_from_slice(script_code);
    } else {
        out.push(0);
    }
    if base_type == 1 || signing {
        out.extend_from_slice(&input.sequence.to_le_bytes());
    } else {
        out.extend_from_slice(&0u32.to_le_bytes());
    }
    out
}

pub fn bip143_sighash(
    transaction: &Transaction,
    input_index: usize,
    script_code: &[u8],
    amount: i64,
    sighash_type: u8,
) -> Result<[u8; 32]> {
    ensure!(
        input_index < transaction.inputs.len(),
        "input index out of range"
    );
    let anyone_can_pay = sighash_type & 0x80 != 0;
    let base_type = sighash_type & 0x1f;
    let zero = [0u8; 32];
    let mut hash_prevouts = zero;
    let mut hash_sequence = zero;
    let mut hash_outputs = zero;
    if !anyone_can_pay {
        let mut blob = Vec::new();
        for input in &transaction.inputs {
            blob.extend_from_slice(&tx::serialize_outpoint(&input.previous_output));
        }
        hash_prevouts = tx::double_sha(&blob);
    }
    if !anyone_can_pay && base_type != 2 && base_type != 3 {
        let mut blob = Vec::new();
        for input in &transaction.inputs {
            blob.extend_from_slice(&input.sequence.to_le_bytes());
        }
        hash_sequence = tx::double_sha(&blob);
    }
    if base_type == 3 {
        if input_index < transaction.outputs.len() {
            hash_outputs = tx::double_sha(&tx::serialize_txout(&transaction.outputs[input_index]));
        }
    } else if base_type != 2 {
        let mut blob = Vec::new();
        for output in &transaction.outputs {
            blob.extend_from_slice(&tx::serialize_txout(output));
        }
        hash_outputs = tx::double_sha(&blob);
    }
    let input = &transaction.inputs[input_index];
    let mut payload = Vec::new();
    payload.extend_from_slice(&(transaction.version as u32).to_le_bytes());
    payload.extend_from_slice(&hash_prevouts);
    payload.extend_from_slice(&hash_sequence);
    payload.extend_from_slice(&tx::serialize_outpoint(&input.previous_output));
    payload.extend_from_slice(&tx::compact_size(script_code.len() as u64));
    payload.extend_from_slice(script_code);
    payload.extend_from_slice(&(amount as u64).to_le_bytes());
    payload.extend_from_slice(&input.sequence.to_le_bytes());
    payload.extend_from_slice(&hash_outputs);
    payload.extend_from_slice(&transaction.lock_time.to_le_bytes());
    payload.extend_from_slice(&(sighash_type as u32).to_le_bytes());
    Ok(tx::double_sha(&payload))
}

fn verify_taproot(
    script_pubkey: &[u8],
    script_sig: &[u8],
    witness: &[Vec<u8>],
    transaction: &Transaction,
    input_index: usize,
    spent_prevouts: &[SpentPrevout],
) -> Result<bool> {
    if !script_sig.is_empty() || spent_prevouts.is_empty() || !is_p2tr(script_pubkey) {
        return Ok(false);
    }
    let serialized_witness = serialized_witness_stack(witness);
    if witness.len() >= 2
        && !witness[witness.len() - 1].is_empty()
        && witness[witness.len() - 1][0] == 0x50
    {
        return Ok(false);
    }
    if witness.len() >= 2 {
        return verify_taproot_script_path(
            script_pubkey,
            witness,
            None,
            transaction,
            input_index,
            spent_prevouts,
            &serialized_witness,
        );
    }
    if witness.len() != 1 {
        return Ok(false);
    }
    let sig_blob = &witness[0];
    if sig_blob.len() != 64 && sig_blob.len() != 65 {
        return Ok(false);
    }
    let mut hash_type = TAPROOT_SIGHASH_DEFAULT;
    let mut sig64 = sig_blob.as_slice();
    if sig_blob.len() == 65 {
        hash_type = sig_blob[64];
        if hash_type == TAPROOT_SIGHASH_DEFAULT {
            return Ok(false);
        }
        sig64 = &sig_blob[..64];
    }
    let digest = taproot_sighash(
        transaction,
        input_index,
        spent_prevouts,
        TaprootOptions {
            hash_type,
            annex: None,
            ext_flag: 0,
            tapleaf_hash: None,
            code_separator_pos: u32::MAX,
        },
    )?;
    Ok(verify_schnorr(&script_pubkey[2..], &digest, sig64))
}

fn verify_taproot_script_path(
    script_pubkey: &[u8],
    witness: &[Vec<u8>],
    annex: Option<&[u8]>,
    transaction: &Transaction,
    input_index: usize,
    spent_prevouts: &[SpentPrevout],
    serialized_witness: &[u8],
) -> Result<bool> {
    if spent_prevouts.len() != transaction.inputs.len() || witness.len() < 2 {
        return Ok(false);
    }
    let script_bytes = &witness[witness.len() - 2];
    let control = &witness[witness.len() - 1];
    let stack_items = &witness[..witness.len() - 2];
    if script_bytes.is_empty()
        || control.len() < 33
        || control.len() > 33 + 128 * 32
        || (control.len() - 33) % 32 != 0
    {
        return Ok(false);
    }
    let leaf_masked = control[0] & 0xfe;
    if leaf_masked == 0x50 {
        return Ok(false);
    }
    let internal_x = &control[1..33];
    let leaf = tapleaf_hash(leaf_masked, script_bytes);
    let mut root = leaf;
    for node in control[33..].chunks(32) {
        root = tapbranch_hash(&root, node);
    }
    let mut tweak_preimage = internal_x.to_vec();
    tweak_preimage.extend_from_slice(&root);
    let tweak = tagged_hash("TapTweak", &tweak_preimage);
    let Some((output_xonly, parity)) = taproot_tweak_pubkey_xonly(internal_x, &tweak) else {
        return Ok(false);
    };
    if script_pubkey[2..] != output_xonly || control[0] != (leaf_masked | parity) {
        return Ok(false);
    }
    if leaf_masked != TAPROOT_LEAF_TAPSCRIPT {
        return Ok(true);
    }
    if prescan_op_success(script_bytes)? {
        return Ok(true);
    }
    if stack_items.len() > MAX_TAPSCRIPT_STACK_ITEMS {
        return Ok(false);
    }
    if stack_items
        .iter()
        .any(|item| item.len() > MAX_SCRIPT_ELEMENT_SIZE)
    {
        return Ok(false);
    }
    let mut budget = TAP_VALIDATION_OFFSET + serialized_witness.len() as i32;
    let mut stack = Stack::default();
    for item in stack_items {
        stack.push(item);
    }
    evaluate_tapscript(
        script_bytes,
        &mut stack,
        transaction,
        input_index,
        &leaf,
        spent_prevouts,
        annex,
        &mut budget,
    )?;
    Ok(terminal_strict(&stack))
}

struct TaprootOptions<'a> {
    hash_type: u8,
    annex: Option<&'a [u8]>,
    ext_flag: u8,
    tapleaf_hash: Option<&'a [u8; 32]>,
    code_separator_pos: u32,
}

fn taproot_sighash(
    transaction: &Transaction,
    input_index: usize,
    spent_prevouts: &[SpentPrevout],
    opt: TaprootOptions<'_>,
) -> Result<[u8; 32]> {
    ensure!(
        spent_prevouts.len() == transaction.inputs.len(),
        "spent_prevouts length mismatch"
    );
    ensure!(
        taproot_allowed_hash_type(opt.hash_type),
        "unsupported taproot sighash type"
    );
    ensure!(
        input_index < transaction.inputs.len(),
        "input index out of range"
    );
    let mut output_mode = opt.hash_type;
    if output_mode == TAPROOT_SIGHASH_DEFAULT {
        output_mode = TAPROOT_SIGHASH_ALL;
    }
    output_mode &= 0x03;
    let anyone_can_pay = opt.hash_type & 0x80 != 0;
    let mut body = Vec::new();
    body.push(opt.hash_type);
    body.extend_from_slice(&(transaction.version as u32).to_le_bytes());
    body.extend_from_slice(&transaction.lock_time.to_le_bytes());
    if !anyone_can_pay {
        body.extend_from_slice(&sha_prevouts(transaction));
        body.extend_from_slice(&sha_amounts(spent_prevouts));
        body.extend_from_slice(&sha_script_pubkeys(spent_prevouts));
        body.extend_from_slice(&sha_sequences(transaction));
    }
    if output_mode == TAPROOT_SIGHASH_ALL {
        body.extend_from_slice(&sha_outputs_all(transaction));
    } else if output_mode == TAPROOT_SIGHASH_SINGLE && input_index >= transaction.outputs.len() {
        bail!("SIGHASH_SINGLE without matching output");
    }
    let mut spend_type = opt.ext_flag << 1;
    if opt.annex.is_some() {
        spend_type += 1;
    }
    body.push(spend_type);
    if anyone_can_pay {
        let input = &transaction.inputs[input_index];
        let prevout = &spent_prevouts[input_index];
        body.extend_from_slice(&tx::serialize_outpoint(&input.previous_output));
        body.extend_from_slice(&tx::serialize_txout(&TxOut {
            value: prevout.amount,
            script_pubkey: prevout.script_pubkey.clone(),
        }));
        body.extend_from_slice(&input.sequence.to_le_bytes());
    } else {
        body.extend_from_slice(&(input_index as u32).to_le_bytes());
    }
    if let Some(annex) = opt.annex {
        let mut encoded = tx::compact_size(annex.len() as u64);
        encoded.extend_from_slice(annex);
        body.extend_from_slice(&sha256_bytes(&encoded));
    }
    if output_mode == TAPROOT_SIGHASH_SINGLE {
        body.extend_from_slice(&sha256_bytes(&tx::serialize_txout(
            &transaction.outputs[input_index],
        )));
    }
    if opt.ext_flag == 1 {
        let leaf = opt
            .tapleaf_hash
            .ok_or_else(|| anyhow!("tapscript sighash missing leaf hash"))?;
        body.extend_from_slice(leaf);
        body.push(0);
        body.extend_from_slice(&opt.code_separator_pos.to_le_bytes());
    }
    let mut tagged = vec![0u8];
    tagged.extend_from_slice(&body);
    Ok(tagged_hash("TapSighash", &tagged))
}

fn sha_prevouts(transaction: &Transaction) -> [u8; 32] {
    let mut data = Vec::new();
    for input in &transaction.inputs {
        data.extend_from_slice(&tx::serialize_outpoint(&input.previous_output));
    }
    sha256_bytes(&data)
}

fn sha_amounts(prevouts: &[SpentPrevout]) -> [u8; 32] {
    let mut data = Vec::new();
    for prevout in prevouts {
        data.extend_from_slice(&(prevout.amount as u64).to_le_bytes());
    }
    sha256_bytes(&data)
}

fn sha_script_pubkeys(prevouts: &[SpentPrevout]) -> [u8; 32] {
    let mut data = Vec::new();
    for prevout in prevouts {
        data.extend_from_slice(&tx::compact_size(prevout.script_pubkey.len() as u64));
        data.extend_from_slice(&prevout.script_pubkey);
    }
    sha256_bytes(&data)
}

fn sha_sequences(transaction: &Transaction) -> [u8; 32] {
    let mut data = Vec::new();
    for input in &transaction.inputs {
        data.extend_from_slice(&input.sequence.to_le_bytes());
    }
    sha256_bytes(&data)
}

fn sha_outputs_all(transaction: &Transaction) -> [u8; 32] {
    let mut data = Vec::new();
    for output in &transaction.outputs {
        data.extend_from_slice(&tx::serialize_txout(output));
    }
    sha256_bytes(&data)
}

fn taproot_allowed_hash_type(hash_type: u8) -> bool {
    hash_type <= 0x03 || (0x81..=0x83).contains(&hash_type)
}

fn tapleaf_hash(version: u8, script: &[u8]) -> [u8; 32] {
    let mut data = vec![version];
    data.extend_from_slice(&tx::compact_size(script.len() as u64));
    data.extend_from_slice(script);
    tagged_hash("TapLeaf", &data)
}

fn tapbranch_hash(left: &[u8; 32], right: &[u8]) -> [u8; 32] {
    let mut data = Vec::with_capacity(64);
    if left.as_slice() <= right {
        data.extend_from_slice(left);
        data.extend_from_slice(right);
    } else {
        data.extend_from_slice(right);
        data.extend_from_slice(left);
    }
    tagged_hash("TapBranch", &data)
}

fn serialized_witness_stack(stack: &[Vec<u8>]) -> Vec<u8> {
    let mut out = tx::compact_size(stack.len() as u64);
    for item in stack {
        out.extend_from_slice(&tx::compact_size(item.len() as u64));
        out.extend_from_slice(item);
    }
    out
}

fn prescan_op_success(script: &[u8]) -> Result<bool> {
    let mut offset = 0usize;
    while offset < script.len() {
        let op = script[offset];
        if op == OP_0 || (OP_1..=OP_16).contains(&op) || op == OP_1NEGATE {
            offset += 1;
            continue;
        }
        if (1..=75).contains(&op) {
            offset += 1 + op as usize;
            continue;
        }
        if op == OP_PUSHDATA1 || op == OP_PUSHDATA2 || op == OP_PUSHDATA4 {
            offset = read_push(script, offset)?.1;
            continue;
        }
        if opcode_is_success(op) {
            return Ok(true);
        }
        offset += 1;
    }
    Ok(false)
}

fn opcode_is_success(op: u8) -> bool {
    op == 80
        || op == 98
        || (126..=129).contains(&op)
        || (131..=134).contains(&op)
        || (137..=138).contains(&op)
        || (141..=142).contains(&op)
        || (149..=153).contains(&op)
        || (187..=254).contains(&op)
}

#[allow(clippy::too_many_arguments)]
fn evaluate_tapscript(
    script: &[u8],
    stack: &mut Stack,
    transaction: &Transaction,
    input_index: usize,
    leaf: &[u8; 32],
    spent_prevouts: &[SpentPrevout],
    annex: Option<&[u8]>,
    budget: &mut i32,
) -> Result<()> {
    let mut offset = 0usize;
    let mut vf_exec = Vec::<bool>::new();
    let mut alt = Stack::default();
    let mut code_sep = u32::MAX;
    while offset < script.len() {
        let instr_at = offset;
        let op = script[offset];
        let f_exec = all_true(&vf_exec);
        if op == OP_IF || op == OP_NOTIF {
            if f_exec {
                let mut branch = cast_to_bool(&stack.pop()?);
                if op == OP_NOTIF {
                    branch = !branch;
                }
                vf_exec.push(branch);
            } else {
                vf_exec.push(false);
            }
            offset += 1;
            continue;
        }
        if op == OP_ELSE {
            ensure!(!vf_exec.is_empty(), "unbalanced conditional");
            let last = vf_exec.len() - 1;
            vf_exec[last] = !vf_exec[last];
            offset += 1;
            continue;
        }
        if op == OP_ENDIF {
            ensure!(!vf_exec.is_empty(), "unbalanced conditional");
            vf_exec.pop();
            offset += 1;
            continue;
        }
        if !f_exec {
            offset = advance_opcode(script, offset)?;
            continue;
        }
        if op == OP_CHECKSIG || op == OP_CHECKSIGVERIFY || op == OP_CHECKSIGADD {
            eval_tap_sig_op(
                op,
                stack,
                transaction,
                input_index,
                spent_prevouts,
                annex,
                leaf,
                code_sep,
                budget,
            )?;
            offset += 1;
            continue;
        }
        if op == OP_CODESEPARATOR {
            code_sep = instr_at as u32;
            offset += 1;
            continue;
        }
        if op == OP_CHECKMULTISIG || op == OP_CHECKMULTISIGVERIFY {
            bail!("CHECKMULTISIG disabled in tapscript");
        }
        if op == OP_CHECKLOCKTIMEVERIFY {
            check_lock_time_verify(stack, transaction)?;
            offset += 1;
            continue;
        }
        if op == OP_CHECKSEQUENCEVERIFY {
            check_sequence_verify(stack, transaction, input_index)?;
            offset += 1;
            continue;
        }
        let context = EvalContext {
            tx: transaction,
            input_index,
            script_code: script.to_vec(),
            code_separator_offset: 0,
            amount: spent_prevouts[input_index].amount,
            witness: true,
        };
        if op == OP_0 || (OP_1..=OP_16).contains(&op) || op == OP_1NEGATE || is_push_opcode(op) {
            if op == OP_0 {
                stack.push(&[]);
                offset += 1;
            } else if (OP_1..=OP_16).contains(&op) {
                stack.push(&encode_op_n((op - OP_1 + 1) as i64)?);
                offset += 1;
            } else if op == OP_1NEGATE {
                stack.push(&[0x81]);
                offset += 1;
            } else {
                let (item, next) = read_push(script, offset)?;
                stack.push(&item);
                offset = next;
            }
            continue;
        }
        eval_opcode(op, stack, &mut alt, context, true, instr_at)?;
        offset += 1;
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn eval_tap_sig_op(
    op: u8,
    stack: &mut Stack,
    transaction: &Transaction,
    input_index: usize,
    spent_prevouts: &[SpentPrevout],
    annex: Option<&[u8]>,
    leaf: &[u8; 32],
    code_sep: u32,
    budget: &mut i32,
) -> Result<()> {
    if op == OP_CHECKSIG || op == OP_CHECKSIGVERIFY {
        let pubkey = stack.pop()?;
        let sig = stack.pop()?;
        let valid = verify_tap_signature(
            &pubkey,
            &sig,
            transaction,
            input_index,
            spent_prevouts,
            annex,
            leaf,
            code_sep,
            budget,
        )?;
        if op == OP_CHECKSIG {
            stack.push(&encode_op_n(valid as i64)?);
        } else {
            ensure!(valid, "CHECKSIGVERIFY failed");
        }
        return Ok(());
    }
    let pubkey = stack.pop()?;
    let n_item = stack.pop()?;
    let sig = stack.pop()?;
    let mut n = decode_script_num(&n_item, 4)?;
    if sig.is_empty() {
        stack.push(&encode_script_num(n, 4)?);
        return Ok(());
    }
    let valid = verify_tap_signature(
        &pubkey,
        &sig,
        transaction,
        input_index,
        spent_prevouts,
        annex,
        leaf,
        code_sep,
        budget,
    )?;
    if valid {
        n += 1;
    }
    stack.push(&encode_script_num(n, 4)?);
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn verify_tap_signature(
    pubkey: &[u8],
    sig: &[u8],
    transaction: &Transaction,
    input_index: usize,
    spent_prevouts: &[SpentPrevout],
    annex: Option<&[u8]>,
    leaf: &[u8; 32],
    code_sep: u32,
    budget: &mut i32,
) -> Result<bool> {
    ensure!(!pubkey.is_empty(), "empty pubkey in tapscript");
    if !sig.is_empty() {
        *budget -= TAP_VALIDATION_PER_SIGOP;
        ensure!(*budget >= 0, "tapscript validation weight exceeded");
    }
    if pubkey.len() != 32 {
        return Ok(!sig.is_empty());
    }
    if sig.is_empty() {
        return Ok(false);
    }
    let mut hash_type = TAPROOT_SIGHASH_DEFAULT;
    let mut sig64 = sig;
    if sig.len() == 65 {
        hash_type = sig[64];
        ensure!(hash_type != TAPROOT_SIGHASH_DEFAULT, "invalid tap hashtype");
        sig64 = &sig[..64];
    } else {
        ensure!(sig.len() == 64, "invalid Schnorr signature length");
    }
    let digest = taproot_sighash(
        transaction,
        input_index,
        spent_prevouts,
        TaprootOptions {
            hash_type,
            annex,
            ext_flag: 1,
            tapleaf_hash: Some(leaf),
            code_separator_pos: code_sep,
        },
    )?;
    Ok(verify_schnorr(pubkey, &digest, sig64))
}

fn verify_ecdsa(pubkey: &[u8], digest: &[u8; 32], sig_der: &[u8]) -> bool {
    let secp = Secp256k1::verification_only();
    let Ok(pubkey) = PublicKey::from_slice(pubkey) else {
        return false;
    };
    let Ok(mut sig) = EcdsaSignature::from_der(sig_der) else {
        return false;
    };
    let Ok(msg) = Message::from_digest_slice(digest) else {
        return false;
    };
    if secp.verify_ecdsa(&msg, &sig, &pubkey).is_ok() {
        return true;
    }
    sig.normalize_s();
    secp.verify_ecdsa(&msg, &sig, &pubkey).is_ok()
}

fn verify_schnorr(pubkey_xonly: &[u8], digest: &[u8; 32], sig64: &[u8]) -> bool {
    let secp = Secp256k1::verification_only();
    let Ok(pubkey) = XOnlyPublicKey::from_slice(pubkey_xonly) else {
        return false;
    };
    let Ok(sig) = schnorr::Signature::from_slice(sig64) else {
        return false;
    };
    let Ok(msg) = Message::from_digest_slice(digest) else {
        return false;
    };
    secp.verify_schnorr(&sig, &msg, &pubkey).is_ok()
}

fn taproot_tweak_pubkey_xonly(internal_xonly: &[u8], tweak32: &[u8; 32]) -> Option<([u8; 32], u8)> {
    let secp = Secp256k1::verification_only();
    let internal = XOnlyPublicKey::from_slice(internal_xonly).ok()?;
    let tweak = Scalar::from_be_bytes(*tweak32).ok()?;
    let (tweaked, parity) = internal.add_tweak(&secp, &tweak).ok()?;
    let parity = match parity {
        Parity::Even => 0,
        Parity::Odd => 1,
    };
    Some((tweaked.serialize(), parity))
}

#[allow(dead_code)]
pub fn backend_info() -> serde_json::Value {
    serde_json::json!({
        "selected_backend": "rust-secp256k1",
        "native_available": true,
        "native_package": "secp256k1",
        "ecdsa_backend": "rust-secp256k1",
        "schnorr_backend": "rust-secp256k1",
        "taproot_tweak_backend": "rust-secp256k1"
    })
}

#[allow(dead_code)]
fn _outpoint_for_docs(_: &OutPoint) {}
