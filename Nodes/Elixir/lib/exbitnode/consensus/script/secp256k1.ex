defmodule Exbitnode.Consensus.Script.Secp256k1 do
  @moduledoc false

  @p 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
  @n 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
  @b 7
  @gx 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
  @gy 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8

  def verify_der_signature(pubkey, message_hash, signature)
      when is_binary(pubkey) and is_binary(message_hash) and is_binary(signature) do
    if byte_size(message_hash) != 32 do
      false
    else
      try do
        {r, s} = parse_der_signature(signature)
        {qx, qy} = decompress_pubkey(pubkey)
        z = :binary.decode_unsigned(message_hash, :big)
        w = mod_inv(s, @n)
        u1 = rem(z * w, @n)
        u2 = rem(r * w, @n)

        case point_add(scalar_mult(u1, {@gx, @gy}), scalar_mult(u2, {qx, qy})) do
          nil -> false
          {x, _y} -> rem(x, @n) == r
        end
      rescue
        _ -> false
      end
    end
  end

  def verify_schnorr_signature(pubkey_xonly, message_hash, signature)
      when is_binary(pubkey_xonly) and is_binary(message_hash) and is_binary(signature) do
    if byte_size(pubkey_xonly) != 32 or byte_size(message_hash) != 32 or byte_size(signature) != 64 do
      false
    else
      try do
        x_pub = :binary.decode_unsigned(pubkey_xonly, :big)

        with {:ok, pubkey_point} <- lift_x_only_pubkey(x_pub),
             <<rx_bytes::binary-size(32), s_bytes::binary-size(32)>> <- signature do
          rx = :binary.decode_unsigned(rx_bytes, :big)
          s = :binary.decode_unsigned(s_bytes, :big)

          if rx >= @p or s >= @n do
            false
          else
            challenge =
              Exbitnode.Util.CryptoUtil.bitcoin_tagged_hash(
                "BIP0340/challenge",
                rx_bytes <> pubkey_xonly <> message_hash
              )
              |> :binary.decode_unsigned(:big)
              |> rem(@n)

            lhs = scalar_mult(s, {@gx, @gy})
            rhs_adj = scalar_mult(rem(@n - challenge, @n), pubkey_point)
            r_pt = point_add(lhs, rhs_adj)

            case r_pt do
              nil ->
                false

              {xr, yr} ->
                rem(yr, 2) == 0 and rem(xr, @p) == rem(rx, @p)
            end
          end
        else
          _ -> false
        end
      rescue
        _ -> false
      end
    end
  end

  def lift_x_only_pubkey(x_coord) when is_integer(x_coord) do
    if x_coord >= @p do
      {:error, :invalid}
    else
      y_squared = rem(mod_pow(x_coord, 3, @p) + @b, @p)
      y = mod_pow(y_squared, div(@p + 1, 4), @p)

      if mod_pow(y, 2, @p) != y_squared do
        {:error, :invalid}
      else
        y = if rem(y, 2) == 1, do: @p - y, else: y
        {:ok, {x_coord, y}}
      end
    end
  end

  def sign_der(private_key, message_hash)
      when is_integer(private_key) and is_binary(message_hash) and byte_size(message_hash) == 32 do
    d = private_key

    if d <= 0 or d >= @n do
      raise ArgumentError, "invalid private key"
    end

    z = :binary.decode_unsigned(message_hash, :big)

    Enum.reduce_while(1..999, nil, fn nonce, _ ->
      k = nonce
      case scalar_mult(k, {@gx, @gy}) do
        nil ->
          {:cont, nil}

        {x, _y} ->
          r = rem(x, @n)

          if r == 0 do
            {:cont, nil}
          else
            s = rem(mod_inv(k, @n) * (z + r * d), @n)

            if s == 0 do
              {:cont, nil}
            else
              s = if s > div(@n, 2), do: @n - s, else: s
              r_bytes = trim_integer(r, 32)
              s_bytes = trim_integer(s, 32)
              der = <<0x30, 4 + byte_size(r_bytes) + byte_size(s_bytes), 0x02, byte_size(r_bytes), r_bytes::binary, 0x02, byte_size(s_bytes), s_bytes::binary>>
              {:halt, der}
            end
          end
      end
    end) || raise ArgumentError, "failed to sign message"
  end

  defp parse_der_signature(data) do
    <<0x30, len, 0x02, r_len, rest::binary>> = data

    if len + 2 != byte_size(data) do
      raise ArgumentError, "invalid DER signature length"
    end

    <<r_bytes::binary-size(r_len), 0x02, s_len, s_rest::binary>> = rest
    <<s_bytes::binary-size(s_len), _rest::binary>> = s_rest

    r = :binary.decode_unsigned(r_bytes, :big)
    s = :binary.decode_unsigned(s_bytes, :big)

    if r <= 0 or s <= 0 or r >= @n or s >= @n do
      raise ArgumentError, "signature r/s out of range"
    end

    {r, s}
  end

  defp decompress_pubkey(data) do
    cond do
      byte_size(data) == 33 and :binary.at(data, 0) in [0x02, 0x03] ->
        <<_, x_bytes::binary>> = data
        x = :binary.decode_unsigned(x_bytes, :big)
        y_squared = rem(mod_pow(x, 3, @p) + @b, @p)
        y = mod_pow(y_squared, div(@p + 1, 4), @p)
        y = if rem(y, 2) == 0 != (:binary.at(data, 0) == 0x02), do: @p - y, else: y
        {x, y}

      byte_size(data) == 65 and :binary.at(data, 0) == 0x04 ->
        <<_, x_bytes::binary-size(32), y_bytes::binary-size(32)>> = data
        {:binary.decode_unsigned(x_bytes, :big), :binary.decode_unsigned(y_bytes, :big)}

      true ->
        raise ArgumentError, "invalid public key encoding"
    end
  end

  defp point_add(nil, p2), do: p2
  defp point_add(p1, nil), do: p1

  defp point_add({x1, y1}, {x2, y2}) do
    if x1 == x2 and rem(y1 + y2, @p) == 0 do
      nil
    else
      slope =
        if x1 == x2 and y1 == y2 do
          rem(3 * x1 * x1 * mod_inv(rem(2 * y1, @p), @p), @p)
        else
          rem((y2 - y1) * mod_inv(rem(x2 - x1, @p), @p), @p)
        end

      x3 = rem(slope * slope - x1 - x2, @p)
      y3 = rem(slope * (x1 - x3) - y1, @p)
      {x3, y3}
    end
  end

  defp scalar_mult(0, _point), do: nil
  defp scalar_mult(k, point), do: do_scalar_mult(k, point, nil)

  defp do_scalar_mult(0, _point, result), do: result

  defp do_scalar_mult(k, point, result) do
    result = if Bitwise.band(k, 1) == 1, do: point_add(result, point), else: result
    point = point_add(point, point)
    do_scalar_mult(Bitwise.bsr(k, 1), point, result)
  end

  defp mod_inv(value, modulus), do: mod_pow(rem(value, modulus), modulus - 2, modulus)

  defp mod_pow(base, exponent, modulus) do
    do_mod_pow(rem(base, modulus), exponent, 1, modulus)
  end

  defp do_mod_pow(_base, 0, result, _modulus), do: result

  defp do_mod_pow(base, exponent, result, modulus) do
    result = if Bitwise.band(exponent, 1) == 1, do: rem(result * base, modulus), else: result
    base = rem(base * base, modulus)
    do_mod_pow(base, Bitwise.bsr(exponent, 1), result, modulus)
  end

  defp trim_integer(value, _max_len) do
    bytes = :binary.encode_unsigned(value, :big)

    cond do
      bytes == <<>> -> <<0>>
      true -> bytes
    end
  end
end
