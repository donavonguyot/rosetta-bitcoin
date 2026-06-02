defmodule Exbitnode.Consensus.BlockHeader do
  @moduledoc false

  @enforce_keys [:version, :prev_block, :merkle_root, :timestamp, :bits, :nonce]
  defstruct [:version, :prev_block, :merkle_root, :timestamp, :bits, :nonce]
end
