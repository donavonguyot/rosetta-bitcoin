defmodule Exbitnode.Messages.InventoryMessages do
  @moduledoc false

  alias Exbitnode.Wire.WireSerialize

  @msg_block 2
  @msg_witness_block 0x4000_0002
  @msg_witness_tx 0x4000_0001

  def msg_block, do: @msg_block
  def msg_witness_block, do: @msg_witness_block
  def msg_witness_tx, do: @msg_witness_tx

  def inv_command, do: "inv"
  def getdata_command, do: "getdata"
  def notfound_command, do: "notfound"

  def serialize_getdata(vectors) when is_list(vectors) do
    parts = [WireSerialize.write_compact_size(length(vectors))]

    Enum.reduce(vectors, parts, fn {type, hash}, acc ->
      acc ++ [WireSerialize.pack_int32_le(type), hash]
    end)
    |> IO.iodata_to_binary()
  end
end

defmodule Exbitnode.Messages.BlockMessage do
  @moduledoc false

  alias Exbitnode.Messages.BlockHeaderCodec

  def command, do: "block"

  def block_hash_from_payload(payload) when is_binary(payload) do
    {header, _} = BlockHeaderCodec.deserialize(payload, 0)
    BlockHeaderCodec.block_hash(header)
  end
end
