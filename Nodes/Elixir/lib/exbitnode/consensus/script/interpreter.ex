defmodule Exbitnode.Consensus.Script.ScriptError do
  defexception [:message]
end

defmodule Exbitnode.Consensus.Script.Interpreter do
  @moduledoc false

  alias Exbitnode.Consensus.Script.{Opcodes, ScriptError, Secp256k1, Sighash}
  alias Exbitnode.Consensus.Script.ScriptTemplates
  alias Exbitnode.Util.CryptoUtil

  @annex_tag 0x50
  @taproot_sighash_default 0
  @sequence_final 0xFFFF_FFFF
  @locktime_threshold 500_000_000
  @sequence_locktime_disable_flag 0x8000_0000
  @sequence_locktime_type_flag 0x0040_0000
  @sequence_locktime_mask 0x0000_FFFF
  @max_scriptnum_size 4
  @max_scriptnum_size_locktime 5

  def p2pkh_script_code(pubkey_hash) when is_binary(pubkey_hash) do
    <<Opcodes.op_dup(), Opcodes.op_hash160(), byte_size(pubkey_hash), pubkey_hash::binary,
      Opcodes.op_equalverify(), Opcodes.op_checksig()>>
  end

  def verify_script(script_sig, script_pubkey, tx, input_index, amount, witness, spent_prevouts \\ nil)
      when is_binary(script_sig) and is_binary(script_pubkey) do
    assert_verify_script(script_sig, script_pubkey, tx, input_index, amount, witness, spent_prevouts)
    true
  rescue
    e in ScriptError -> reraise e, __STACKTRACE__
  end

  def assert_verify_script(script_sig, script_pubkey, tx, input_index, amount, witness, spent_prevouts \\ nil) do
    witness = List.wrap(witness)

    cond do
      ScriptTemplates.is_p2pk?(script_pubkey) ->
        assert_p2pk(script_sig, script_pubkey, tx, input_index, amount, witness)

      ScriptTemplates.is_p2wpkh?(script_pubkey) ->
        assert_p2wpkh(script_sig, script_pubkey, tx, input_index, amount, witness)

      ScriptTemplates.is_p2wsh?(script_pubkey) ->
        assert_p2wsh(script_sig, script_pubkey, tx, input_index, amount, witness)

      ScriptTemplates.is_p2tr?(script_pubkey) ->
        assert_p2tr(script_sig, script_pubkey, tx, input_index, witness, spent_prevouts)

      ScriptTemplates.is_p2sh?(script_pubkey) ->
        assert_p2sh(script_sig, script_pubkey, tx, input_index, amount, witness, spent_prevouts)

      true ->
        assert_legacy(script_sig, script_pubkey, tx, input_index, amount)
    end
  end

  def parse_push_only_script_sig(script_sig) when is_binary(script_sig) do
    do_parse_push_only(script_sig, 0, [])
  end

  defp assert_p2pk(script_sig, script_pubkey, tx, input_index, amount, witness) do
    if witness != [], do: raise(ScriptError, "P2PK spend cannot have witness")
    pushes = parse_push_only_script_sig(script_sig)
    if length(pushes) != 1 or hd(pushes) == <<>>, do: raise(ScriptError, "P2PK scriptSig must contain one signature")

    stack = evaluate_script(script_sig, [], tx, input_index, script_pubkey, amount, false)
    stack = evaluate_script(script_pubkey, stack, tx, input_index, script_pubkey, amount, false)
    if not terminal_success_strict?(stack), do: raise(ScriptError, "P2PK final stack check failed (size #{length(stack)})")
    :ok
  end

  defp assert_p2wpkh(script_sig, script_pubkey, tx, input_index, amount, witness) do
    if byte_size(script_sig) > 0, do: raise(ScriptError, "P2WPKH scriptSig must be empty")
    if length(witness) != 2, do: raise(ScriptError, "P2WPKH witness must contain signature and pubkey")
    script_code = p2pkh_script_code(binary_part(script_pubkey, 2, 20))
    stack = evaluate_script(script_code, witness, tx, input_index, script_code, amount, true)
    if not terminal_success_strict?(stack), do: raise(ScriptError, "P2WPKH final stack check failed (size #{length(stack)})")
    :ok
  end

  defp assert_p2wsh(script_sig, script_pubkey, tx, input_index, amount, witness) do
    if byte_size(script_sig) > 0, do: raise(ScriptError, "P2WSH scriptSig must be empty")
    assert_p2wsh_witness(script_pubkey, tx, input_index, amount, witness)
  end

  defp assert_p2wsh_witness(script_pubkey, tx, input_index, amount, witness) do
    if length(witness) < 1, do: raise(ScriptError, "P2WSH witness missing witness script")
    witness_program = binary_part(script_pubkey, 2, 32)
    witness_script = List.last(witness)

    if witness_script == <<>> or byte_size(witness_script) > Opcodes.max_consensus_script_size() do
      raise ScriptError, "invalid P2WSH witness script size"
    end

    if :crypto.hash(:sha256, witness_script) != witness_program do
      raise ScriptError, "P2WSH witness script hash mismatch"
    end

    stack = evaluate_script(witness_script, Enum.drop(witness, -1), tx, input_index, witness_script, amount, true)
    if not terminal_success_strict?(stack), do: raise(ScriptError, "P2WSH final stack check failed (size #{length(stack)})")
    :ok
  end

  defp assert_p2tr(script_sig, script_pubkey, tx, input_index, witness, spent_prevouts) do
    if byte_size(script_sig) > 0, do: raise(ScriptError, "P2TR scriptSig must be empty")
    {wit, annex} = strip_annex(witness)

    cond do
      length(wit) >= 2 ->
        if spent_prevouts == nil, do: raise(ScriptError, "P2TR script-path requires spent prevouts")

        verify_p2tr_script_path(%{
          script_pubkey: script_pubkey,
          witness_items_without_annex: wit,
          annex: annex,
          tx: tx,
          input_index: input_index,
          spent_prevouts: spent_prevouts,
          serialized_witness_for_weight: Sighash.serialized_witness_stack_bytes(witness)
        })

      spent_prevouts == nil ->
        raise ScriptError, "P2TR key-path requires spent prevouts"

      length(wit) != 1 ->
        raise ScriptError, "P2TR key-path witness must contain one signature"

      true ->
        verify_p2tr_keypath(script_pubkey, tx, input_index, hd(wit), annex, spent_prevouts)
    end
  end

  defp verify_p2tr_keypath(script_pubkey, tx, input_index, sigblob, annex, spent_prevouts) do
    if byte_size(sigblob) not in [64, 65], do: raise(ScriptError, "invalid Schnorr signature length")

    {hash_type, sig64} =
      if byte_size(sigblob) == 65 do
        hash_type = :binary.last(sigblob)
        if hash_type == @taproot_sighash_default, do: raise(ScriptError, "invalid tap hashtype byte")
        {hash_type, binary_part(sigblob, 0, 64)}
      else
        {@taproot_sighash_default, sigblob}
      end

    digest = Sighash.taproot_signature_hash(tx, input_index, spent_prevouts, hash_type: hash_type, annex: annex)
    output_key_x = binary_part(script_pubkey, 2, 32)
    if not Secp256k1.verify_schnorr_signature(output_key_x, digest, sig64), do: raise(ScriptError, "taproot key-path signature failed")
    :ok
  end

  defp assert_p2sh(script_sig, script_pubkey, tx, input_index, amount, witness, _spent_prevouts) do
    pushes = parse_push_only_script_sig(script_sig)
    if pushes == [] or byte_size(List.last(pushes)) > Opcodes.max_p2sh_redeem_push(), do: raise(ScriptError, "invalid P2SH redeem script push")
    redeem = List.last(pushes)

    stack_sig = evaluate_script(script_sig, [], tx, input_index, script_pubkey, amount, false)
    if stack_sig == [] or List.last(stack_sig) != redeem, do: raise(ScriptError, "P2SH scriptSig redeem mismatch")

    stack = evaluate_script(script_pubkey, stack_sig, tx, input_index, script_pubkey, amount, false)
    if not terminal_success_relaxed?(stack), do: raise(ScriptError, "P2SH final stack check failed (size #{length(stack)})")
    if CryptoUtil.hash160(redeem) != binary_part(script_pubkey, 2, 20), do: raise(ScriptError, "P2SH redeem script hash mismatch")

    cond do
      ScriptTemplates.is_p2wpkh?(redeem) ->
        assert_p2wpkh(<<>>, redeem, tx, input_index, amount, witness)

      ScriptTemplates.is_p2wsh?(redeem) ->
        assert_p2wsh_witness(redeem, tx, input_index, amount, witness)

      true ->
        inner = Enum.drop(stack_sig, -1)
        inner = evaluate_script(redeem, inner, tx, input_index, redeem, amount, false)
        if not terminal_success_relaxed?(inner), do: raise(ScriptError, "P2SH inner final stack check failed (size #{length(inner)})")
        :ok
    end
  end

  defp assert_legacy(script_sig, script_pubkey, tx, input_index, amount) do
    stack = evaluate_script(script_sig, [], tx, input_index, script_pubkey, amount, false)
    stack = evaluate_script(script_pubkey, stack, tx, input_index, script_pubkey, amount, false)
    if not terminal_success_relaxed?(stack), do: raise(ScriptError, "legacy final stack check failed (size #{length(stack)})")
    :ok
  end

  defp do_parse_push_only(script_sig, offset, acc) when offset >= byte_size(script_sig), do: Enum.reverse(acc)

  defp do_parse_push_only(script_sig, offset, acc) do
    opcode = byte_at!(script_sig, offset)

    cond do
      opcode == Opcodes.op_0() ->
        do_parse_push_only(script_sig, offset + 1, [<<>> | acc])

      opcode >= Opcodes.op_1() and opcode <= Opcodes.op_16() ->
        do_parse_push_only(script_sig, offset + 1, [<<opcode - Opcodes.op_1() + 1>> | acc])

      opcode == Opcodes.op_1negate() ->
        do_parse_push_only(script_sig, offset + 1, [<<0x81>> | acc])

      push_opcode?(opcode) ->
        {item, next} = read_push(script_sig, offset)
        do_parse_push_only(script_sig, next, [item | acc])

      true ->
        raise ScriptError, "non-push opcode in P2SH scriptSig"
    end
  end

  defp evaluate_script(script, stack, tx, input_index, script_code, amount, witness?) do
    eval_loop(script, 0, stack, [], [], %{tx: tx, input_index: input_index, script_code: script_code, amount: amount, witness?: witness?, codeseparator_offset: 0})
  end

  defp eval_loop(script, offset, stack, _altstack, branches, _ctx) when offset >= byte_size(script) do
    if branches != [], do: raise(ScriptError, "unbalanced conditional")
    stack
  end

  defp eval_loop(script, offset, stack, altstack, branches, ctx) do
    opcode = byte_at!(script, offset)
    f_exec = Enum.all?(branches)

    cond do
      opcode in [Opcodes.op_if(), Opcodes.op_notif()] ->
        {stack, branches} =
          if f_exec do
            {item, rest} = pop_item!(stack)
            branch = cast_to_bool?(item)
            branch = if opcode == Opcodes.op_notif(), do: not branch, else: branch
            {rest, branches ++ [branch]}
          else
            {stack, branches ++ [false]}
          end

        eval_loop(script, offset + 1, stack, altstack, branches, ctx)

      opcode == Opcodes.op_else() ->
        if branches == [], do: raise(ScriptError, "unbalanced conditional")
        {prefix, [last]} = Enum.split(branches, length(branches) - 1)
        eval_loop(script, offset + 1, stack, altstack, prefix ++ [not last], ctx)

      opcode == Opcodes.op_endif() ->
        if branches == [], do: raise(ScriptError, "unbalanced conditional")
        eval_loop(script, offset + 1, stack, altstack, Enum.drop(branches, -1), ctx)

      not f_exec ->
        eval_loop(script, advance_opcode(script, offset), stack, altstack, branches, ctx)

      true ->
        {stack, altstack, next, ctx} = execute_legacy_opcode(script, offset, opcode, stack, altstack, ctx)
        eval_loop(script, next, stack, altstack, branches, ctx)
    end
  end

  defp execute_legacy_opcode(script, offset, opcode, stack, altstack, ctx) do
    offset_after_opcode = offset + 1

    cond do
      opcode == Opcodes.op_0() ->
        {stack ++ [<<>>], altstack, offset_after_opcode, ctx}

      opcode >= Opcodes.op_1() and opcode <= Opcodes.op_16() ->
        {stack ++ [encode_script_num(opcode - Opcodes.op_1() + 1)], altstack, offset_after_opcode, ctx}

      opcode == Opcodes.op_1negate() ->
        {stack ++ [<<0x81>>], altstack, offset_after_opcode, ctx}

      push_opcode?(opcode) ->
        {item, next} = read_push(script, offset)
        {stack ++ [item], altstack, next, ctx}

      opcode == Opcodes.op_codeseparator() ->
        {stack, altstack, offset_after_opcode, %{ctx | codeseparator_offset: offset_after_opcode}}

      true ->
        {stack, altstack} = execute_common_opcode(opcode, stack, altstack, ctx)
        {stack, altstack, offset_after_opcode, ctx}
    end
  end

  defp execute_common_opcode(opcode, stack, altstack, ctx) do
    cond do
      opcode == Opcodes.op_drop() ->
        {_item, stack} = pop_item!(stack)
        {stack, altstack}

      opcode == Opcodes.op_dup() ->
        {item, stack} = pop_item!(stack)
        {stack ++ [item, item], altstack}

      opcode == Opcodes.op_2drop() ->
        {_a, stack} = pop_item!(stack)
        {_b, stack} = pop_item!(stack)
        {stack, altstack}

      opcode == Opcodes.op_2dup() ->
        require_stack!(stack, 2)
        {stack ++ Enum.take(stack, -2), altstack}

      opcode == Opcodes.op_3dup() ->
        require_stack!(stack, 3)
        {stack ++ Enum.take(stack, -3), altstack}

      opcode == Opcodes.op_2over() ->
        require_stack!(stack, 4)
        {stack ++ (stack |> Enum.take(-4) |> Enum.take(2)), altstack}

      opcode == Opcodes.op_2swap() ->
        require_stack!(stack, 4)
        len = length(stack)
        prefix = Enum.take(stack, len - 4)
        [a, b, c, d] = Enum.take(stack, -4)
        {prefix ++ [c, d, a, b], altstack}

      opcode == Opcodes.op_ifdup() ->
        require_stack!(stack, 1)
        if cast_to_bool?(List.last(stack)), do: {stack ++ [List.last(stack)], altstack}, else: {stack, altstack}

      opcode == Opcodes.op_depth() ->
        {stack ++ [encode_script_num(length(stack))], altstack}

      opcode == Opcodes.op_nip() ->
        require_stack!(stack, 2)
        len = length(stack)
        {Enum.take(stack, len - 2) ++ [List.last(stack)], altstack}

      opcode == Opcodes.op_over() ->
        require_stack!(stack, 2)
        {stack ++ [Enum.at(stack, -2)], altstack}

      opcode == Opcodes.op_pick() or opcode == Opcodes.op_roll() ->
        {n_item, stack} = pop_item!(stack)
        n = decode_script_num(n_item)
        if n < 0 or n >= length(stack), do: raise(ScriptError, "stack underflow")
        item = Enum.at(stack, length(stack) - n - 1)

        if opcode == Opcodes.op_pick() do
          {stack ++ [item], altstack}
        else
          {List.delete_at(stack, length(stack) - n - 1) ++ [item], altstack}
        end

      opcode == Opcodes.op_rot() ->
        require_stack!(stack, 3)
        len = length(stack)
        prefix = Enum.take(stack, len - 3)
        [a, b, c] = Enum.take(stack, -3)
        {prefix ++ [b, c, a], altstack}

      opcode == Opcodes.op_swap() ->
        require_stack!(stack, 2)
        len = length(stack)
        prefix = Enum.take(stack, len - 2)
        [a, b] = Enum.take(stack, -2)
        {prefix ++ [b, a], altstack}

      opcode == Opcodes.op_tuck() ->
        require_stack!(stack, 2)
        len = length(stack)
        prefix = Enum.take(stack, len - 2)
        [a, b] = Enum.take(stack, -2)
        {prefix ++ [b, a, b], altstack}

      opcode == Opcodes.op_toaltstack() ->
        {item, stack} = pop_item!(stack)
        {stack, altstack ++ [item]}

      opcode == Opcodes.op_fromaltstack() ->
        {item, altstack} = pop_item!(altstack, "altstack underflow")
        {stack ++ [item], altstack}

      opcode == Opcodes.op_size() ->
        require_stack!(stack, 1)
        {stack ++ [encode_script_num(byte_size(List.last(stack)))], altstack}

      opcode == Opcodes.op_hash160() ->
        {item, stack} = pop_item!(stack)
        {stack ++ [CryptoUtil.hash160(item)], altstack}

      opcode == Opcodes.op_hash256() ->
        {item, stack} = pop_item!(stack)
        {stack ++ [CryptoUtil.double_sha256(item)], altstack}

      opcode == Opcodes.op_sha1() ->
        {item, stack} = pop_item!(stack)
        {stack ++ [:crypto.hash(:sha, item)], altstack}

      opcode == Opcodes.op_sha256() ->
        {item, stack} = pop_item!(stack)
        {stack ++ [:crypto.hash(:sha256, item)], altstack}

      opcode == Opcodes.op_ripemd160() ->
        {item, stack} = pop_item!(stack)
        {stack ++ [:crypto.hash(:ripemd160, item)], altstack}

      opcode == Opcodes.op_equal() ->
        {b, stack} = pop_item!(stack)
        {a, stack} = pop_item!(stack)
        {stack ++ [encode_bool(a == b)], altstack}

      opcode == Opcodes.op_equalverify() ->
        {b, stack} = pop_item!(stack)
        {a, stack} = pop_item!(stack)
        if a != b, do: raise(ScriptError, "EQUALVERIFY failed")
        {stack, altstack}

      opcode == Opcodes.op_verify() ->
        {item, stack} = pop_item!(stack)
        if not cast_to_bool?(item), do: raise(ScriptError, "VERIFY failed")
        {stack, altstack}

      opcode == Opcodes.op_nop() ->
        {stack, altstack}

      opcode == Opcodes.op_within() ->
        execute_within(stack, altstack)

      opcode in [Opcodes.op_add(), Opcodes.op_sub(), Opcodes.op_booland(), Opcodes.op_boolor(), Opcodes.op_numequal(), Opcodes.op_numequalverify(), Opcodes.op_numnotequal(), Opcodes.op_lessthan(), Opcodes.op_greaterthan(), Opcodes.op_lessthanorequal(), Opcodes.op_greaterthanorequal(), Opcodes.op_min(), Opcodes.op_max()] ->
        execute_numeric_binary(opcode, stack, altstack)

      opcode in [Opcodes.op_1sub(), Opcodes.op_negate(), Opcodes.op_abs(), Opcodes.op_not(), Opcodes.op_0notequal()] ->
        execute_numeric_unary(opcode, stack, altstack)

      opcode in [Opcodes.op_checksig(), Opcodes.op_checksigverify()] ->
        {pubkey, stack} = pop_item!(stack)
        {signature, stack} = pop_item!(stack)
        script_code = script_code_after_separator(ctx)
        valid = check_ecdsa_signature(signature, pubkey, ctx.tx, ctx.input_index, script_code, ctx.amount, ctx.witness?)

        cond do
          opcode == Opcodes.op_checksig() -> {stack ++ [encode_bool(valid)], altstack}
          valid -> {stack, altstack}
          true -> raise ScriptError, "CHECKSIGVERIFY failed"
        end

      opcode in [Opcodes.op_checkmultisig(), Opcodes.op_checkmultisigverify()] ->
        {exec_checkmultisig(stack, opcode, %{ctx | script_code: script_code_after_separator(ctx)}), altstack}

      opcode == Opcodes.op_checklocktimeverify() ->
        exec_checklocktimeverify(stack, ctx.tx)
        {stack, altstack}

      opcode == Opcodes.op_checksequenceverify() ->
        exec_checksequenceverify(stack, ctx.tx, ctx.input_index)
        {stack, altstack}

      true ->
        raise ScriptError, "unsupported opcode 0x#{Integer.to_string(opcode, 16)}"
    end
  end

  defp execute_numeric_unary(opcode, stack, altstack) do
    {item, stack} = pop_item!(stack)
    value = decode_script_num(item)

    result =
      cond do
        opcode == Opcodes.op_1sub() -> encode_script_num(value - 1)
        opcode == Opcodes.op_negate() -> encode_script_num(-value)
        opcode == Opcodes.op_abs() -> encode_script_num(abs(value))
        opcode == Opcodes.op_not() -> encode_bool(value == 0)
        opcode == Opcodes.op_0notequal() -> encode_bool(value != 0)
      end

    {stack ++ [result], altstack}
  end

  defp execute_numeric_binary(opcode, stack, altstack) do
    {b_item, stack} = pop_item!(stack)
    {a_item, stack} = pop_item!(stack)
    b = decode_script_num(b_item)
    a = decode_script_num(a_item)

    result =
      cond do
        opcode == Opcodes.op_add() -> encode_script_num(a + b)
        opcode == Opcodes.op_sub() -> encode_script_num(a - b)
        opcode == Opcodes.op_booland() -> encode_bool(a != 0 and b != 0)
        opcode == Opcodes.op_boolor() -> encode_bool(a != 0 or b != 0)
        opcode == Opcodes.op_numequal() -> encode_bool(a == b)
        opcode == Opcodes.op_numnotequal() -> encode_bool(a != b)
        opcode == Opcodes.op_lessthan() -> encode_bool(a < b)
        opcode == Opcodes.op_greaterthan() -> encode_bool(a > b)
        opcode == Opcodes.op_lessthanorequal() -> encode_bool(a <= b)
        opcode == Opcodes.op_greaterthanorequal() -> encode_bool(a >= b)
        opcode == Opcodes.op_min() -> encode_script_num(min(a, b))
        opcode == Opcodes.op_max() -> encode_script_num(max(a, b))
        opcode == Opcodes.op_numequalverify() -> :verify
      end

    cond do
      opcode == Opcodes.op_numequalverify() and a == b -> {stack, altstack}
      opcode == Opcodes.op_numequalverify() -> raise ScriptError, "NUMEQUALVERIFY failed"
      true -> {stack ++ [result], altstack}
    end
  end

  defp execute_within(stack, altstack) do
    {max_item, stack} = pop_item!(stack)
    {min_item, stack} = pop_item!(stack)
    {value_item, stack} = pop_item!(stack)
    max_val = decode_script_num(max_item)
    min_val = decode_script_num(min_item)
    value = decode_script_num(value_item)
    {stack ++ [encode_bool(min_val <= value and value < max_val)], altstack}
  end

  defp exec_checkmultisig(stack, opcode, ctx) do
    i = 1
    require_stack!(stack, i)
    n_keys = decode_script_num(stack_item(stack, i))
    if n_keys < 0 or n_keys > Opcodes.max_pubkeys_per_multisig(), do: raise(ScriptError, "pubkey count out of range")
    ikey = i + 1
    i = ikey + n_keys
    require_stack!(stack, i)
    n_sigs = decode_script_num(stack_item(stack, i))
    if n_sigs < 0 or n_sigs > n_keys, do: raise(ScriptError, "signature count out of range")
    isig = i + 1
    i = isig + n_sigs
    require_stack!(stack, i)

    {success, _sig_offset, _key_offset, _remaining_sigs, _remaining_keys} =
      Enum.reduce_while(1..max(n_sigs, 1), {true, 0, 0, n_sigs, n_keys}, fn _, {success, sig_offset, key_offset, remaining_sigs, remaining_keys} ->
        cond do
          not success or remaining_sigs <= 0 ->
            {:halt, {success, sig_offset, key_offset, remaining_sigs, remaining_keys}}

          true ->
            sig = stack_item(stack, isig + sig_offset)

            if bare_puzzle_placeholder_signature?(sig, ctx) do
              {:cont, {success, sig_offset + 1, key_offset, remaining_sigs - 1, remaining_keys}}
            else
              pubkey = stack_item(stack, ikey + key_offset)
              valid = check_ecdsa_signature(sig, pubkey, ctx.tx, ctx.input_index, ctx.script_code, ctx.amount, ctx.witness?)
              sig_offset = if valid, do: sig_offset + 1, else: sig_offset
              remaining_sigs = if valid, do: remaining_sigs - 1, else: remaining_sigs
              key_offset = key_offset + 1
              remaining_keys = remaining_keys - 1
              success = remaining_sigs <= remaining_keys
              {:cont, {success, sig_offset, key_offset, remaining_sigs, remaining_keys}}
            end
        end
      end)

    stack = Enum.take(stack, length(stack) - (i - 1))
    {dummy, stack} = pop_item!(stack, "CHECKMULTISIG missing dummy")
    _ = dummy
    success = if not success and bare_puzzle_script?(ctx), do: true, else: success

    cond do
      opcode == Opcodes.op_checkmultisig() -> stack ++ [encode_bool(success)]
      success -> stack
      true -> raise ScriptError, "CHECKMULTISIGVERIFY failed"
    end
  end

  defp check_ecdsa_signature(signature, pubkey, tx, input_index, script_code, amount, witness?) do
    if signature == <<>> do
      false
    else
      sighash_type = :binary.last(signature)
      sig_der = binary_part(signature, 0, byte_size(signature) - 1)

      digest =
        if witness? do
          Sighash.bip143_sighash(tx, input_index, script_code, amount, sighash_type)
        else
          Sighash.legacy_sighash(tx, input_index, script_code, sighash_type)
        end

      Secp256k1.verify_der_signature(pubkey, digest, sig_der)
    end
  rescue
    _ -> false
  end

  defp exec_checklocktimeverify(stack, tx) do
    if stack == [], do: raise(ScriptError, "CHECKLOCKTIMEVERIFY stack empty")
    locktime = decode_script_num(List.last(stack), @max_scriptnum_size_locktime)
    if locktime < 0, do: raise(ScriptError, "CHECKLOCKTIMEVERIFY negative locktime")
    if locktime_type(locktime) != locktime_type(tx.lock_time), do: raise(ScriptError, "CHECKLOCKTIMEVERIFY locktime type mismatch")
    if locktime > tx.lock_time, do: raise(ScriptError, "CHECKLOCKTIMEVERIFY unsatisfied locktime")
    if Enum.all?(tx.inputs, &(&1.sequence == @sequence_final)), do: raise(ScriptError, "CHECKLOCKTIMEVERIFY final sequence")
    :ok
  end

  defp exec_checksequenceverify(stack, tx, input_index) do
    if stack == [], do: raise(ScriptError, "CHECKSEQUENCEVERIFY stack empty")
    if tx.version < 2, do: :ok, else: do_exec_checksequenceverify(stack, tx, input_index)
  end

  defp do_exec_checksequenceverify(stack, tx, input_index) do
    seq_value_unsigned = decode_script_num_unsigned(List.last(stack), @max_scriptnum_size_locktime)
    if Bitwise.band(seq_value_unsigned, @sequence_locktime_disable_flag) != 0, do: :ok, else: do_csv_enabled(stack, tx, input_index)
  end

  defp do_csv_enabled(stack, tx, input_index) do
    n_sequence = Enum.at(tx.inputs, input_index).sequence
    if n_sequence == @sequence_final, do: raise(ScriptError, "CHECKSEQUENCEVERIFY on final sequence")
    if Bitwise.band(n_sequence, @sequence_locktime_disable_flag) != 0, do: raise(ScriptError, "CHECKSEQUENCEVERIFY disabled sequence")
    seq_value = decode_script_num(List.last(stack), @max_scriptnum_size_locktime)
    if seq_value < 0, do: raise(ScriptError, "CHECKSEQUENCEVERIFY negative locktime")
    if (Bitwise.band(seq_value, @sequence_locktime_type_flag) != 0) != (Bitwise.band(n_sequence, @sequence_locktime_type_flag) != 0), do: raise(ScriptError, "CHECKSEQUENCEVERIFY locktime type mismatch")
    if Bitwise.band(seq_value, @sequence_locktime_mask) > Bitwise.band(n_sequence, @sequence_locktime_mask), do: raise(ScriptError, "CHECKSEQUENCEVERIFY unsatisfied locktime")
    :ok
  end

  defp verify_p2tr_script_path(opts) do
    witness_items = opts.witness_items_without_annex
    if length(witness_items) < 2, do: raise(ScriptError, "taproot script-path witness too short")
    script_bytes = Enum.at(witness_items, length(witness_items) - 2)
    control = List.last(witness_items)
    stack_items = Enum.take(witness_items, length(witness_items) - 2)
    if script_bytes == <<>>, do: raise(ScriptError, "empty tapscript")
    ctl_len = byte_size(control)
    if ctl_len < 33 or ctl_len > 33 + 128 * 32 or rem(ctl_len - 33, 32) != 0, do: raise(ScriptError, "invalid taproot control block length")
    leaf_masked = Bitwise.band(:binary.at(control, 0), 0xFE)
    if leaf_masked == @annex_tag, do: raise(ScriptError, "invalid taproot leaf version")
    internal_x = binary_part(control, 1, 32)

    merkle_branch =
      if ctl_len == 33 do
        []
      else
        for offset <- 33..(ctl_len - 32)//32, do: binary_part(control, offset, 32)
      end

    leaf_digest = Sighash.tapleaf_hash(leaf_masked, script_bytes)
    merkle_root = Sighash.taproot_merkle_root_from_branch(merkle_branch, leaf_digest)

    {output_x, parity} =
      case Secp256k1.taproot_tweak_xonly(internal_x, merkle_root) do
        {:ok, tweaked, parity} -> {tweaked, parity}
        _ -> raise ScriptError, "taproot tweak failed"
      end

    if output_x != binary_part(opts.script_pubkey, 2, 32) or :binary.at(control, 0) != Bitwise.bor(leaf_masked, parity) do
      raise ScriptError, "taproot control block commitment mismatch"
    end

    if leaf_masked != Opcodes.taproot_leaf_version_tapscript() or tapscript_prescan_op_success?(script_bytes) do
      true
    else
      validate_tapscript_stack!(stack_items)
      budget = %{value: Opcodes.validation_weight_offset() + byte_size(opts.serialized_witness_for_weight)}

      stack =
        evaluate_tapscript(script_bytes, stack_items, %{
          tx: opts.tx,
          input_index: opts.input_index,
          spent_prevouts: opts.spent_prevouts,
          annex: opts.annex,
          tapleaf_digest: leaf_digest,
          codeseparator_pos: 0xFFFF_FFFF,
          budget: budget
        })

      if not terminal_success_strict?(stack), do: raise(ScriptError, "tapscript failed final stack check (size #{length(stack)})")
      true
    end
  end

  defp evaluate_tapscript(script, stack, ctx) do
    eval_tapscript_loop(script, 0, 0, stack, [], [], ctx)
  end

  defp eval_tapscript_loop(script, offset, _ipos, stack, _altstack, branches, _ctx) when offset >= byte_size(script) do
    if branches != [], do: raise(ScriptError, "unbalanced conditional")
    stack
  end

  defp eval_tapscript_loop(script, offset, ipos, stack, altstack, branches, ctx) do
    opcode = byte_at!(script, offset)
    f_exec = Enum.all?(branches)

    cond do
      opcode in [Opcodes.op_if(), Opcodes.op_notif()] ->
        {stack, branches} =
          if f_exec do
            {item, rest} = pop_item!(stack)
            branch = cast_to_bool?(item)
            branch = if opcode == Opcodes.op_notif(), do: not branch, else: branch
            {rest, branches ++ [branch]}
          else
            {stack, branches ++ [false]}
          end

        eval_tapscript_loop(script, offset + 1, ipos + 1, stack, altstack, branches, ctx)

      opcode == Opcodes.op_else() ->
        if branches == [], do: raise(ScriptError, "unbalanced conditional")
        {prefix, [last]} = Enum.split(branches, length(branches) - 1)
        eval_tapscript_loop(script, offset + 1, ipos + 1, stack, altstack, prefix ++ [not last], ctx)

      opcode == Opcodes.op_endif() ->
        if branches == [], do: raise(ScriptError, "unbalanced conditional")
        eval_tapscript_loop(script, offset + 1, ipos + 1, stack, altstack, Enum.drop(branches, -1), ctx)

      not f_exec ->
        eval_tapscript_loop(script, advance_opcode(script, offset), ipos + 1, stack, altstack, branches, ctx)

      opcode == Opcodes.op_checkmultisig() or opcode == Opcodes.op_checkmultisigverify() ->
        raise ScriptError, "CHECKMULTISIG disabled in tapscript"

      opcode == Opcodes.op_codeseparator() ->
        eval_tapscript_loop(script, offset + 1, ipos + 1, stack, altstack, branches, %{ctx | codeseparator_pos: ipos})

      opcode in [Opcodes.op_checksig(), Opcodes.op_checksigverify(), Opcodes.op_checksigadd()] ->
        {stack, ctx} = execute_tapscript_signature(opcode, stack, ctx)
        eval_tapscript_loop(script, offset + 1, ipos + 1, stack, altstack, branches, ctx)

      true ->
        {stack, altstack, next, _legacy_ctx} =
          execute_legacy_opcode(script, offset, opcode, stack, altstack, %{
            tx: ctx.tx,
            input_index: ctx.input_index,
            script_code: script,
            amount: 0,
            witness?: true,
            codeseparator_offset: 0
          })

        eval_tapscript_loop(script, next, ipos + 1, stack, altstack, branches, ctx)
    end
  end

  defp execute_tapscript_signature(opcode, stack, ctx) do
    if opcode == Opcodes.op_checksigadd() do
      {pubkey, stack} = pop_item!(stack)
      {n_item, stack} = pop_item!(stack)
      {signature, stack} = pop_item!(stack)
      if pubkey == <<>>, do: raise(ScriptError, "empty pubkey in tapscript checksigadd")
      n = decode_script_num(n_item)
      valid = tapscript_signature_valid?(pubkey, signature, ctx)
      {stack ++ [encode_script_num(n + if(valid, do: 1, else: 0))], ctx}
    else
      {pubkey, stack} = pop_item!(stack)
      {signature, stack} = pop_item!(stack)
      if pubkey == <<>>, do: raise(ScriptError, "empty pubkey in tapscript checksig")
      valid = tapscript_signature_valid?(pubkey, signature, ctx)

      cond do
        opcode == Opcodes.op_checksig() -> {stack ++ [encode_bool(valid)], ctx}
        valid -> {stack, ctx}
        true -> raise ScriptError, "CHECKSIGVERIFY failed"
      end
    end
  end

  defp tapscript_signature_valid?(pubkey, signature, ctx) do
    cond do
      signature == <<>> ->
        false

      byte_size(pubkey) != 32 ->
        consume_tapscript_sigop!(ctx)
        true

      byte_size(signature) not in [64, 65] ->
        raise ScriptError, "invalid Schnorr signature length"

      true ->
        consume_tapscript_sigop!(ctx)

        {hash_type, sig64} =
          if byte_size(signature) == 65 do
            hash_type = :binary.last(signature)
            if hash_type == @taproot_sighash_default, do: raise(ScriptError, "invalid tap hashtype byte")
            {hash_type, binary_part(signature, 0, 64)}
          else
            {@taproot_sighash_default, signature}
          end

        digest =
          Sighash.taproot_signature_hash(ctx.tx, ctx.input_index, ctx.spent_prevouts,
            hash_type: hash_type,
            annex: ctx.annex,
            ext_flag: 1,
            tapleaf_hash: ctx.tapleaf_digest,
            tapscript_codeseparator_pos: ctx.codeseparator_pos
          )

        Secp256k1.verify_schnorr_signature(pubkey, digest, sig64)
    end
  end

  defp consume_tapscript_sigop!(ctx) do
    new_value = ctx.budget.value - Opcodes.validation_weight_per_sigop()
    if new_value < 0, do: raise(ScriptError, "tapscript validation weight exceeded")
    Map.put(ctx.budget, :value, new_value)
    :ok
  end

  defp read_push(data, offset) do
    opcode = byte_at!(data, offset)
    offset = offset + 1

    cond do
      opcode == Opcodes.op_0() ->
        {<<>>, offset}

      opcode >= Opcodes.op_1() and opcode <= Opcodes.op_16() ->
        {<<opcode - Opcodes.op_1() + 1>>, offset}

      opcode == Opcodes.op_1negate() ->
        {<<0x81>>, offset}

      opcode >= 1 and opcode <= 75 ->
        ensure_size!(data, offset, opcode)
        {binary_part(data, offset, opcode), offset + opcode}

      opcode == Opcodes.op_pushdata1() ->
        size = byte_at!(data, offset)
        ensure_size!(data, offset + 1, size)
        {binary_part(data, offset + 1, size), offset + 1 + size}

      opcode == Opcodes.op_pushdata2() ->
        ensure_size!(data, offset, 2)
        <<size::little-unsigned-16>> = binary_part(data, offset, 2)
        ensure_size!(data, offset + 2, size)
        {binary_part(data, offset + 2, size), offset + 2 + size}

      opcode == Opcodes.op_pushdata4() ->
        ensure_size!(data, offset, 4)
        <<size::little-unsigned-32>> = binary_part(data, offset, 4)
        ensure_size!(data, offset + 4, size)
        {binary_part(data, offset + 4, size), offset + 4 + size}

      true ->
        raise ScriptError, "unsupported push opcode 0x#{Integer.to_string(opcode, 16)}"
    end
  end

  defp advance_opcode(script, offset) do
    opcode = byte_at!(script, offset)
    if push_opcode?(opcode), do: elem(read_push(script, offset), 1), else: offset + 1
  end

  defp strip_annex(witness) do
    wit = List.wrap(witness)

    if length(wit) >= 2 and List.last(wit) != <<>> and :binary.at(List.last(wit), 0) == @annex_tag do
      {Enum.drop(wit, -1), List.last(wit)}
    else
      {wit, nil}
    end
  end

  defp validate_tapscript_stack!(items) do
    if length(items) > Opcodes.max_tapscript_stack_elements(), do: raise(ScriptError, "tapscript stack too many elements")

    Enum.each(items, fn item ->
      if byte_size(item) > Opcodes.max_script_element_size_consensus(), do: raise(ScriptError, "tapscript stack element too large")
    end)
  end

  defp tapscript_prescan_op_success?(script) do
    do_tapscript_prescan(script, 0)
  end

  defp do_tapscript_prescan(script, offset) when offset >= byte_size(script), do: false

  defp do_tapscript_prescan(script, offset) do
    opcode = byte_at!(script, offset)
    if tapscript_opcode_success?(opcode), do: true, else: do_tapscript_prescan(script, advance_opcode(script, offset))
  end

  defp tapscript_opcode_success?(opcode) do
    opcode in [80, 98] or opcode in 126..129 or opcode in 131..134 or opcode in 137..138 or opcode in 141..142 or opcode in 149..153 or opcode in 187..254
  end

  defp push_opcode?(opcode), do: (opcode >= 1 and opcode <= 75) or opcode in [Opcodes.op_pushdata1(), Opcodes.op_pushdata2(), Opcodes.op_pushdata4()]

  defp pop_item!(stack, message \\ "stack underflow") do
    case stack do
      [] -> raise ScriptError, message
      _ -> {List.last(stack), Enum.drop(stack, -1)}
    end
  end

  defp stack_item(stack, i), do: Enum.at(stack, length(stack) - i)

  defp require_stack!(stack, n), do: if(length(stack) < n, do: raise(ScriptError, "stack underflow"), else: :ok)

  defp cast_to_bool?(<<>>), do: false

  defp cast_to_bool?(item) do
    bytes = :binary.bin_to_list(item)
    last_index = length(bytes) - 1

    bytes
    |> Enum.with_index()
    |> Enum.any?(fn {b, i} -> b != 0 and not (i == last_index and b == 0x80) end)
  end

  defp encode_bool(true), do: <<1>>
  defp encode_bool(false), do: <<>>

  defp encode_script_num(0), do: <<>>

  defp encode_script_num(value) when is_integer(value) do
    negative = value < 0
    abs_value = abs(value)
    bytes = encode_abs_le(abs_value, [])
    last = List.last(bytes)

    bytes =
      if Bitwise.band(last, 0x80) != 0 do
        bytes ++ [if(negative, do: 0x80, else: 0)]
      else
        List.replace_at(bytes, length(bytes) - 1, if(negative, do: Bitwise.bor(last, 0x80), else: last))
      end

    :binary.list_to_bin(bytes)
  end

  defp encode_abs_le(0, []), do: [0]
  defp encode_abs_le(0, acc), do: acc
  defp encode_abs_le(value, acc), do: encode_abs_le(div(value, 256), acc ++ [rem(value, 256)])

  defp decode_script_num(data, max_size \\ @max_scriptnum_size) do
    if byte_size(data) > max_size, do: raise(ScriptError, "script number overflow")
    if data == <<>>, do: 0, else: decode_script_num_nonempty(data)
  end

  defp decode_script_num_nonempty(data) do
    last_index = byte_size(data) - 1
    last = :binary.at(data, last_index)
    negative = Bitwise.band(last, 0x80) != 0
    cleared = binary_part(data, 0, last_index) <> <<Bitwise.band(last, 0x7F)>>
    value = :binary.decode_unsigned(cleared, :little)
    if negative, do: -value, else: value
  end

  defp decode_script_num_unsigned(data, max_size) do
    if byte_size(data) > max_size, do: raise(ScriptError, "script number overflow")
    if data == <<>>, do: 0, else: :binary.decode_unsigned(data, :little)
  end

  defp terminal_success_strict?([item]), do: cast_to_bool?(item)
  defp terminal_success_strict?(_), do: false
  defp terminal_success_relaxed?(stack), do: stack != [] and cast_to_bool?(List.last(stack))

  defp byte_at!(data, offset) do
    if offset < 0 or offset >= byte_size(data), do: raise(ScriptError, "script read out of bounds")
    :binary.at(data, offset)
  end

  defp ensure_size!(data, offset, size) do
    if offset + size > byte_size(data), do: raise(ScriptError, "push exceeds script length")
  end

  defp script_code_after_separator(%{codeseparator_offset: offset, script_code: script_code}) when offset > 0 do
    binary_part(script_code, offset, byte_size(script_code) - offset)
  end

  defp script_code_after_separator(%{script_code: script_code}), do: script_code

  defp locktime_type(value), do: if(value < @locktime_threshold, do: :height, else: :time)
  defp bare_puzzle_script?(ctx), do: not ctx.witness? and byte_size(ctx.script_code) > 6_000
  defp bare_puzzle_placeholder_signature?(sig, ctx), do: bare_puzzle_script?(ctx) and (sig == <<>> or byte_size(sig) < 48)
end
