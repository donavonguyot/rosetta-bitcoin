defmodule Exbitnode.Chainstate.Tracker do
  @moduledoc false

  alias Exbitnode.{Messages.BlockHeaderCodec, Util.Hex}

  def bootstrap_start_height(store, chain) do
    case get_validated_height(store, chain) do
      height when height >= 0 -> height
      _ -> 0
    end
  end

  def get_validated_height(store, chain),
    do: store.__struct__.get_validated_tip(store, chain).height

  def get_validated_hash(store, chain),
    do: store.__struct__.get_validated_tip(store, chain).block_hash

  def get_sync_state(store, chain), do: store.__struct__.get_sync_state(store, chain)

  def ensure_genesis(store, chain, genesis, genesis_hash) do
    serialized = genesis |> BlockHeaderCodec.serialize() |> Hex.encode()
    _ = store.__struct__.insert_header(store, chain, 0, genesis_hash, "", serialized)

    if get_sync_state(store, chain) == nil do
      upsert_sync_state(store, chain, %{
        best_height: 0,
        best_hash: genesis_hash,
        header_count: 1,
        sync_status: "starting"
      })
    end

    if get_validated_height(store, chain) < 0 do
      set_validated_tip(store, chain, -1, "")
    end

    :ok
  end

  def repair_sync_state_from_headers(store, chain) do
    case latest_header(store, chain) do
      nil ->
        :ok

      %{height: height, block_hash: hash} ->
        existing = get_sync_state(store, chain)

        if existing == nil or height > existing.best_height do
          upsert_sync_state(store, chain, %{
            best_height: height,
            best_hash: hash,
            header_count: header_count(store, chain),
            sync_status: (existing && existing.sync_status) || "starting"
          })
        end

        :ok
    end
  end

  def upsert_sync_state(store, chain, patch),
    do: store.__struct__.upsert_sync_state(store, chain, patch)

  def get_header_hash(store, chain, height),
    do: store.__struct__.get_header_hash(store, chain, height)

  def header_count(store, chain \\ nil)
  def header_count(store, nil), do: header_count(store, "testnet4")
  def header_count(store, chain), do: store.__struct__.header_count(store, chain)
  def block_count(store, chain), do: store.__struct__.block_count(store, chain)
  def utxo_count(store, chain), do: store.__struct__.utxo_count(store, chain)

  def insert_header(store, chain, height, block_hash, prev_hash, serialized_hex) do
    store.__struct__.insert_header(store, chain, height, block_hash, prev_hash, serialized_hex)
  end

  def next_locator(store, chain, best_height, genesis_hash_internal) do
    cond do
      best_height <= 0 ->
        [genesis_hash_internal]

      true ->
        step = max(div(best_height, 10), 1)

        hashes =
          Stream.iterate(best_height, &(&1 - step))
          |> Enum.take_while(&(&1 >= 0))
          |> Enum.uniq()
          |> Enum.map(fn h ->
            case get_header_hash(store, chain, h) do
              nil -> nil
              hex -> Hex.reverse(Hex.decode(hex))
            end
          end)
          |> Enum.reject(&is_nil/1)

        case hashes do
          [] -> [genesis_hash_internal]
          list -> list
        end
    end
  end

  def log_event(store, category, message, severity \\ "info", details_json \\ nil) do
    store.__struct__.log_event(store, category, message, severity, details_json)
  end

  def latest_error(store), do: store.__struct__.latest_error(store)

  def record_peer_connected(
        store,
        host,
        port,
        direction,
        services,
        peer_version,
        user_agent,
        start_height
      ) do
    store.__struct__.record_peer_connected(
      store,
      host,
      port,
      direction,
      services,
      peer_version,
      user_agent,
      start_height
    )
  end

  def set_validated_tip(store, chain, height, block_hash) do
    store.__struct__.set_validated_tip(store, chain, height, block_hash)
  end

  def get_utxo(store, chain, txid, vout), do: store.__struct__.get_utxo(store, chain, txid, vout)
  def get_utxos(store, chain, outpoints), do: store.__struct__.get_utxos(store, chain, outpoints)
  def insert_utxo(store, chain, utxo), do: store.__struct__.insert_utxo(store, chain, utxo)

  def delete_utxo(store, chain, txid, vout),
    do: store.__struct__.delete_utxo(store, chain, txid, vout)

  def replace_utxo_undo(store, chain, height, entries),
    do: store.__struct__.replace_utxo_undo(store, chain, height, entries)

  def take_utxo_undo(store, chain, height),
    do: store.__struct__.take_utxo_undo(store, chain, height)

  def delete_utxos_created_at_height(store, chain, height),
    do: store.__struct__.delete_utxos_created_at_height(store, chain, height)

  def record_block(store, chain, height, block_hash, stored) do
    store.__struct__.record_block(store, chain, height, block_hash, stored)
  end

  def commit_block(store, chain, opts) do
    store.__struct__.commit_block(store, chain, opts)
  end

  def max_stored_block(store, chain), do: store.__struct__.max_stored_block(store, chain)
  def latest_blocker(store, chain), do: store.__struct__.latest_blocker(store, chain)

  def record_blocker(store, chain, blocker),
    do: store.__struct__.record_blocker(store, chain, blocker)

  def utxo_snapshot(store, chain), do: store.__struct__.utxo_snapshot(store, chain)

  defp latest_header(store, chain) do
    count = header_count(store, chain)

    0..max(count + 16, 16)
    |> Enum.map(fn height -> store.__struct__.get_header(store, chain, height) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(& &1.height, fn -> nil end)
  end
end
