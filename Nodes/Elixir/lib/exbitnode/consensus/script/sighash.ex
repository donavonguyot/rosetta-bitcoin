defmodule Exbitnode.Consensus.Script.Sighash do
  @moduledoc false

  alias Exbitnode.Consensus.Tx.{OutPoint, Transaction, TxIn, TxOut}
  alias Exbitnode.Util.CryptoUtil
  alias Exbitnode.Wire.WireSerialize

  @taproot_sighash_default 0
  @taproot_sighash_all 1
  @taproot_sighash_single 3

  def legacy_sighash(%Transaction{} = tx, input_index, script_code, sighash_type \\ 1)
      when is_binary(script_code) do
    base_type = Bitwise.band(sighash_type, 0x1F)
    anyone_can_pay = Bitwise.band(sighash_type, 0x80) != 0

    if base_type == 3 and input_index >= length(tx.outputs) do
      <<1>> <> :binary.copy(<<0>>, 31)
    else
      inputs =
        if anyone_can_pay do
          [Enum.at(tx.inputs, input_index)]
        else
          tx.inputs
        end

      parts = [
        WireSerialize.pack_int32_le(tx.version),
        WireSerialize.write_compact_size(length(inputs))
      ]

      parts =
        Enum.with_index(inputs)
        |> Enum.reduce(parts, fn {tx_in, index}, acc ->
          source_index = if anyone_can_pay, do: input_index, else: index

          script_part =
            if source_index == input_index do
              WireSerialize.write_compact_size(byte_size(script_code)) <> script_code
            else
              <<0>>
            end

          sequence =
            if anyone_can_pay or base_type == 1 or source_index == input_index do
              WireSerialize.pack_int32_le(Enum.at(tx.inputs, source_index).sequence)
            else
              <<0, 0, 0, 0>>
            end

          acc ++
            [
              tx_in.previous_output.hash,
              WireSerialize.pack_int32_le(tx_in.previous_output.index),
              script_part,
              sequence
            ]
        end)

      parts =
        cond do
          base_type == 2 ->
            parts ++ [WireSerialize.write_compact_size(0)]

          base_type == 3 ->
            placeholders =
              if input_index == 0 do
                []
              else
                Enum.map(1..input_index, fn _ -> %TxOut{value: -1, script_pubkey: <<>>} end)
              end

            outputs = placeholders ++ [Enum.at(tx.outputs, input_index)]

            parts ++
              [
                WireSerialize.write_compact_size(input_index + 1)
                | Enum.map(outputs, &serialize_output/1)
              ]

          true ->
            parts ++
              [
                WireSerialize.write_compact_size(length(tx.outputs))
                | Enum.map(tx.outputs, &serialize_output/1)
              ]
        end

      parts =
        parts ++
          [WireSerialize.pack_int32_le(tx.lock_time), WireSerialize.pack_int32_le(sighash_type)]

      CryptoUtil.double_sha256(IO.iodata_to_binary(parts))
    end
  end

  def bip143_sighash(%Transaction{} = tx, input_index, script_code, amount, sighash_type \\ 1)
      when is_binary(script_code) do
    anyone_can_pay = Bitwise.band(sighash_type, 0x80) != 0
    base_type = Bitwise.band(sighash_type, 0x1F)

    hash_prevouts =
      if anyone_can_pay do
        :binary.copy(<<0>>, 32)
      else
        prevouts =
          Enum.reduce(tx.inputs, [], fn input, acc ->
            acc ++
              [
                input.previous_output.hash,
                WireSerialize.pack_int32_le(input.previous_output.index)
              ]
          end)

        CryptoUtil.double_sha256(IO.iodata_to_binary(prevouts))
      end

    hash_sequence =
      if anyone_can_pay or base_type in [2, 3] do
        :binary.copy(<<0>>, 32)
      else
        sequences =
          Enum.reduce(tx.inputs, [], fn input, acc ->
            acc ++ [WireSerialize.pack_int32_le(input.sequence)]
          end)

        CryptoUtil.double_sha256(IO.iodata_to_binary(sequences))
      end

    hash_outputs =
      cond do
        base_type == 3 and input_index < length(tx.outputs) ->
          CryptoUtil.double_sha256(serialize_output(Enum.at(tx.outputs, input_index)))

        base_type == 2 ->
          :binary.copy(<<0>>, 32)

        true ->
          outputs =
            Enum.reduce(tx.outputs, [], fn output, acc -> acc ++ [serialize_output(output)] end)

          CryptoUtil.double_sha256(IO.iodata_to_binary(outputs))
      end

    tx_in = Enum.at(tx.inputs, input_index)

    payload =
      IO.iodata_to_binary([
        WireSerialize.pack_int32_le(tx.version),
        hash_prevouts,
        hash_sequence,
        tx_in.previous_output.hash,
        WireSerialize.pack_int32_le(tx_in.previous_output.index),
        WireSerialize.write_compact_size(byte_size(script_code)),
        script_code,
        WireSerialize.pack_int64_le(amount),
        WireSerialize.pack_int32_le(tx_in.sequence),
        hash_outputs,
        WireSerialize.pack_int32_le(tx.lock_time),
        WireSerialize.pack_int32_le(sighash_type)
      ])

    CryptoUtil.double_sha256(payload)
  end

  defp serialize_output(%TxOut{value: value, script_pubkey: script}) do
    WireSerialize.pack_int64_le(value) <>
      WireSerialize.write_compact_size(byte_size(script)) <> script
  end

  def tapleaf_hash(leaf_version, tapscript_bytes)
      when is_integer(leaf_version) and is_binary(tapscript_bytes) do
    CryptoUtil.bitcoin_tagged_hash(
      "TapLeaf",
      <<Bitwise.band(leaf_version, 0xFF)>> <>
        WireSerialize.write_compact_size(byte_size(tapscript_bytes)) <> tapscript_bytes
    )
  end

  def tapbranch_hash(left, right) when is_binary(left) and is_binary(right) do
    pair = if left < right, do: left <> right, else: right <> left
    CryptoUtil.bitcoin_tagged_hash("TapBranch", pair)
  end

  def taproot_merkle_root_from_branch(branch_nodes, leaf_hash)
      when is_list(branch_nodes) and is_binary(leaf_hash) do
    Enum.reduce(branch_nodes, leaf_hash, fn sibling, acc -> tapbranch_hash(acc, sibling) end)
  end

  def serialized_witness_stack_bytes(stack) when is_list(stack) do
    Enum.reduce(stack, WireSerialize.write_compact_size(length(stack)), fn item, acc ->
      acc <> WireSerialize.write_compact_size(byte_size(item)) <> item
    end)
  end

  def taproot_signature_hash(%Transaction{} = tx, input_index, spent_prevouts, opts \\ [])
      when is_list(spent_prevouts) do
    hash_type = Keyword.get(opts, :hash_type, @taproot_sighash_default)
    annex = Keyword.get(opts, :annex)
    ext_flag = Keyword.get(opts, :ext_flag, 0)
    tapleaf_hash_value = Keyword.get(opts, :tapleaf_hash)
    codeseparator_pos = Keyword.get(opts, :tapscript_codeseparator_pos, 0xFFFF_FFFF)

    if length(spent_prevouts) != length(tx.inputs) do
      raise ArgumentError, "spent_prevouts length mismatch"
    end

    unless taproot_allowed_hashtype?(hash_type) do
      raise ArgumentError, "unsupported taproot sighash type"
    end

    annex_present = annex != nil

    if ext_flag not in [0, 1] do
      raise ArgumentError, "invalid taproot ext_flag"
    end

    if ext_flag == 1 and (not is_binary(tapleaf_hash_value) or byte_size(tapleaf_hash_value) != 32) do
      raise ArgumentError, "tapscript sighash requires 32-byte tapleaf_hash"
    end

    output_mode =
      if hash_type == @taproot_sighash_default,
        do: @taproot_sighash_all,
        else: Bitwise.band(hash_type, 0x03)

    anyone_can_pay = Bitwise.band(hash_type, 0x80) != 0

    body = [
      <<hash_type>>,
      WireSerialize.pack_int32_le(tx.version),
      WireSerialize.pack_int32_le(tx.lock_time)
    ]

    body =
      if anyone_can_pay do
        if input_index >= length(tx.inputs), do: raise(ArgumentError, "input_index out of range")
        body
      else
        prev_blob =
          Enum.reduce(tx.inputs, [], fn %TxIn{previous_output: %OutPoint{} = out}, acc ->
            acc ++ [out.hash, WireSerialize.pack_int32_le(out.index)]
          end)

        amounts_blob =
          Enum.reduce(spent_prevouts, [], fn {amt, _spk}, acc ->
            acc ++ [WireSerialize.pack_int64_le(amt)]
          end)

        script_blob =
          Enum.reduce(spent_prevouts, [], fn {_amt, spk}, acc ->
            acc ++ [WireSerialize.write_compact_size(byte_size(spk)), spk]
          end)

        sequences_blob =
          Enum.reduce(tx.inputs, [], fn %TxIn{sequence: seq}, acc ->
            acc ++ [WireSerialize.pack_int32_le(seq)]
          end)

        body ++
          [
            sha256_concat(prev_blob),
            sha256_concat(amounts_blob),
            sha256_concat(script_blob),
            sha256_concat(sequences_blob)
          ]
      end

    body =
      cond do
        output_mode == @taproot_sighash_all ->
          outs_blob =
            Enum.reduce(tx.outputs, [], fn output, acc -> acc ++ [serialize_output(output)] end)

          body ++ [sha256_concat(outs_blob)]

        output_mode == @taproot_sighash_single ->
          if input_index >= length(tx.outputs),
            do: raise(ArgumentError, "SIGHASH_SINGLE without matching output")

          body

        true ->
          body
      end

    spend_type = Bitwise.bsl(ext_flag, 1) + if(annex_present, do: 1, else: 0)
    body = body ++ [<<spend_type>>]

    body =
      if anyone_can_pay do
        tin = Enum.at(tx.inputs, input_index)
        {amt, spk} = Enum.at(spent_prevouts, input_index)
        utxo_blob = serialize_output(%TxOut{value: amt, script_pubkey: spk})

        body ++
          [
            tin.previous_output.hash,
            WireSerialize.pack_int32_le(tin.previous_output.index),
            utxo_blob,
            WireSerialize.pack_int32_le(tin.sequence)
          ]
      else
        body ++ [WireSerialize.pack_int32_le(input_index)]
      end

    body =
      if annex_present do
        annex_bin = annex || <<>>

        body ++
          [
            :crypto.hash(
              :sha256,
              WireSerialize.write_compact_size(byte_size(annex_bin)) <> annex_bin
            )
          ]
      else
        body
      end

    body =
      if output_mode == @taproot_sighash_single do
        body ++ [:crypto.hash(:sha256, serialize_output(Enum.at(tx.outputs, input_index)))]
      else
        body
      end

    body =
      if ext_flag == 1 do
        body ++ [tapleaf_hash_value, <<0>>, pack_uint32_le(codeseparator_pos)]
      else
        body
      end

    sigmsg = <<0>> <> IO.iodata_to_binary(body)
    CryptoUtil.bitcoin_tagged_hash("TapSighash", sigmsg)
  end

  defp taproot_allowed_hashtype?(hash_type) do
    hash_type <= 0x03 or (hash_type >= 0x81 and hash_type <= 0x83)
  end

  defp sha256_concat(parts) do
    :crypto.hash(:sha256, IO.iodata_to_binary(parts))
  end

  defp pack_uint32_le(value), do: <<Bitwise.band(value, 0xFFFF_FFFF)::little-unsigned-32>>
end
