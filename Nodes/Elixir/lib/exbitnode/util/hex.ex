defmodule Exbitnode.Util.Hex do
  @moduledoc false

  def encode(data) when is_binary(data) do
    Base.encode16(data, case: :lower)
  end

  def decode(hex) when is_binary(hex) do
    Base.decode16!(hex, case: :mixed)
  end

  def reverse(data) when is_binary(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.reverse()
    |> :binary.list_to_bin()
  end
end
