const std = @import("std");
const crypto = @import("crypto.zig");
const tx = @import("tx.zig");

const OP_0 = 0x00;
const OP_PUSHDATA1 = 0x4c;
const OP_PUSHDATA2 = 0x4d;
const OP_1NEGATE = 0x4f;
const OP_1 = 0x51;
const OP_16 = 0x60;
const OP_NOP = 0x61;
const OP_IF = 0x63;
const OP_NOTIF = 0x64;
const OP_ELSE = 0x67;
const OP_ENDIF = 0x68;
const OP_VERIFY = 0x69;
const OP_TOALTSTACK = 0x6b;
const OP_FROMALTSTACK = 0x6c;
const OP_2DROP = 0x6d;
const OP_2DUP = 0x6e;
const OP_3DUP = 0x6f;
const OP_2OVER = 0x70;
const OP_2SWAP = 0x72;
const OP_IFDUP = 0x73;
const OP_DEPTH = 0x74;
const OP_DROP = 0x75;
const OP_DUP = 0x76;
const OP_NIP = 0x77;
const OP_OVER = 0x78;
const OP_PICK = 0x79;
const OP_ROLL = 0x7a;
const OP_ROT = 0x7b;
const OP_SWAP = 0x7c;
const OP_TUCK = 0x7d;
const OP_SIZE = 0x82;
const OP_EQUAL = 0x87;
const OP_EQUALVERIFY = 0x88;
const OP_1ADD = 0x8b;
const OP_1SUB = 0x8c;
const OP_NEGATE = 0x8f;
const OP_ABS = 0x90;
const OP_NOT = 0x91;
const OP_0NOTEQUAL = 0x92;
const OP_ADD = 0x93;
const OP_SUB = 0x94;
const OP_MUL = 0x95;
const OP_BOOLAND = 0x9a;
const OP_BOOLOR = 0x9b;
const OP_NUMEQUAL = 0x9c;
const OP_NUMEQUALVERIFY = 0x9d;
const OP_NUMNOTEQUAL = 0x9e;
const OP_LESSTHAN = 0x9f;
const OP_GREATERTHAN = 0xa0;
const OP_LESSTHANOREQUAL = 0xa1;
const OP_GREATERTHANOREQUAL = 0xa2;
const OP_MIN = 0xa3;
const OP_MAX = 0xa4;
const OP_WITHIN = 0xa5;
const OP_RIPEMD160 = 0xa6;
const OP_SHA1 = 0xa7;
const OP_SHA256 = 0xa8;
const OP_HASH160 = 0xa9;
const OP_HASH256 = 0xaa;
const OP_CODESEPARATOR = 0xab;
const OP_CHECKSIG = 0xac;
const OP_CHECKSIGVERIFY = 0xad;
const OP_CHECKMULTISIG = 0xae;
const OP_CHECKMULTISIGVERIFY = 0xaf;
const OP_CHECKLOCKTIMEVERIFY = 0xb1;
const OP_CHECKSEQUENCEVERIFY = 0xb2;
const OP_CHECKSIGADD = 0xba;

const SIGHASH_ALL = 0x01;
const SIGHASH_NONE = 0x02;
const SIGHASH_SINGLE = 0x03;
const SIGHASH_ANYONECANPAY = 0x80;
const LOCKTIME_THRESHOLD = 500_000_000;
const SEQUENCE_LOCKTIME_DISABLE_FLAG: u32 = 1 << 31;
const SEQUENCE_LOCKTIME_TYPE_FLAG: u32 = 1 << 22;
const SEQUENCE_LOCKTIME_MASK: u32 = 0x0000ffff;

pub const SpentPrevout = struct {
    amount: i64,
    script_pubkey: []const u8,
};

const VerifyMode = enum { legacy, witness_v0 };

const EvalContext = struct {
    transaction: tx.Transaction,
    input_index: usize,
    amount: i64,
    script_code: []const u8,
    mode: VerifyMode,
    verifier: *crypto.NativeVerifier,
    code_separator_offset: usize = 0,
};

pub fn verifyInput(
    allocator: std.mem.Allocator,
    transaction: tx.Transaction,
    input_index: usize,
    spent_prevouts: []const SpentPrevout,
) !void {
    if (input_index >= transaction.inputs.len or input_index >= spent_prevouts.len) return error.InputIndexOutOfRange;
    const script_pubkey = spent_prevouts[input_index].script_pubkey;
    const witness = if (input_index < transaction.witness.len) transaction.witness[input_index] else &.{};
    var verifier = try crypto.NativeVerifier.create();
    defer verifier.destroy();
    if (isP2WSH(script_pubkey)) {
        return verifyP2WSH(allocator, transaction, input_index, spent_prevouts[input_index].amount, transaction.inputs[input_index].script_sig, script_pubkey, witness, &verifier);
    }
    if (isP2SH(script_pubkey)) {
        return verifyP2SH(allocator, transaction, input_index, spent_prevouts[input_index].amount, transaction.inputs[input_index].script_sig, script_pubkey, witness, &verifier);
    }
    if (isP2PKH(script_pubkey)) {
        return verifyP2PKH(allocator, transaction, input_index, spent_prevouts[input_index].amount, transaction.inputs[input_index].script_sig, script_pubkey, witness, &verifier);
    }
    if (isP2WPKH(script_pubkey)) {
        return verifyP2WPKH(allocator, transaction, input_index, spent_prevouts[input_index].amount, transaction.inputs[input_index].script_sig, script_pubkey, witness, &verifier);
    }
    if (isP2PK(script_pubkey) or isBareOpN(script_pubkey) or isBareLegacy(script_pubkey)) {
        if (witness.len != 0) return error.LegacyWitnessUnexpected;
        var stack = Stack.init(allocator);
        defer stack.deinit();
        try evaluate(allocator, transaction.inputs[input_index].script_sig, &stack, null);
        var context = EvalContext{ .transaction = transaction, .input_index = input_index, .amount = spent_prevouts[input_index].amount, .script_code = script_pubkey, .mode = .legacy, .verifier = &verifier };
        try evaluate(allocator, script_pubkey, &stack, &context);
        if (!terminalRelaxed(&stack)) return error.ScriptTerminalFalse;
        return;
    }
    if (isP2TR(script_pubkey)) {
        return error.SignatureVerifierNotImplemented;
    }
    return error.UnsupportedScriptTemplate;
}

