defmodule :exbitnode_native_secp256k1 do
  @moduledoc false

  @on_load :load_nif

  def load_nif do
    load_from_candidates("exbitnode_native_secp256k1")
  end

  defp load_from_candidates(name) do
    candidates =
      [
        :code.priv_dir(:exbitnode),
        Path.join(File.cwd!(), "priv")
      ]
      |> Enum.reject(&(&1 in [:bad_name, nil]))
      |> Enum.map(&Path.join(&1, name))
      |> Enum.uniq()

    Enum.reduce_while(candidates, {:error, :not_found}, fn candidate, _last ->
      case :erlang.load_nif(String.to_charlist(candidate), 0) do
        :ok -> {:halt, :ok}
        {:error, _reason} = error -> {:cont, error}
      end
    end)
  end

  def verify_der_signature(_pubkey, _message_hash, _signature), do: :erlang.nif_error(:nif_not_loaded)
  def verify_schnorr_signature(_pubkey_xonly, _message_hash, _signature), do: :erlang.nif_error(:nif_not_loaded)
  def taproot_tweak_xonly(_pubkey_xonly, _tweak), do: :erlang.nif_error(:nif_not_loaded)
end
