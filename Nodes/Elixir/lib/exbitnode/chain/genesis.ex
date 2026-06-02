defmodule Exbitnode.Chain.Genesis do
  @moduledoc false

  alias Exbitnode.Consensus.BlockHeader
  alias Exbitnode.Messages.BlockHeaderCodec
  alias Exbitnode.Util.Hex

  @testnet4 %BlockHeader{
    version: 1,
    prev_block: <<0::256>>,
    merkle_root: Hex.reverse(Hex.decode("7aa0a7ae1e223414cb807e40cd57e667b718e42aaf9306db9102fe28912b7b4e")),
    timestamp: 1_714_777_860,
    bits: 0x1D00FFFF,
    nonce: 393_743_547
  }

  def testnet4, do: @testnet4
  def testnet4_hash, do: BlockHeaderCodec.block_hash_hex(@testnet4)

  def for_chain("testnet4"), do: @testnet4

  def for_chain(name) do
    raise ArgumentError, "No genesis header defined for chain #{name}"
  end
end