fn verifyP2PKH(
    allocator: std.mem.Allocator,
    transaction: tx.Transaction,
    input_index: usize,
    amount: i64,
    script_sig: []const u8,
    script_pubkey: []const u8,
    witness: []const []const u8,
    verifier: *crypto.NativeVerifier,
) !void {
    if (witness.len != 0) return error.LegacyWitnessUnexpected;
    var stack = Stack.init(allocator);
    defer stack.deinit();
    try evaluate(allocator, script_sig, &stack, null);
    var context = EvalContext{ .transaction = transaction, .input_index = input_index, .amount = amount, .script_code = script_pubkey, .mode = .legacy, .verifier = verifier };
    try evaluate(allocator, script_pubkey, &stack, &context);
    if (!terminalRelaxed(&stack)) return error.ScriptTerminalFalse;
}

fn verifyP2WPKH(
    allocator: std.mem.Allocator,
    transaction: tx.Transaction,
    input_index: usize,
    amount: i64,
    script_sig: []const u8,
    script_pubkey: []const u8,
    witness: []const []const u8,
    verifier: *crypto.NativeVerifier,
) !void {
    if (script_sig.len != 0) return error.WitnessScriptSigNotEmpty;
    if (witness.len != 2) return error.InvalidP2WPKHWitness;
    const script_code = try p2pkhScriptCode(allocator, script_pubkey[2..22]);
    defer allocator.free(script_code);
    var stack = Stack.init(allocator);
    defer stack.deinit();
    try stack.push(witness[0]);
    try stack.push(witness[1]);
    var context = EvalContext{ .transaction = transaction, .input_index = input_index, .amount = amount, .script_code = script_code, .mode = .witness_v0, .verifier = verifier };
    try evaluate(allocator, script_code, &stack, &context);
    if (!terminalStrict(&stack)) return error.ScriptTerminalFalse;
}

fn verifyP2WSH(
    allocator: std.mem.Allocator,
    transaction: tx.Transaction,
    input_index: usize,
    amount: i64,
    script_sig: []const u8,
    script_pubkey: []const u8,
    witness: []const []const u8,
    verifier: *crypto.NativeVerifier,
) !void {
    if (script_sig.len != 0) return error.WitnessScriptSigNotEmpty;
    if (witness.len < 1) return error.WitnessStackEmpty;
    const script = witness[witness.len - 1];
    const hash = crypto.sha256(script);
    if (!std.mem.eql(u8, hash[0..], script_pubkey[2..34])) return error.WitnessScriptHashMismatch;
    var stack = Stack.init(allocator);
    defer stack.deinit();
    for (witness[0 .. witness.len - 1]) |item| try stack.push(item);
    var context = EvalContext{ .transaction = transaction, .input_index = input_index, .amount = amount, .script_code = script, .mode = .witness_v0, .verifier = verifier };
    try evaluate(allocator, script, &stack, &context);
    if (!terminalStrict(&stack)) return error.ScriptTerminalFalse;
}

fn verifyP2SH(
    allocator: std.mem.Allocator,
    transaction: tx.Transaction,
    input_index: usize,
    amount: i64,
    script_sig: []const u8,
    script_pubkey: []const u8,
    witness: []const []const u8,
    verifier: *crypto.NativeVerifier,
) !void {
    const pushes = try parsePushOnly(allocator, script_sig);
    defer {
        for (pushes) |item| allocator.free(item);
        allocator.free(pushes);
    }
    if (pushes.len == 0) return error.P2SHMissingRedeemScript;
    const redeem = pushes[pushes.len - 1];
    const redeem_hash = crypto.hash160(redeem);
    if (!std.mem.eql(u8, redeem_hash[0..], script_pubkey[2..22])) return error.P2SHHashMismatch;
    if (isP2WSH(redeem)) {
        return verifyP2WSHWitnessProgram(allocator, transaction, input_index, amount, redeem[2..34], witness, verifier);
    }
    if (isP2WPKH(redeem)) return verifyP2WPKH(allocator, transaction, input_index, amount, &.{}, redeem, witness, verifier);
    if (witness.len != 0) return error.LegacyWitnessUnexpected;
    var stack = Stack.init(allocator);
    defer stack.deinit();
    for (pushes[0 .. pushes.len - 1]) |item| try stack.push(item);
    var context = EvalContext{ .transaction = transaction, .input_index = input_index, .amount = amount, .script_code = redeem, .mode = .legacy, .verifier = verifier };
    try evaluate(allocator, redeem, &stack, &context);
    if (!terminalRelaxed(&stack)) return error.ScriptTerminalFalse;
}

fn verifyP2WSHWitnessProgram(
    allocator: std.mem.Allocator,
    transaction: tx.Transaction,
    input_index: usize,
    amount: i64,
    program: []const u8,
    witness: []const []const u8,
    verifier: *crypto.NativeVerifier,
) !void {
    if (witness.len < 1) return error.WitnessStackEmpty;
    const script = witness[witness.len - 1];
    const hash = crypto.sha256(script);
    if (!std.mem.eql(u8, hash[0..], program)) return error.WitnessScriptHashMismatch;
    var stack = Stack.init(allocator);
    defer stack.deinit();
    for (witness[0 .. witness.len - 1]) |item| try stack.push(item);
    var context = EvalContext{ .transaction = transaction, .input_index = input_index, .amount = amount, .script_code = script, .mode = .witness_v0, .verifier = verifier };
    try evaluate(allocator, script, &stack, &context);
    if (!terminalStrict(&stack)) return error.ScriptTerminalFalse;
}

