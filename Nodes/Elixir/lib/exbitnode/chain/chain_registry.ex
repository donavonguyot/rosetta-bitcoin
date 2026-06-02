defmodule Exbitnode.Chain.ChainRegistry do
  @moduledoc false

  alias Exbitnode.Chain.{ChainParams, Genesis}
  alias Exbitnode.Util.Hex

  @testnet4 %ChainParams{
    name: "testnet4",
    magic: Hex.decode("1c163f28"),
    default_port: 48_333,
    genesis_hash: Genesis.testnet4_hash(),
    protocol_version: 70_016,
    user_agent: "/exbitnode:0.1.0/"
  }

  @chains %{"testnet4" => @testnet4}

  def get(name) when is_binary(name) do
    case Map.get(@chains, String.downcase(name)) do
      nil -> raise ArgumentError, "Unknown chain #{name}; choose from #{Map.keys(@chains) |> Enum.join(", ")}"
      chain -> chain
    end
  end

  def default_chain, do: @testnet4
end
