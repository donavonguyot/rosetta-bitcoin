defmodule Exbitnode.Consensus.BlockValidationError do
  defexception [:message]
end

defmodule Exbitnode.Consensus.BlockValidator do
  @moduledoc false

  alias Exbitnode.Consensus.{Block.BlockDeserializer, BlockValidationError, Merkle}
  alias Exbitnode.Consensus.Tx.Transaction
  alias Exbitnode.Messages.BlockHeaderCodec

  def validate_block(payload, expected_prev_internal, expected_hash_internal)
      when is_binary(payload) and is_binary(expected_prev_internal) and
             is_binary(expected_hash_internal) do
    block = BlockDeserializer.deserialize(payload)
    hash = BlockHeaderCodec.block_hash(block.header)

    cond do
      hash != expected_hash_internal ->
        raise BlockValidationError, "block hash mismatch"

      block.header.prev_block != expected_prev_internal ->
        raise BlockValidationError, "prev block hash mismatch"

      block.header.merkle_root != Merkle.block_merkle_root(block.transactions) ->
        raise BlockValidationError, "merkle root mismatch"

      block.transactions == [] or not Transaction.coinbase?(hd(block.transactions)) ->
        raise BlockValidationError, "first transaction must be coinbase"

      true ->
        block
    end
  end
end