fn evaluate(allocator: std.mem.Allocator, script: []const u8, stack: *Stack, context: ?*EvalContext) !void {
    var offset: usize = 0;
    var alt = Stack.init(allocator);
    defer alt.deinit();
    var conditions: std.ArrayList(bool) = .empty;
    defer conditions.deinit(allocator);
    while (offset < script.len) {
        const opcode = script[offset];
        const active = conditionActive(conditions.items);
        if (opcode == OP_0) {
            if (active) try stack.push(&.{});
            offset += 1;
        } else if (opcode >= OP_1 and opcode <= OP_16) {
            const value: u8 = opcode - OP_1 + 1;
            if (active) try stack.push(&.{value});
            offset += 1;
        } else if (opcode == OP_1NEGATE) {
            if (active) try stack.push(&.{0x81});
            offset += 1;
        } else if (opcode > 0 and opcode < OP_PUSHDATA1) {
            const len: usize = opcode;
            if (offset + 1 + len > script.len) return error.TruncatedPush;
            if (active) try stack.push(script[offset + 1 .. offset + 1 + len]);
            offset += 1 + len;
        } else if (opcode == OP_PUSHDATA1) {
            if (offset + 2 > script.len) return error.TruncatedPush;
            const len = script[offset + 1];
            if (offset + 2 + len > script.len) return error.TruncatedPush;
            if (active) try stack.push(script[offset + 2 .. offset + 2 + len]);
            offset += 2 + len;
        } else if (opcode == OP_PUSHDATA2) {
            if (offset + 3 > script.len) return error.TruncatedPush;
            const len = std.mem.readInt(u16, script[offset + 1 ..][0..2], .little);
            if (offset + 3 + len > script.len) return error.TruncatedPush;
            if (active) try stack.push(script[offset + 3 .. offset + 3 + len]);
            offset += 3 + len;
        } else if (opcode == OP_IF or opcode == OP_NOTIF) {
            const parent_active = active;
            var branch_active = false;
            if (parent_active) {
                const item = try stack.pop();
                defer stack.allocator.free(item);
                const truth = castToBool(item);
                branch_active = if (opcode == OP_IF) truth else !truth;
            }
            try conditions.append(allocator, parent_active and branch_active);
            offset += 1;
        } else if (opcode == OP_ELSE) {
            if (conditions.items.len == 0) return error.UnbalancedConditional;
            const parent_active = conditionActive(conditions.items[0 .. conditions.items.len - 1]);
            conditions.items[conditions.items.len - 1] = parent_active and !conditions.items[conditions.items.len - 1];
            offset += 1;
        } else if (opcode == OP_ENDIF) {
            if (conditions.items.len == 0) return error.UnbalancedConditional;
            _ = conditions.pop();
            offset += 1;
        } else if (opcode == OP_CODESEPARATOR) {
            if (active and context != null) context.?.code_separator_offset = offset + 1;
            offset += 1;
        } else {
            if (active) try evalOpcode(allocator, opcode, stack, &alt, context);
            offset += 1;
        }
    }
    if (conditions.items.len != 0) return error.UnbalancedConditional;
}

