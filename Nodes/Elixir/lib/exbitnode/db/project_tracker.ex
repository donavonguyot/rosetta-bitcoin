defmodule Exbitnode.Db.ProjectTracker do
  @moduledoc false

  alias Exbitnode.{Db.Schema, Db.Sql, Messages.BlockHeaderCodec, Util.Hex}

  def bootstrap_start_height(conn, chain) do
    case get_validated_height(conn, chain) do
      height when height >= 0 -> height
      _ -> 0
    end
  end

  def get_validated_height(conn, chain) do
    case Sql.query_one(conn, "SELECT height FROM validated_tip WHERE chain = ?1", [chain]) do
      [height] -> height
      _ -> -1
    end
  end

  def get_sync_state(conn, chain) do
    case Sql.query_one(
           conn,
           "SELECT best_height, best_hash, header_count, sync_status FROM sync_state WHERE chain = ?1",
           [chain]
         ) do
      [height, hash, header_count, status] ->
        %{best_height: height, best_hash: hash, header_count: header_count, sync_status: status}

      _ ->
        nil
    end
  end

  def ensure_genesis(conn, chain, genesis, genesis_hash) do
    serialized = genesis |> BlockHeaderCodec.serialize() |> Hex.encode()

    Sql.exec!(
      conn,
      """
      INSERT INTO headers(chain, height, block_hash, prev_hash, header_serialized_hex)
      VALUES(?1, 0, ?2, '', ?3)
      ON CONFLICT(chain, height) DO NOTHING
      """,
      [chain, genesis_hash, serialized]
    )

    case get_sync_state(conn, chain) do
      nil ->
        upsert_sync_state(conn, chain, %{
          best_height: 0,
          best_hash: genesis_hash,
          header_count: 1,
          sync_status: "starting"
        })

      _ ->
        :ok
    end

    if get_validated_height(conn, chain) < 0 do
      set_validated_tip(conn, chain, -1, "")
    end

    :ok
  end

  def repair_sync_state_from_headers(conn, chain) do
    case Sql.query_one(
           conn,
           "SELECT height, block_hash FROM headers WHERE chain = ?1 ORDER BY height DESC LIMIT 1",
           [chain]
         ) do
      [height, hash] ->
        existing = get_sync_state(conn, chain)

        if existing == nil or height > existing.best_height do
          upsert_sync_state(conn, chain, %{
            best_height: height,
            best_hash: hash,
            header_count: header_count(conn),
            sync_status: existing && existing.sync_status || "starting"
          })
        end

        :ok

      _ ->
        :ok
    end
  end

  def upsert_sync_state(conn, chain, patch) do
    existing = get_sync_state(conn, chain)

    height = Map.get(patch, :best_height, existing && existing.best_height) || 0
    hash = Map.get(patch, :best_hash, existing && existing.best_hash) || ""
    header_count = Map.get(patch, :header_count, existing && existing.header_count) || 0
    status = Map.get(patch, :sync_status, existing && existing.sync_status) || "starting"
    now = Schema.utc_now_iso()

    Sql.exec!(
      conn,
      """
      INSERT INTO sync_state(chain, best_height, best_hash, header_count, sync_status, updated_at)
      VALUES(?1, ?2, ?3, ?4, ?5, ?6)
      ON CONFLICT(chain) DO UPDATE SET
        best_height = excluded.best_height,
        best_hash = excluded.best_hash,
        header_count = excluded.header_count,
        sync_status = excluded.sync_status,
        updated_at = excluded.updated_at
      """,
      [chain, height, hash, header_count, status, now]
    )

    :ok
  end

  def get_header_hash(conn, chain, height) do
    case Sql.query_one(conn, "SELECT block_hash FROM headers WHERE chain = ?1 AND height = ?2", [chain, height]) do
      [hash] -> hash
      _ -> nil
    end
  end

  def header_count(conn) do
    case Sql.query_one(conn, "SELECT COUNT(*) FROM headers", []) do
      [count] -> count
      _ -> 0
    end
  end

  def block_count(conn, chain) do
    case Sql.query_one(conn, "SELECT COUNT(*) FROM blocks WHERE chain = ?1", [chain]) do
      [count] -> count
      _ -> 0
    end
  end

  def utxo_count(conn, chain) do
    case Sql.query_one(conn, "SELECT COUNT(*) FROM utxos WHERE chain = ?1", [chain]) do
      [count] -> count
      _ -> 0
    end
  end

  def insert_header(conn, chain, height, block_hash, prev_hash, serialized_hex) do
    changes =
      Sql.exec!(
        conn,
        """
        INSERT INTO headers(chain, height, block_hash, prev_hash, header_serialized_hex)
        VALUES(?1, ?2, ?3, ?4, ?5)
        ON CONFLICT(chain, height) DO NOTHING
        """,
        [chain, height, block_hash, prev_hash, serialized_hex]
      )

    if changes == 1, do: :inserted, else: :exists
  end

  def next_locator(conn, chain, best_height, genesis_hash_internal) do
    cond do
      best_height <= 0 ->
        [genesis_hash_internal]

      true ->
        step = max(div(best_height, 10), 1)

        heights =
          Stream.iterate(best_height, &(&1 - step))
          |> Enum.take_while(&(&1 >= 0))
          |> Enum.uniq()

        hashes =
          Enum.map(heights, fn h ->
            case get_header_hash(conn, chain, h) do
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

  def log_event(conn, category, message, severity \\ "info", details_json \\ nil) do
    Sql.exec!(
      conn,
      "INSERT INTO events(category, message, severity, details_json, created_at) VALUES(?1, ?2, ?3, ?4, ?5)",
      [category, message, severity, details_json, Schema.utc_now_iso()]
    )

    :ok
  end

  def record_peer_connected(conn, host, port, direction, services, peer_version, user_agent, start_height) do
    Sql.exec!(
      conn,
      """
      INSERT INTO peers(host, port, connected_at, direction, services, peer_version, user_agent, start_height)
      VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
      """,
      [host, port, Schema.utc_now_iso(), direction, services, peer_version, user_agent, start_height]
    )

    :ok
  end

  def set_validated_tip(conn, chain, height, block_hash) do
    Sql.exec!(
      conn,
      """
      INSERT INTO validated_tip(chain, height, block_hash, updated_at)
      VALUES(?1, ?2, ?3, ?4)
      ON CONFLICT(chain) DO UPDATE SET
        height = excluded.height,
        block_hash = excluded.block_hash,
        updated_at = excluded.updated_at
      """,
      [chain, height, block_hash, Schema.utc_now_iso()]
    )

    :ok
  end

  def get_utxo(conn, chain, txid, vout) do
    case Sql.query_one(
           conn,
           """
           SELECT txid, vout, height, value_sats, script_pubkey_hex, coinbase
           FROM utxos WHERE chain = ?1 AND txid = ?2 AND vout = ?3
           """,
           [chain, txid, vout]
         ) do
      [txid, vout, height, value_sats, script_hex, coinbase] ->
        %{
          txid: txid,
          vout: vout,
          height: height,
          value_sats: value_sats,
          script_pubkey_hex: script_hex,
          coinbase: coinbase != 0
        }

      _ ->
        nil
    end
  end

  def insert_utxo(conn, chain, utxo) do
    Sql.exec!(
      conn,
      """
      INSERT INTO utxos(chain, txid, vout, height, value_sats, script_pubkey_hex, coinbase)
      VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
      """,
      [
        chain,
        utxo.txid,
        utxo.vout,
        utxo.height,
        utxo.value_sats,
        utxo.script_pubkey_hex,
        if(utxo.coinbase, do: 1, else: 0)
      ]
    )

    :ok
  end

  def delete_utxo(conn, chain, txid, vout) do
    Sql.exec!(
      conn,
      "DELETE FROM utxos WHERE chain = ?1 AND txid = ?2 AND vout = ?3",
      [chain, txid, vout]
    )

    :ok
  end

  def replace_utxo_undo(conn, chain, height, entries) when is_list(entries) do
    Sql.exec!(conn, "DELETE FROM utxo_undo WHERE chain = ?1 AND height = ?2", [chain, height])

    Enum.each(entries, fn entry ->
      Sql.exec!(
        conn,
        """
        INSERT INTO utxo_undo(chain, height, txid, vout, value_sats, script_pubkey_hex, utxo_height, coinbase)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        """,
        [
          chain,
          height,
          entry.txid,
          entry.vout,
          entry.value_sats,
          entry.script_pubkey_hex,
          Map.get(entry, :utxo_height, Map.get(entry, :height, 0)),
          if(entry.coinbase, do: 1, else: 0)
        ]
      )
    end)

    :ok
  end

  def take_utxo_undo(conn, chain, height) do
    rows =
      Sql.query_all(
        conn,
        """
        SELECT txid, vout, value_sats, script_pubkey_hex, utxo_height, coinbase
        FROM utxo_undo WHERE chain = ?1 AND height = ?2
        """,
        [chain, height]
      )

    Sql.exec!(conn, "DELETE FROM utxo_undo WHERE chain = ?1 AND height = ?2", [chain, height])

    Enum.map(rows, fn [txid, vout, value_sats, script_hex, utxo_height, coinbase] ->
      %{
        txid: txid,
        vout: vout,
        utxo_height: utxo_height,
        value_sats: value_sats,
        script_pubkey_hex: script_hex,
        coinbase: coinbase != 0
      }
    end)
  end

  def delete_utxos_created_at_height(conn, chain, height) do
    Sql.exec!(conn, "DELETE FROM utxos WHERE chain = ?1 AND height = ?2", [chain, height])
    :ok
  end

  def record_block(conn, chain, height, block_hash, stored) do
    Sql.exec!(
      conn,
      """
      INSERT INTO blocks(chain, height, block_hash, file_number, file_offset, block_size)
      VALUES(?1, ?2, ?3, ?4, ?5, ?6)
      ON CONFLICT(chain, height) DO UPDATE SET
        block_hash = excluded.block_hash,
        file_number = excluded.file_number,
        file_offset = excluded.file_offset,
        block_size = excluded.block_size
      """,
      [chain, height, block_hash, stored.file_number, stored.file_offset, stored.block_size]
    )

    :ok
  end

  def record_blocker(conn, chain, blocker) do
    Sql.exec!(
      conn,
      """
      INSERT INTO blockers(chain, height, block_hash, txid, input_index, spent_script_pubkey_hex,
        failure, missing_rule, created_at)
      VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
      """,
      [
        chain,
        blocker.height,
        blocker.block_hash_hex,
        blocker.txid_hex,
        blocker.input_index,
        blocker.spent_script_pubkey_hex,
        blocker.message,
        blocker.missing_rule,
        Schema.utc_now_iso()
      ]
    )

    :ok
  end
end
