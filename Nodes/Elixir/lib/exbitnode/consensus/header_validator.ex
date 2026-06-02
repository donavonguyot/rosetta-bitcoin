defmodule Exbitnode.Consensus.HeaderValidator do
  @moduledoc false

  alias Exbitnode.Consensus.BlockHeader
  alias Exbitnode.Messages.BlockHeaderCodec
  alias Exbitnode.Util.Hex

  defmodule Target do
    @moduledoc false
    import Bitwise

    def from_bits(bits) when is_integer(bits) do
      exponent = bits >>> 24
      mantissa = bits &&& 0x007F_FFFF

      if exponent <= 3 do
        mantissa >>> (8 * (3 - exponent))
      else
        mantissa * Integer.pow(256, exponent - 3)
      end
    end

    def meets_target?(block_hash_internal, bits) when is_binary(block_hash_internal) do
      target = from_bits(bits)
      hash_int = :binary.decode_unsigned(Hex.reverse(block_hash_internal), :big)
      hash_int <= target
    end
  end

  def validate_header(%BlockHeader{} = header, expected_prev_internal) do
    if header.prev_block != expected_prev_internal do
      raise Exbitnode.Consensus.HeaderValidationError, "prev block hash mismatch"
    end

    hash = BlockHeaderCodec.block_hash(header)

    unless Target.meets_target?(hash, header.bits) do
      raise Exbitnode.Consensus.HeaderValidationError, "header does not meet proof-of-work target"
    end

    :ok
  end
end

defmodule Exbitnode.Consensus.HeaderValidationError do
  defexception [:message]
end