fn evalOpcode(allocator: std.mem.Allocator, opcode: u8, stack: *Stack, alt: *Stack, context: ?*EvalContext) !void {
    switch (opcode) {
        OP_DROP => {
            const item = try stack.pop();
            stack.allocator.free(item);
        },
        OP_2DROP => {
            const a = try stack.pop();
            stack.allocator.free(a);
            const b = try stack.pop();
            stack.allocator.free(b);
        },
        OP_TOALTSTACK => {
            const item = try stack.pop();
            defer stack.allocator.free(item);
            try alt.push(item);
        },
        OP_FROMALTSTACK => {
            const item = try alt.pop();
            defer alt.allocator.free(item);
            try stack.push(item);
        },
        OP_DUP => {
            const item = try stack.peek();
            try stack.push(item);
        },
        OP_2DUP => {
            if (stack.items.items.len < 2) return error.StackUnderflow;
            const a = stack.items.items[stack.items.items.len - 2];
            const b = stack.items.items[stack.items.items.len - 1];
            try stack.push(a);
            try stack.push(b);
        },
        OP_3DUP => {
            if (stack.items.items.len < 3) return error.StackUnderflow;
            const a = stack.items.items[stack.items.items.len - 3];
            const b = stack.items.items[stack.items.items.len - 2];
            const c = stack.items.items[stack.items.items.len - 1];
            try stack.push(a);
            try stack.push(b);
            try stack.push(c);
        },
        OP_2OVER => {
            if (stack.items.items.len < 4) return error.StackUnderflow;
            const a = stack.items.items[stack.items.items.len - 4];
            const b = stack.items.items[stack.items.items.len - 3];
            try stack.push(a);
            try stack.push(b);
        },
        OP_2SWAP => {
            if (stack.items.items.len < 4) return error.StackUnderflow;
            const d = try stack.pop();
            defer stack.allocator.free(d);
            const c = try stack.pop();
            defer stack.allocator.free(c);
            const b = try stack.pop();
            defer stack.allocator.free(b);
            const a = try stack.pop();
            defer stack.allocator.free(a);
            try stack.push(c);
            try stack.push(d);
            try stack.push(a);
            try stack.push(b);
        },
        OP_IFDUP => {
            const item = try stack.peek();
            if (castToBool(item)) try stack.push(item);
        },
        OP_DEPTH => try stack.pushNum(@intCast(stack.items.items.len)),
        OP_NIP => {
            if (stack.items.items.len < 2) return error.StackUnderflow;
            const top = try stack.pop();
            defer stack.allocator.free(top);
            const second = try stack.pop();
            stack.allocator.free(second);
            try stack.push(top);
        },
        OP_OVER => {
            if (stack.items.items.len < 2) return error.StackUnderflow;
            try stack.push(stack.items.items[stack.items.items.len - 2]);
        },
        OP_PICK, OP_ROLL => {
            const n = try stack.popNum();
            if (n < 0 or @as(usize, @intCast(n)) >= stack.items.items.len) return error.StackUnderflow;
            const index = stack.items.items.len - 1 - @as(usize, @intCast(n));
            if (opcode == OP_PICK) {
                try stack.push(stack.items.items[index]);
            } else {
                const item = stack.items.orderedRemove(index);
                defer stack.allocator.free(item);
                try stack.push(item);
            }
        },
        OP_ROT => {
            if (stack.items.items.len < 3) return error.StackUnderflow;
            const c = try stack.pop();
            defer stack.allocator.free(c);
            const b = try stack.pop();
            defer stack.allocator.free(b);
            const a = try stack.pop();
            defer stack.allocator.free(a);
            try stack.push(b);
            try stack.push(c);
            try stack.push(a);
        },
        OP_SWAP => {
            if (stack.items.items.len < 2) return error.StackUnderflow;
            const b = try stack.pop();
            defer stack.allocator.free(b);
            const a = try stack.pop();
            defer stack.allocator.free(a);
            try stack.push(b);
            try stack.push(a);
        },
        OP_TUCK => {
            if (stack.items.items.len < 2) return error.StackUnderflow;
            const top = stack.items.items[stack.items.items.len - 1];
            try stack.insert(stack.items.items.len - 2, top);
        },
        OP_SIZE => {
            const item = try stack.peek();
            try stack.pushNum(@intCast(item.len));
        },
        OP_EQUAL, OP_EQUALVERIFY => {
            const b = try stack.pop();
            defer stack.allocator.free(b);
            const a = try stack.pop();
            defer stack.allocator.free(a);
            try stack.pushNum(if (std.mem.eql(u8, a, b)) 1 else 0);
            if (opcode == OP_EQUALVERIFY) {
                const result = try stack.pop();
                defer stack.allocator.free(result);
                if (!castToBool(result)) return error.EqualVerifyFailed;
            }
        },
        OP_1ADD => {
            const a = try stack.popNum();
            try stack.pushNum(a + 1);
        },
        OP_1SUB => {
            const a = try stack.popNum();
            try stack.pushNum(a - 1);
        },
        OP_NEGATE => {
            const a = try stack.popNum();
            try stack.pushNum(-a);
        },
        OP_ABS => {
            const a = try stack.popNum();
            try stack.pushNum(if (a < 0) -a else a);
        },
        OP_NOT => {
            const a = try stack.popNum();
            try stack.pushNum(if (a == 0) 1 else 0);
        },
        OP_0NOTEQUAL => {
            const a = try stack.popNum();
            try stack.pushNum(if (a != 0) 1 else 0);
        },
        OP_NUMEQUAL, OP_NUMEQUALVERIFY => {
            const b = try stack.popNum();
            const a = try stack.popNum();
            try stack.pushNum(if (a == b) 1 else 0);
            if (opcode == OP_NUMEQUALVERIFY) {
                const result = try stack.pop();
                defer stack.allocator.free(result);
                if (!castToBool(result)) return error.NumEqualVerifyFailed;
            }
        },
        OP_NUMNOTEQUAL => {
            const b = try stack.popNum();
            const a = try stack.popNum();
            try stack.pushNum(if (a != b) 1 else 0);
        },
        OP_ADD => {
            const b = try stack.popNum();
            const a = try stack.popNum();
            try stack.pushNum(a + b);
        },
        OP_SUB => {
            const b = try stack.popNum();
            const a = try stack.popNum();
            try stack.pushNum(a - b);
        },
        OP_MUL => {
            const b = try stack.popNum();
            const a = try stack.popNum();
            try stack.pushNum(a * b);
        },
        OP_BOOLAND => {
            const b = try stack.popNum();
            const a = try stack.popNum();
            try stack.pushNum(if (a != 0 and b != 0) 1 else 0);
        },
        OP_BOOLOR => {
            const b = try stack.popNum();
            const a = try stack.popNum();
            try stack.pushNum(if (a != 0 or b != 0) 1 else 0);
        },
        OP_LESSTHAN => {
            const b = try stack.popNum();
            const a = try stack.popNum();
            try stack.pushNum(if (a < b) 1 else 0);
        },
        OP_GREATERTHAN => {
            const b = try stack.popNum();
            const a = try stack.popNum();
            try stack.pushNum(if (a > b) 1 else 0);
        },
        OP_LESSTHANOREQUAL => {
            const b = try stack.popNum();
            const a = try stack.popNum();
            try stack.pushNum(if (a <= b) 1 else 0);
        },
        OP_GREATERTHANOREQUAL => {
            const b = try stack.popNum();
            const a = try stack.popNum();
            try stack.pushNum(if (a >= b) 1 else 0);
        },
        OP_MIN => {
            const b = try stack.popNum();
            const a = try stack.popNum();
            try stack.pushNum(if (a < b) a else b);
        },
        OP_MAX => {
            const b = try stack.popNum();
            const a = try stack.popNum();
            try stack.pushNum(if (a > b) a else b);
        },
        OP_WITHIN => {
            const max = try stack.popNum();
            const min = try stack.popNum();
            const x = try stack.popNum();
            try stack.pushNum(if (min <= x and x < max) 1 else 0);
        },
        OP_RIPEMD160 => {
            const item = try stack.pop();
            defer stack.allocator.free(item);
            const hash = crypto.ripemd160(item);
            try stack.push(hash[0..]);
        },
        OP_SHA1 => {
            const item = try stack.pop();
            defer stack.allocator.free(item);
            const hash = crypto.sha1(item);
            try stack.push(hash[0..]);
        },
        OP_SHA256 => {
            const item = try stack.pop();
            defer stack.allocator.free(item);
            const hash = crypto.sha256(item);
            try stack.push(hash[0..]);
        },
        OP_HASH160 => {
            const item = try stack.pop();
            defer stack.allocator.free(item);
            const hash = crypto.hash160(item);
            try stack.push(hash[0..]);
        },
        OP_HASH256 => {
            const item = try stack.pop();
            defer stack.allocator.free(item);
            const hash = crypto.doubleSha256(item);
            try stack.push(hash[0..]);
        },
        OP_VERIFY => {
            const item = try stack.pop();
            defer stack.allocator.free(item);
            if (!castToBool(item)) return error.VerifyFailed;
        },
        OP_NOP => {},
        OP_CHECKSIG, OP_CHECKSIGVERIFY => {
            if (context == null) return error.SignatureVerifierNotImplemented;
            const pubkey = try stack.pop();
            defer stack.allocator.free(pubkey);
            const signature = try stack.pop();
            defer stack.allocator.free(signature);
            const valid = try checkSignature(allocator, context.?, signature, pubkey);
            if (opcode == OP_CHECKSIGVERIFY) {
                if (!valid) return error.ChecksigVerifyFailed;
            } else {
                try stack.pushNum(if (valid) 1 else 0);
            }
        },
        OP_CHECKMULTISIG, OP_CHECKMULTISIGVERIFY => {
            if (context == null) return error.SignatureVerifierNotImplemented;
            const valid = try checkMultiSig(allocator, context.?, stack);
            if (opcode == OP_CHECKMULTISIGVERIFY) {
                if (!valid) return error.CheckmultisigVerifyFailed;
            } else {
                try stack.pushNum(if (valid) 1 else 0);
            }
        },
        OP_CHECKLOCKTIMEVERIFY => {
            if (context == null) return error.SignatureVerifierNotImplemented;
            try checkLockTime(context.?, stack);
        },
        OP_CHECKSEQUENCEVERIFY => {
            if (context == null) return error.SignatureVerifierNotImplemented;
            try checkSequence(context.?, stack);
        },
        OP_CHECKSIGADD => return error.SignatureVerifierNotImplemented,
        else => return error.UnsupportedOpcode,
    }
}

