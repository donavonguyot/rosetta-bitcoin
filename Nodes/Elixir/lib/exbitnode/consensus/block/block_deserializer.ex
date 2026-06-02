defmodule Exbitnode.Consensus.Block.Block do
  @moduledoc false

  alias Exbitnode.Consensus.BlockHeader

  defstruct [:header, :transactions]
end

defmodule Exbitnode.Consensus.Block.BlockDeserializer do
  @moduledoc false

  alias Exbitnode.Consensus.Block.Block
  alias Exbitnode.Consensus.Tx.TransactionParser
  alias Exbitnode.Messages.BlockHeaderCodec
  alias Exbitnode.Wire.WireSerialize

  def deserialize(payload) when is_binary(payload) do
    {header, offset} = BlockHeaderCodec.deserialize(payload, 0)
    {tx_count, tx_read} = WireSerialize.read_compact_size_at(payload, offset)
    offset = offset + tx_read

    {transactions, _offset} =
      if tx_count == 0 do
        {[], offset}
      else
        Enum.reduce(1..tx_count, {[], offset}, fn _, {acc, off} ->
          {tx, off} = TransactionParser.parse(payload, off)
          {[tx | acc], off}
        end)
        |> then(fn {acc, off} -> {Enum.reverse(acc), off} end)
      end
    %Block{header: header, transactions: transactions}
  end
end
