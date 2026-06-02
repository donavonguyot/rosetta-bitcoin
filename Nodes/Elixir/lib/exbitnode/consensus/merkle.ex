defmodule Exbitnode.Consensus.Merkle do
  @moduledoc false

  alias Exbitnode.Consensus.Tx.{Transaction, TransactionParser}
  alias Exbitnode.Wire.WireSerialize

  def transaction_txid(%Transaction{} = tx) do
    tx |> TransactionParser.serialize(false) |> WireSerialize.double_sha256()
  end

  def compute_root([]), do: :binary.copy(<<0>>, 32)

  def compute_root([single]), do: single

  def compute_root(hashes) do
    layer = Enum.map(hashes, & &1)

    compute_layer(layer)
  end

  defp compute_layer([root]), do: root

  defp compute_layer(layer) do
    layer =
      if rem(length(layer), 2) == 1 do
        layer ++ [List.last(layer)]
      else
        layer
      end

    next =
      layer
      |> Enum.chunk_every(2)
      |> Enum.map(fn [left, right] ->
        WireSerialize.double_sha256(left <> right)
      end)

    compute_layer(next)
  end

  def block_merkle_root(transactions) when is_list(transactions) do
    transactions
    |> Enum.map(&transaction_txid/1)
    |> compute_root()
  end
end