fn parsePushOnly(allocator: std.mem.Allocator, script: []const u8) ![][]const u8 {
    var pushes: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (pushes.items) |item| allocator.free(item);
        pushes.deinit(allocator);
    }
    var offset: usize = 0;
    while (offset < script.len) {
        const opcode = script[offset];
        if (opcode == OP_0) {
            try pushes.append(allocator, try allocator.dupe(u8, &.{}));
            offset += 1;
        } else if (opcode == OP_1NEGATE) {
            try pushes.append(allocator, try allocator.dupe(u8, &.{0x81}));
            offset += 1;
        } else if (opcode >= OP_1 and opcode <= OP_16) {
            const value: u8 = opcode - OP_1 + 1;
            try pushes.append(allocator, try allocator.dupe(u8, &.{value}));
            offset += 1;
        } else if (opcode > 0 and opcode < OP_PUSHDATA1) {
            const len: usize = opcode;
            if (offset + 1 + len > script.len) return error.TruncatedPush;
            try pushes.append(allocator, try allocator.dupe(u8, script[offset + 1 .. offset + 1 + len]));
            offset += 1 + len;
        } else if (opcode == OP_PUSHDATA1) {
            if (offset + 2 > script.len) return error.TruncatedPush;
            const len = script[offset + 1];
            if (offset + 2 + len > script.len) return error.TruncatedPush;
            try pushes.append(allocator, try allocator.dupe(u8, script[offset + 2 .. offset + 2 + len]));
            offset += 2 + len;
        } else if (opcode == OP_PUSHDATA2) {
            if (offset + 3 > script.len) return error.TruncatedPush;
            const len = std.mem.readInt(u16, script[offset + 1 ..][0..2], .little);
            if (offset + 3 + len > script.len) return error.TruncatedPush;
            try pushes.append(allocator, try allocator.dupe(u8, script[offset + 3 .. offset + 3 + len]));
            offset += 3 + len;
        } else {
            return error.ScriptSigNotPushOnly;
        }
    }
    return pushes.toOwnedSlice(allocator);
}

fn checkSignature(allocator: std.mem.Allocator, context: *const EvalContext, signature: []const u8, pubkey: []const u8) !bool {
    if (signature.len == 0) return false;
    const sighash_type = signature[signature.len - 1];
    const sig_der = signature[0 .. signature.len - 1];
    const effective_script_code = if (context.code_separator_offset < context.script_code.len) context.script_code[context.code_separator_offset..] else &.{};
    const digest = switch (context.mode) {
        .legacy => try legacySighash(allocator, context.transaction, context.input_index, effective_script_code, signature, sighash_type),
        .witness_v0 => try bip143Sighash(allocator, context.transaction, context.input_index, effective_script_code, context.amount, sighash_type),
    };
    return context.verifier.verifyEcdsaDer(pubkey, sig_der, &digest);
}

