defmodule Exbitnode.Util.CryptoUtil do
  @moduledoc false

  def double_sha256(data) when is_binary(data) do
    :crypto.hash(:sha256, :crypto.hash(:sha256, data))
  end

  def message_checksum(payload) when is_binary(payload) do
    double_sha256(payload) |> binary_part(0, 4)
  end

  def hash160(data) when is_binary(data) do
    :crypto.hash(:ripemd160, :crypto.hash(:sha256, data))
  end

  def bitcoin_tagged_hash(tag, msg) when is_binary(tag) and is_binary(msg) do
    tag_digest = :crypto.hash(:sha256, tag)
    :crypto.hash(:sha256, tag_digest <> tag_digest <> msg)
  end
end
