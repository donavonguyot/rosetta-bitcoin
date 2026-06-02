defmodule Exbitnode.Consensus.Tx.TransactionParser do
  @moduledoc false

  alias Exbitnode.Consensus.Tx.{OutPoint, Transaction, TxIn, TxOut}
  alias Exbitnode.Wire.WireSerialize

  def parse(data, offset \\ 0, witness_enabled \\ true) do
    version = WireSerialize.unpack_int32_le(data, offset)
    offset = offset + 4

    {has_witness, offset} =
      if witness_enabled and offset + 2 <= byte_size(data) and
           binary_part(data, offset, 2) == <<0, 1>> do
        {true, offset + 2}
      else
        {false, offset}
      end

    {input_count, input_read} = WireSerialize.read_compact_size_at(data, offset)
    offset = offset + input_read

    {inputs, offset} =
      if input_count == 0 do
        {[], offset}
      else
        Enum.reduce(1..input_count, {[], offset}, fn _, {acc, off} ->
          {input, off} = parse_input(data, off)
          {[input | acc], off}
        end)
        |> then(fn {acc, off} -> {Enum.reverse(acc), off} end)
      end

    {output_count, output_read} = WireSerialize.read_compact_size_at(data, offset)
    offset = offset + output_read

    {outputs, offset} =
      if output_count == 0 do
        {[], offset}
      else
        Enum.reduce(1..output_count, {[], offset}, fn _, {acc, off} ->
          {output, off} = parse_output(data, off)
          {[output | acc], off}
        end)
        |> then(fn {acc, off} -> {Enum.reverse(acc), off} end)
      end

    {witness, offset} =
      if has_witness do
        if input_count == 0 do
          {[], offset}
        else
          parse_witness(data, offset, input_count)
        end
      else
        {[], offset}
      end

    lock_time = WireSerialize.unpack_int32_le(data, offset) |> Bitwise.band(0xFFFF_FFFF)
    offset = offset + 4

    {%Transaction{
       version: version,
       inputs: inputs,
       outputs: outputs,
       lock_time: lock_time,
       witness: witness
     }, offset}
  end

  def serialize(%Transaction{} = tx, include_witness \\ false) do
    parts = [WireSerialize.pack_int32_le(tx.version)]

    parts =
      if include_witness and tx.witness != [] do
        parts ++ [<<0, 1>>]
      else
        parts
      end

    parts = parts ++ [WireSerialize.write_compact_size(length(tx.inputs))]

    parts =
      Enum.reduce(tx.inputs, parts, fn input, acc ->
        acc ++
          [
            input.previous_output.hash,
            WireSerialize.pack_int32_le(input.previous_output.index),
            WireSerialize.write_compact_size(byte_size(input.script_sig)),
            input.script_sig,
            WireSerialize.pack_int32_le(input.sequence)
          ]
      end)

    parts = parts ++ [WireSerialize.write_compact_size(length(tx.outputs))]

    parts =
      Enum.reduce(tx.outputs, parts, fn output, acc ->
        acc ++
          [
            WireSerialize.pack_int64_le(output.value),
            WireSerialize.write_compact_size(byte_size(output.script_pubkey)),
            output.script_pubkey
          ]
      end)

    parts =
      if include_witness and tx.witness != [] do
        Enum.reduce(tx.witness, parts, fn stack, acc ->
          acc =
            acc ++ [WireSerialize.write_compact_size(length(stack))]

          Enum.reduce(stack, acc, fn item, inner ->
            inner ++ [WireSerialize.write_compact_size(byte_size(item)), item]
          end)
        end)
      else
        parts
      end

    IO.iodata_to_binary(parts ++ [WireSerialize.pack_int32_le(tx.lock_time)])
  end

  defp parse_witness(data, offset, input_count) do
    if input_count == 0 do
      {[], offset}
    else
      Enum.reduce(1..input_count, {[], offset}, fn _, {acc, off} ->
        {stack_count, stack_read} = WireSerialize.read_compact_size_at(data, off)
        off = off + stack_read

        {stack, off} =
          if stack_count == 0 do
            {[], off}
          else
            Enum.reduce(1..stack_count, {[], off}, fn _, {stack_acc, stack_off} ->
              {item_len, item_read} = WireSerialize.read_compact_size_at(data, stack_off)
              stack_off = stack_off + item_read
              {item, stack_off} = WireSerialize.read_bytes(data, item_len, stack_off)
              {[item | stack_acc], stack_off}
            end)
            |> then(fn {stack_acc, stack_off} -> {Enum.reverse(stack_acc), stack_off} end)
          end

        {[stack | acc], off}
      end)
      |> then(fn {stacks, off} -> {Enum.reverse(stacks), off} end)
    end
  end

  defp parse_input(data, offset) do
    {prev_hash, offset} = WireSerialize.read_bytes(data, 32, offset)
    prev_index = WireSerialize.unpack_int32_le(data, offset) |> Bitwise.band(0xFFFF_FFFF)
    offset = offset + 4
    {script_len, script_read} = WireSerialize.read_compact_size_at(data, offset)
    offset = offset + script_read
    {script_sig, offset} = WireSerialize.read_bytes(data, script_len, offset)
    sequence = WireSerialize.unpack_int32_le(data, offset) |> Bitwise.band(0xFFFF_FFFF)
    offset = offset + 4

    {%TxIn{
       previous_output: %OutPoint{hash: prev_hash, index: prev_index},
       script_sig: script_sig,
       sequence: sequence
     }, offset}
  end

  defp parse_output(data, offset) do
    value = WireSerialize.unpack_int64_le(data, offset)
    offset = offset + 8
    {script_len, script_read} = WireSerialize.read_compact_size_at(data, offset)
    offset = offset + script_read
    {script, offset} = WireSerialize.read_bytes(data, script_len, offset)

    {%TxOut{value: value, script_pubkey: script}, offset}
  end
end