fn checkLockTime(context: *const EvalContext, stack: *Stack) !void {
    const item = try stack.peek();
    const lock_time = try decodeScriptNum(item);
    if (lock_time < 0) return error.NegativeLockTime;
    const lock_time_u: u32 = @intCast(lock_time);
    if ((lock_time_u < LOCKTIME_THRESHOLD and context.transaction.lock_time >= LOCKTIME_THRESHOLD) or
        (lock_time_u >= LOCKTIME_THRESHOLD and context.transaction.lock_time < LOCKTIME_THRESHOLD))
    {
        return error.LockTimeTypeMismatch;
    }
    if (lock_time_u > context.transaction.lock_time) return error.LockTimeUnsatisfied;
    if (context.transaction.inputs[context.input_index].sequence == 0xffff_ffff) return error.LockTimeFinalInput;
}

fn checkSequence(context: *const EvalContext, stack: *Stack) !void {
    const item = try stack.peek();
    const sequence = try decodeScriptNum(item);
    if (sequence < 0) return error.NegativeSequence;
    const sequence_u: u32 = @intCast(sequence);
    if ((sequence_u & SEQUENCE_LOCKTIME_DISABLE_FLAG) != 0) return;
    if (context.transaction.version < 2) return error.SequenceVersionTooLow;
    const input_sequence = context.transaction.inputs[context.input_index].sequence;
    if ((input_sequence & SEQUENCE_LOCKTIME_DISABLE_FLAG) != 0) return error.SequenceDisabledInput;
    const mask = SEQUENCE_LOCKTIME_TYPE_FLAG | SEQUENCE_LOCKTIME_MASK;
    if ((sequence_u & SEQUENCE_LOCKTIME_TYPE_FLAG) != (input_sequence & SEQUENCE_LOCKTIME_TYPE_FLAG)) return error.SequenceTypeMismatch;
    if ((sequence_u & mask) > (input_sequence & mask)) return error.SequenceUnsatisfied;
}

fn checkMultiSig(allocator: std.mem.Allocator, context: *const EvalContext, stack: *Stack) !bool {
    const n_raw = try stack.popNum();
    if (n_raw < 0 or n_raw > 20) return error.InvalidMultisigPubkeyCount;
    const n: usize = @intCast(n_raw);
    if (stack.items.items.len < n) return error.StackUnderflow;
    var pubkeys = try allocator.alloc([]const u8, n);
    defer allocator.free(pubkeys);
    errdefer for (pubkeys) |item| allocator.free(item);
    var i = n;
    while (i > 0) {
        i -= 1;
        pubkeys[i] = try stack.pop();
    }
    defer for (pubkeys) |item| allocator.free(item);

    const m_raw = try stack.popNum();
    if (m_raw < 0 or m_raw > n_raw) return error.InvalidMultisigSignatureCount;
    const m: usize = @intCast(m_raw);
    if (stack.items.items.len < m + 1) return error.StackUnderflow;
    var signatures = try allocator.alloc([]const u8, m);
    defer allocator.free(signatures);
    errdefer for (signatures) |item| allocator.free(item);
    i = m;
    while (i > 0) {
        i -= 1;
        signatures[i] = try stack.pop();
    }
    defer for (signatures) |item| allocator.free(item);
    const dummy = try stack.pop();
    stack.allocator.free(dummy);

    var sig_index: usize = 0;
    var key_index: usize = 0;
    while (sig_index < signatures.len) {
        if (context.script_code.len > 6000 and signatures[sig_index].len < 48) {
            sig_index += 1;
            continue;
        }
        var matched = false;
        while (key_index < pubkeys.len) : (key_index += 1) {
            if (try checkSignature(allocator, context, signatures[sig_index], pubkeys[key_index])) {
                matched = true;
                key_index += 1;
                break;
            }
        }
        if (!matched) return context.script_code.len > 6000;
        sig_index += 1;
        if (signatures.len - sig_index > pubkeys.len - key_index) return context.script_code.len > 6000;
    }
    return true;
}

fn legacySighash(
    allocator: std.mem.Allocator,
    transaction: tx.Transaction,
    input_index: usize,
    script_code: []const u8,
    signature: []const u8,
    sighash_type: u8,
) ![32]u8 {
    const base_type = sighash_type & 0x1f;
    if (base_type == SIGHASH_SINGLE and input_index >= transaction.outputs.len) {
        var one = [_]u8{0} ** 32;
        one[0] = 1;
        return one;
    }
    const anyone = (sighash_type & SIGHASH_ANYONECANPAY) != 0;
    const clean_script = try removeSignatureOccurrences(allocator, script_code, signature);
    defer allocator.free(clean_script);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try appendU32(allocator, &out, @bitCast(transaction.version));
    if (anyone) {
        try tx.writeCompactSize(allocator, &out, 1);
        try appendLegacyInput(allocator, &out, transaction.inputs[input_index], clean_script, false);
    } else {
        try tx.writeCompactSize(allocator, &out, transaction.inputs.len);
        for (transaction.inputs, 0..) |input, i| {
            const script = if (i == input_index) clean_script else &.{};
            const zero_sequence = i != input_index and (base_type == SIGHASH_NONE or base_type == SIGHASH_SINGLE);
            try appendLegacyInput(allocator, &out, input, script, zero_sequence);
        }
    }

    if (base_type == SIGHASH_NONE) {
        try tx.writeCompactSize(allocator, &out, 0);
    } else if (base_type == SIGHASH_SINGLE) {
        try tx.writeCompactSize(allocator, &out, input_index + 1);
        var i: usize = 0;
        while (i < input_index) : (i += 1) {
            try appendU64(allocator, &out, 0xffff_ffff_ffff_ffff);
            try tx.writeCompactSize(allocator, &out, 0);
        }
        try appendOutput(allocator, &out, transaction.outputs[input_index]);
    } else {
        try tx.writeCompactSize(allocator, &out, transaction.outputs.len);
        for (transaction.outputs) |output| try appendOutput(allocator, &out, output);
    }
    try appendU32(allocator, &out, transaction.lock_time);
    try appendU32(allocator, &out, @intCast(sighash_type));
    return crypto.doubleSha256(out.items);
}

