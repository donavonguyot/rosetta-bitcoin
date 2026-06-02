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

  def p2pkh_script_code(pubkey_hash) when is_binary(pubkey_hash) do
    <<Opcodes.op_dup(), Opcodes.op_hash160(), byte_size(pubkey_hash), pubkey_hash::binary,
      Opcodes.op_equalverify(), Opcodes.op_checksig()>>
  end

  def verify_script(
        script_sig,
        script_pubkey,
        tx,
        input_index,
        amount,
        witness,
        spent_prevouts \\ nil
      )
      when is_binary(script_sig) and is_binary(script_pubkey) do
    cond do
      ScriptTemplates.is_p2pk?(script_pubkey) ->
        verify_p2pk(script_sig, script_pubkey, tx, input_index, amount)

      ScriptTemplates.is_p2wpkh?(script_pubkey) ->
        verify_p2wpkh(script_pubkey, tx, input_index, amount, witness)

      ScriptTemplates.is_p2tr?(script_pubkey) ->
        verify_p2tr_keypath(script_sig, script_pubkey, tx, input_index, witness, spent_prevouts)

      true ->
        verify_legacy(script_sig, script_pubkey, tx, input_index, amount)
    end
  end

  defp verify_p2pk(script_sig, script_pubkey, tx, input_index, amount) do
    if not witness_empty?(tx, input_index) do
      false
    else
      try do
        pushes = parse_push_only_script_sig(script_sig)

        if length(pushes) != 1 or hd(pushes) == <<>> do
          false
        else
          stack_after_sig =
            evaluate_script(script_sig, [], tx, input_index, script_pubkey, amount, false)

          stack =
            evaluate_script(
              script_pubkey,
              stack_after_sig,
              tx,
              input_index,
              script_pubkey,
              amount,
              false
            )

          terminal_success_strict?(stack)
        end
      rescue
        ScriptError -> false
      end
    end
  end

  defp verify_p2wpkh(script_pubkey, tx, input_index, amount, witness) do
    input = Enum.at(tx.inputs, input_index)

    if byte_size(input.script_sig) > 0 or length(witness) != 2 do
      false
    else
      pubkey_hash = binary_part(script_pubkey, 2, 20)
      script_code = p2pkh_script_code(pubkey_hash)
      stack = witness

      try do
        stack = evaluate_script(script_code, stack, tx, input_index, script_code, amount, true)
        terminal_success_strict?(stack)
      rescue
        ScriptError -> false
      end
    end
  end

  defp verify_p2tr_keypath(script_sig, script_pubkey, tx, input_index, witness, spent_prevouts) do
    if byte_size(script_sig) > 0 or spent_prevouts == nil do
      false
    else
      output_key_x = binary_part(script_pubkey, 2, 32)
      {wit, annex} = strip_annex(witness)

      cond do
        length(wit) >= 2 ->
          false

        length(wit) != 1 ->
          false

        true ->
          sigblob = hd(wit)

          cond do
            byte_size(sigblob) not in [64, 65] ->
              false

            true ->
              {hash_type, sig64} =
                if byte_size(sigblob) == 65 do
                  hash_type = :binary.last(sigblob)

                  if hash_type == @taproot_sighash_default do
                    {nil, nil}
                  else
                    {hash_type, binary_part(sigblob, 0, 64)}
                  end
                else
                  {@taproot_sighash_default, sigblob}
                end

              if hash_type == nil do
                false
              else
                try do
                  digest =
                    Sighash.taproot_signature_hash(
                      tx,
                      input_index,
                      spent_prevouts,
                      hash_type: hash_type,
                      annex: annex
                    )

                  Secp256k1.verify_schnorr_signature(output_key_x, digest, sig64)
                rescue
                  _ -> false
                end
              end
          end
      end
    end
  end

  defp strip_annex(witness) do
    wit = List.wrap(witness)

    if length(wit) >= 2 do
      last = List.last(wit)

      if last != <<>> and :binary.at(last, 0) == @annex_tag do
        {Enum.drop(wit, -1), last}
      else
        {wit, nil}
      end
    else
      {wit, nil}
    end
  end

  defp verify_legacy(script_sig, script_pubkey, tx, input_index, amount) do
    try do
      stack_after_sig =
        evaluate_script(script_sig, [], tx, input_index, script_pubkey, amount, false)

      stack =
        evaluate_script(
          script_pubkey,
          stack_after_sig,
          tx,
          input_index,
          script_pubkey,
          amount,
          false
        )

      terminal_success_strict?(stack)
    rescue
      ScriptError -> false
    end
  end

  def parse_push_only_script_sig(script_sig) when is_binary(script_sig) do
    do_parse_push_only(script_sig, 0, [])
  end

  defp do_parse_push_only(script_sig, offset, acc) when offset >= byte_size(script_sig),
    do: Enum.reverse(acc)

  defp do_parse_push_only(script_sig, offset, acc) do
    opcode = :binary.at(script_sig, offset)
    offset = offset + 1

    cond do
      opcode == Opcodes.op_0() ->
        do_parse_push_only(script_sig, offset, [<<>> | acc])

      opcode >= Opcodes.op_1() and opcode <= Opcodes.op_16() ->
        do_parse_push_only(script_sig, offset, [<<opcode - Opcodes.op_1() + 1>> | acc])

      opcode == Opcodes.op_1negate() ->
        do_parse_push_only(script_sig, offset, [<<0x81>> | acc])

      (opcode >= 1 and opcode <= 75) or
          opcode in [Opcodes.op_pushdata1(), Opcodes.op_pushdata2(), Opcodes.op_pushdata4()] ->
        {item, next} = read_push(script_sig, offset - 1)
        do_parse_push_only(script_sig, next, [item | acc])

      true ->
        raise ScriptError, "non-push opcode in P2SH scriptSig"
    end
  end

  defp evaluate_script(script, stack, tx, input_index, script_code, amount, witness?) do
    do_evaluate_script(script, 0, stack, tx, input_index, script_code, amount, witness?)
  end

  defp do_evaluate_script(script, offset, stack, tx, input_index, script_code, amount, witness?)
       when offset >= byte_size(script),
       do: stack

  defp do_evaluate_script(script, offset, stack, tx, input_index, script_code, amount, witness?) do
    opcode = :binary.at(script, offset)
    offset = offset + 1

    {stack, offset} =
      cond do
        opcode == Opcodes.op_0() ->
          {stack ++ [<<>>], offset}

        opcode >= Opcodes.op_1() and opcode <= Opcodes.op_16() ->
          {stack ++ [<<opcode - Opcodes.op_1() + 1>>], offset}

        opcode == Opcodes.op_1negate() ->
          {stack ++ [<<0x81>>], offset}

        (opcode >= 1 and opcode <= 75) or
            opcode in [Opcodes.op_pushdata1(), Opcodes.op_pushdata2(), Opcodes.op_pushdata4()] ->
          {item, next} = read_push(script, offset - 1)
          {stack ++ [item], next}

        opcode == Opcodes.op_dup() ->
          {item, rest} = pop_item!(stack)
          {rest ++ [item, item], offset}

        opcode == Opcodes.op_hash160() ->
          {item, rest} = pop_item!(stack)
          {rest ++ [CryptoUtil.hash160(item)], offset}

        opcode == Opcodes.op_equal() ->
          {b_val, rest1} = pop_item!(stack)
          {a_val, rest2} = pop_item!(rest1)
          {rest2 ++ [encode_op_n(if(a_val == b_val, do: 1, else: 0))], offset}

        opcode == Opcodes.op_equalverify() ->
          {b_val, rest1} = pop_item!(stack)
          {a_val, rest2} = pop_item!(rest1)

          if a_val != b_val do
            raise ScriptError, "EQUALVERIFY failed"
          end

          {rest2, offset}

        opcode in [Opcodes.op_checksig(), Opcodes.op_checksigverify()] ->
          {pubkey, rest1} = pop_item!(stack)
          {signature, rest2} = pop_item!(rest1)

          valid =
            check_ecdsa_signature(
              signature,
              pubkey,
              tx,
              input_index,
              script_code,
              amount,
              witness?
            )

          if opcode == Opcodes.op_checksig() do
            {rest2 ++ [encode_op_n(if(valid, do: 1, else: 0))], offset}
          else
            if valid do
              {rest2, offset}
            else
              raise ScriptError, "CHECKSIGVERIFY failed"
            end
          end

        true ->
          raise ScriptError, "unsupported opcode 0x#{Integer.to_string(opcode, 16)}"
      end

    do_evaluate_script(script, offset, stack, tx, input_index, script_code, amount, witness?)
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
  end

  defp read_push(data, offset) do
    opcode = :binary.at(data, offset)
    offset = offset + 1

    cond do
      opcode == Opcodes.op_0() ->
        {<<>>, offset}

      opcode >= Opcodes.op_1() and opcode <= Opcodes.op_16() ->
        {<<opcode - Opcodes.op_1() + 1>>, offset}

      opcode == Opcodes.op_1negate() ->
        {<<0x81>>, offset}

      opcode >= 1 and opcode <= 75 ->
        {binary_part(data, offset, opcode), offset + opcode}

      opcode == Opcodes.op_pushdata1() ->
        size = :binary.at(data, offset)
        {binary_part(data, offset + 1, size), offset + 1 + size}

      opcode == Opcodes.op_pushdata2() ->
        <<size::little-unsigned-16, rest::binary>> = binary_part(data, offset, 2)
        {binary_part(rest, 0, size), offset + 2 + size}

      opcode == Opcodes.op_pushdata4() ->
        <<size::little-unsigned-32, rest::binary>> = binary_part(data, offset, 4)
        {binary_part(rest, 0, size), offset + 4 + size}

      true ->
        raise ScriptError, "unsupported push opcode 0x#{Integer.to_string(opcode, 16)}"
    end
  end

  defp pop_item!(stack) do
    case stack do
      [] -> raise ScriptError, "stack underflow"
      _ -> {List.last(stack), Enum.drop(stack, -1)}
    end
  end

  defp cast_to_bool?(item) do
    if item == <<>> do
      false
    else
      Enum.any?(:binary.bin_to_list(item), fn b -> b != 0 and b != 0x80 end)
    end
  end

  defp encode_op_n(0), do: <<>>
  defp encode_op_n(n) when n >= 1 and n <= 16, do: <<n>>
  defp encode_op_n(_), do: raise(ScriptError, "cannot encode numeric")

  defp terminal_success_strict?([item]), do: cast_to_bool?(item)
  defp terminal_success_strict?(_), do: false

  defp witness_empty?(tx, input_index) do
    tx.witness == [] or input_index >= length(tx.witness) or
      Enum.at(tx.witness, input_index) == []
  end
end
