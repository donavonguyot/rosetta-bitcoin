defmodule Exbitnode.Db.ChainstateStore do
  @moduledoc false

  @callback close(term()) :: :ok
  @callback metadata(term()) :: map()
  @callback get_meta(term(), String.t()) :: String.t() | nil
  @callback put_meta(term(), String.t(), String.t()) :: :ok
  @callback get_validated_tip(term(), String.t()) :: map()
  @callback set_validated_tip(term(), String.t(), integer(), String.t()) :: :ok
  @callback get_sync_state(term(), String.t()) :: map() | nil
  @callback upsert_sync_state(term(), String.t(), map()) :: :ok
  @callback insert_header(term(), String.t(), integer(), String.t(), String.t(), String.t()) ::
              :inserted | :exists | :updated
  @callback get_header_hash(term(), String.t(), integer()) :: String.t() | nil
  @callback get_header(term(), String.t(), integer()) :: map() | nil
  @callback header_count(term(), String.t()) :: integer()
  @callback record_block(term(), String.t(), integer(), String.t(), map()) :: :ok
  @callback commit_block(term(), String.t(), map()) :: :ok
  @callback get_block(term(), String.t(), integer()) :: map() | nil
  @callback block_count(term(), String.t()) :: integer()
  @callback max_stored_block(term(), String.t()) :: map() | nil
  @callback get_utxo(term(), String.t(), String.t(), integer()) :: map() | nil
  @callback get_utxos(term(), String.t(), list()) :: list(map() | nil)
  @callback insert_utxo(term(), String.t(), map()) :: :ok
  @callback delete_utxo(term(), String.t(), String.t(), integer()) :: :ok
  @callback replace_utxo_undo(term(), String.t(), integer(), list(map())) :: :ok
  @callback take_utxo_undo(term(), String.t(), integer()) :: list(map())
  @callback delete_utxos_created_at_height(term(), String.t(), integer()) :: :ok
  @callback utxo_count(term(), String.t()) :: integer()
  @callback log_event(term(), String.t(), String.t(), String.t(), String.t() | nil) :: :ok
  @callback latest_error(term()) :: String.t() | nil
  @callback record_blocker(term(), String.t(), Exception.t()) :: :ok
  @callback latest_blocker(term(), String.t()) :: map() | nil
  @callback record_peer_connected(
              term(),
              String.t(),
              integer(),
              String.t(),
              integer(),
              integer(),
              String.t(),
              integer()
            ) :: :ok
end