fn bip143Sighash(
    allocator: std.mem.Allocator,
    transaction: tx.Transaction,
    input_index: usize,
    script_code: []const u8,
    amount: i64,
    sighash_type: u8,
) ![32]u8 {
    const base_type = sighash_type & 0x1f;
    const anyone = (sighash_type & SIGHASH_ANYONECANPAY) != 0;
    const zero32 = [_]u8{0} ** 32;
    const hash_prevouts = if (!anyone) try hashPrevouts(allocator, transaction) else zero32;
    const hash_sequence = if (!anyone and base_type != SIGHASH_SINGLE and base_type != SIGHASH_NONE) try hashSequence(allocator, transaction) else zero32;
    const hash_outputs = if (base_type == SIGHASH_SINGLE and input_index < transaction.outputs.len)
        try hashSingleOutput(allocator, transaction.outputs[input_index])
    else if (base_type != SIGHASH_SINGLE and base_type != SIGHASH_NONE)
        try hashOutputs(allocator, transaction)
    else
        zero32;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try appendU32(allocator, &out, @bitCast(transaction.version));
    try out.appendSlice(allocator, hash_prevouts[0..]);
    try out.appendSlice(allocator, hash_sequence[0..]);
    try out.appendSlice(allocator, transaction.inputs[input_index].previous_output.hash[0..]);
    try appendU32(allocator, &out, transaction.inputs[input_index].previous_output.index);
    try tx.writeCompactSize(allocator, &out, script_code.len);
    try out.appendSlice(allocator, script_code);
    try appendU64(allocator, &out, @bitCast(amount));
    try appendU32(allocator, &out, transaction.inputs[input_index].sequence);
    try out.appendSlice(allocator, hash_outputs[0..]);
    try appendU32(allocator, &out, transaction.lock_time);
    try appendU32(allocator, &out, @intCast(sighash_type));
    return crypto.doubleSha256(out.items);
}

fn appendLegacyInput(allocator: std.mem.Allocator, out: *std.ArrayList(u8), input: tx.TxIn, script: []const u8, zero_sequence: bool) !void {
    try out.appendSlice(allocator, input.previous_output.hash[0..]);
    try appendU32(allocator, out, input.previous_output.index);
    try tx.writeCompactSize(allocator, out, script.len);
    try out.appendSlice(allocator, script);
    try appendU32(allocator, out, if (zero_sequence) 0 else input.sequence);
}

fn appendOutput(allocator: std.mem.Allocator, out: *std.ArrayList(u8), output: tx.TxOut) !void {
    try appendU64(allocator, out, @bitCast(output.value));
    try tx.writeCompactSize(allocator, out, output.script_pubkey.len);
    try out.appendSlice(allocator, output.script_pubkey);
}

fn hashPrevouts(allocator: std.mem.Allocator, transaction: tx.Transaction) ![32]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (transaction.inputs) |input| {
        try out.appendSlice(allocator, input.previous_output.hash[0..]);
        try appendU32(allocator, &out, input.previous_output.index);
    }
    return crypto.doubleSha256(out.items);
}

fn hashSequence(allocator: std.mem.Allocator, transaction: tx.Transaction) ![32]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (transaction.inputs) |input| try appendU32(allocator, &out, input.sequence);
    return crypto.doubleSha256(out.items);
}

fn hashOutputs(allocator: std.mem.Allocator, transaction: tx.Transaction) ![32]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (transaction.outputs) |output| try appendOutput(allocator, &out, output);
    return crypto.doubleSha256(out.items);
}

fn hashSingleOutput(allocator: std.mem.Allocator, output: tx.TxOut) ![32]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try appendOutput(allocator, &out, output);
    return crypto.doubleSha256(out.items);
}

fn appendU32(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try out.appendSlice(allocator, &buf);
}

fn appendU64(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    try out.appendSlice(allocator, &buf);
}

fn removeSignatureOccurrences(allocator: std.mem.Allocator, script_code: []const u8, signature: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var offset: usize = 0;
    while (offset < script_code.len) {
        if (signature.len != 0 and offset + signature.len <= script_code.len and std.mem.eql(u8, script_code[offset .. offset + signature.len], signature)) {
            offset += signature.len;
        } else {
            try out.append(allocator, script_code[offset]);
            offset += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn p2pkhScriptCode(allocator: std.mem.Allocator, pubkey_hash: []const u8) ![]u8 {
    if (pubkey_hash.len != 20) return error.InvalidPubkeyHash;
    var out = try allocator.alloc(u8, 25);
    out[0] = OP_DUP;
    out[1] = OP_HASH160;
    out[2] = 0x14;
    @memcpy(out[3..23], pubkey_hash);
    out[23] = OP_EQUALVERIFY;
    out[24] = OP_CHECKSIG;
    return out;
}

const Stack = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]const u8),

    fn init(allocator: std.mem.Allocator) Stack {
        return .{ .allocator = allocator, .items = .empty };
    }

    fn deinit(self: *Stack) void {
        for (self.items.items) |item| self.allocator.free(item);
        self.items.deinit(self.allocator);
    }

    fn push(self: *Stack, item: []const u8) !void {
        try self.items.append(self.allocator, try self.allocator.dupe(u8, item));
    }

    fn insert(self: *Stack, index: usize, item: []const u8) !void {
        try self.items.insert(self.allocator, index, try self.allocator.dupe(u8, item));
    }

    fn pushNum(self: *Stack, value: i64) !void {
        var buf: [8]u8 = undefined;
        const encoded = encodeScriptNum(&buf, value);
        try self.push(encoded);
    }

    fn pop(self: *Stack) ![]const u8 {
        if (self.items.items.len == 0) return error.StackUnderflow;
        return self.items.pop().?;
    }

    fn popNum(self: *Stack) !i64 {
        const item = try self.pop();
        defer self.allocator.free(item);
        return decodeScriptNum(item);
    }

    fn peek(self: *Stack) ![]const u8 {
        if (self.items.items.len == 0) return error.StackUnderflow;
        return self.items.items[self.items.items.len - 1];
    }
};

