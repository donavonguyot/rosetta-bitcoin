defmodule Exbitnode.Chain.ChainParams do
  @moduledoc false

  @enforce_keys [:name, :magic, :default_port, :genesis_hash, :protocol_version, :user_agent]
  defstruct [:name, :magic, :default_port, :genesis_hash, :protocol_version, :user_agent]
end