fn terminalStrict(stack: *Stack) bool {
    return stack.items.items.len == 1 and castToBool(stack.items.items[0]);
}

fn terminalRelaxed(stack: *Stack) bool {
    return stack.items.items.len >= 1 and castToBool(stack.items.items[stack.items.items.len - 1]);
}

fn castToBool(item: []const u8) bool {
    for (item, 0..) |byte, i| {
        if (byte != 0) {
            if (i == item.len - 1 and byte == 0x80) return false;
            return true;
        }
    }
    return false;
}

fn conditionActive(items: []const bool) bool {
    for (items) |item| {
        if (!item) return false;
    }
    return true;
}

fn encodeScriptNum(buf: *[8]u8, value: i64) []const u8 {
    if (value == 0) return &.{};
    var abs: u64 = if (value < 0) @intCast(-value) else @intCast(value);
    var len: usize = 0;
    while (abs > 0) : (abs >>= 8) {
        buf[len] = @intCast(abs & 0xff);
        len += 1;
    }
    if ((buf[len - 1] & 0x80) != 0) {
        buf[len] = if (value < 0) 0x80 else 0;
        len += 1;
    } else if (value < 0) {
        buf[len - 1] |= 0x80;
    }
    return buf[0..len];
}

fn decodeScriptNum(item: []const u8) !i64 {
    if (item.len > 8) return error.ScriptNumTooWide;
    if (item.len == 0) return 0;
    var result: i64 = 0;
    for (item, 0..) |byte, i| result |= @as(i64, byte) << @intCast(8 * i);
    if ((item[item.len - 1] & 0x80) != 0) {
        result &= ~(@as(i64, 0x80) << @intCast(8 * (item.len - 1)));
        return -result;
    }
    return result;
}

fn isP2PKH(script_pubkey: []const u8) bool {
    return script_pubkey.len == 25 and script_pubkey[0] == 0x76 and script_pubkey[1] == 0xa9 and script_pubkey[2] == 0x14 and script_pubkey[23] == 0x88 and script_pubkey[24] == 0xac;
}

fn isP2SH(script_pubkey: []const u8) bool {
    return script_pubkey.len == 23 and script_pubkey[0] == 0xa9 and script_pubkey[1] == 0x14 and script_pubkey[22] == 0x87;
}

fn isP2WPKH(script_pubkey: []const u8) bool {
    return script_pubkey.len == 22 and script_pubkey[0] == 0x00 and script_pubkey[1] == 0x14;
}

fn isP2WSH(script_pubkey: []const u8) bool {
    return script_pubkey.len == 34 and script_pubkey[0] == 0x00 and script_pubkey[1] == 0x20;
}

fn isP2TR(script_pubkey: []const u8) bool {
    return script_pubkey.len == 34 and script_pubkey[0] == 0x51 and script_pubkey[1] == 0x20;
}

fn isP2PK(script_pubkey: []const u8) bool {
    return script_pubkey.len >= 35 and (script_pubkey[0] == 33 or script_pubkey[0] == 65) and script_pubkey[script_pubkey.len - 1] == OP_CHECKSIG;
}

fn isBareOpN(script_pubkey: []const u8) bool {
    return script_pubkey.len == 1 and (script_pubkey[0] == OP_0 or (script_pubkey[0] >= OP_1 and script_pubkey[0] <= OP_16));
}

fn isBareLegacy(script_pubkey: []const u8) bool {
    return !isP2PKH(script_pubkey) and !isP2SH(script_pubkey) and !isP2WPKH(script_pubkey) and !isP2WSH(script_pubkey) and !isP2TR(script_pubkey);
}

test "minimal P2WSH OP_TRUE verifies" {
    const allocator = std.testing.allocator;
    const script = [_]u8{OP_1};
    const hash = crypto.sha256(script[0..]);
    var spk: [34]u8 = undefined;
    spk[0] = 0x00;
    spk[1] = 0x20;
    @memcpy(spk[2..34], hash[0..]);
    const input = tx.TxIn{ .previous_output = .{ .hash = [_]u8{0} ** 32, .index = 0 }, .script_sig = &.{}, .sequence = 0xffff_ffff };
    const output = tx.TxOut{ .value = 1, .script_pubkey = &.{OP_1} };
    const witness_stack = [_][]const u8{script[0..]};
    const witness = [_][]const []const u8{witness_stack[0..]};
    const raw = try tx.serializeNoWitness(allocator, .{
        .version = 1,
        .inputs = @constCast(&[_]tx.TxIn{input}),
        .outputs = @constCast(&[_]tx.TxOut{output}),
        .lock_time = 0,
        .witness = witness[0..],
        .raw_no_witness = &.{},
    });
    defer allocator.free(raw);
    const transaction = tx.Transaction{
        .version = 1,
        .inputs = @constCast(&[_]tx.TxIn{input}),
        .outputs = @constCast(&[_]tx.TxOut{output}),
        .lock_time = 0,
        .witness = witness[0..],
        .raw_no_witness = raw,
    };
    try verifyInput(allocator, transaction, 0, &.{.{ .amount = 1, .script_pubkey = spk[0..] }});
}
