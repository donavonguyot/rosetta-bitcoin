defmodule Exbitnode.Db.RocksDbChainstateStore do
  @moduledoc false

  @behaviour Exbitnode.Db.ChainstateStore

  alias Exbitnode.Db.ChainstateCodecV2
  alias Exbitnode.Messages.BlockHeaderCodec
  alias Exbitnode.Native.RocksDb
  alias Exbitnode.Util.Hex

  defstruct [:db, :data_dir, :backend_path, :chain, :generation_id]

  @shim_file "chainstate.term"
  @schema_version "1"
  @backend_name "rocksdb"
  @backend_version "native-librocksdb"

  @metadata_keys [
    "backend_name",
    "backend_version",
    "backend_path",
    "schema_version",
    "codec_version",
    "chain",
    "network",
    "generation_id",
    "status",
    "created_at",
    "updated_at",
    "tip_height",
    "tip_hash",
    "block_count",
    "utxo_count",
    "stored_block_height",
    "stored_block_hash",
    "rocksdb_block_cache_bytes",
    "rocksdb_write_buffer_bytes",
    "rocksdb_max_write_buffers",
    "rocksdb_max_background_jobs",
    "rocksdb_disable_wal"
  ]

  def open(data_dir, chain) do
    backend_path = Path.join(data_dir, "chainstate-rocksdb")
    File.mkdir_p!(backend_path)
    reject_shim!(backend_path)
    marker = Path.join(backend_path, ".exbitnode_storage_native")
    File.write!(marker, "backend=rocksdb\ncodec_version=2\n")

    {:ok, db} = RocksDb.open(backend_path)
    now = utc_now_iso()

    store = %__MODULE__{
      db: db,
      data_dir: data_dir,
      backend_path: backend_path,
      chain: chain,
      generation_id: ""
    }

    generation_id = get_meta(store, "generation_id") || "exbitnode-rocksdb-" <> random_id()
    created_at = get_meta(store, "created_at") || now

    store = %{store | generation_id: generation_id}

    :ok =
      write_batch(store, [
        put_meta_op("backend_name", @backend_name),
        put_meta_op("backend_version", @backend_version),
        put_meta_op("backend_path", backend_path),
        put_meta_op("schema_version", @schema_version),
        put_meta_op("codec_version", ChainstateCodecV2.codec_version()),
        put_meta_op("chain", chain),
        put_meta_op("network", chain),
        put_meta_op("generation_id", generation_id),
        put_meta_op("status", "usable"),
        put_meta_op("rocksdb_block_cache_bytes", env_value("ROCKSDB_BLOCK_CACHE_BYTES", "134217728")),
        put_meta_op("rocksdb_write_buffer_bytes", env_value("ROCKSDB_WRITE_BUFFER_BYTES", "134217728")),
        put_meta_op("rocksdb_max_write_buffers", env_value("ROCKSDB_MAX_WRITE_BUFFERS", "4")),
        put_meta_op("rocksdb_max_background_jobs", env_value("ROCKSDB_MAX_BACKGROUND_JOBS", "4")),
        put_meta_op("rocksdb_disable_wal", if(env_flag?("ROCKSDB_DISABLE_WAL"), do: "true", else: "false")),
        put_meta_op("created_at", created_at),
        put_meta_op("updated_at", now)
      ])

    backfill_operational_metadata(store, chain)

    {:ok, store}
  end

  @impl true
  def close(%__MODULE__{} = store), do: RocksDb.close(store.db)

  @impl true
  def metadata(%__MODULE__{} = store) do
    @metadata_keys
    |> Enum.map(fn key -> {key, get_meta(store, key)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @impl true
  def get_meta(%__MODULE__{} = store, key) do
    case RocksDb.get(store.db, ChainstateCodecV2.metadata_key(key)) do
      {:ok, value} -> value
      :nil -> nil
      {:error, reason} -> raise "rocksdb metadata read failed: #{reason}"
    end
  end

  @impl true
  def put_meta(%__MODULE__{} = store, key, value) do
    write_batch(store, [put_meta_op(key, value), put_meta_op("updated_at", utc_now_iso())])
  end

  @impl true
  def get_validated_tip(%__MODULE__{} = store, chain) do
    case RocksDb.get(store.db, ChainstateCodecV2.tip_key(chain)) do
      {:ok, value} -> ChainstateCodecV2.decode_tip(value)
      :nil -> %{height: -1, block_hash: ""}
      {:error, reason} -> raise "rocksdb tip read failed: #{reason}"
    end
  end

  @impl true
  def set_validated_tip(%__MODULE__{} = store, chain, height, block_hash) do
    ops =
      if height < 0 do
        [
          {:delete, ChainstateCodecV2.tip_key(chain)},
          put_meta_op("tip_height", Integer.to_string(height)),
          put_meta_op("tip_hash", block_hash)
        ]
      else
        [
          {:put, ChainstateCodecV2.tip_key(chain), ChainstateCodecV2.encode_tip(height, block_hash)},
          put_meta_op("tip_height", Integer.to_string(height)),
          put_meta_op("tip_hash", block_hash)
        ]
      end

    write_batch(store, touch_ops(ops))
  end

  @impl true
  def get_sync_state(%__MODULE__{} = store, chain) do
    case RocksDb.get(store.db, ChainstateCodecV2.sync_state_key(chain)) do
      {:ok, value} -> decode_json_atom_map(value)
      :nil -> nil
      {:error, reason} -> raise "rocksdb sync_state read failed: #{reason}"
    end
  end

  @impl true
  def upsert_sync_state(%__MODULE__{} = store, chain, patch) do
    existing = get_sync_state(store, chain)

    value = %{
      best_height: Map.get(patch, :best_height, (existing && existing.best_height) || 0),
      best_hash: Map.get(patch, :best_hash, (existing && existing.best_hash) || ""),
      header_count: Map.get(patch, :header_count, (existing && existing.header_count) || 0),
      sync_status: Map.get(patch, :sync_status, (existing && existing.sync_status) || "starting"),
      updated_at: utc_now_iso()
    }

    write_batch(store, touch_ops([{:put, ChainstateCodecV2.sync_state_key(chain), Jason.encode!(value)}]))
  end

  @impl true
  def insert_header(%__MODULE__{} = store, chain, height, _block_hash, _prev_hash, serialized_hex) do
    key = ChainstateCodecV2.header_key(chain, height)

    case RocksDb.get(store.db, key) do
      {:ok, _} when serialized_hex == "" ->
        :exists

      {:ok, _} ->
        serialized = Hex.decode(serialized_hex)
        :ok = write_batch(store, touch_ops([{:put, key, ChainstateCodecV2.encode_header(serialized)}]))
        :updated

      :nil ->
        serialized = Hex.decode(serialized_hex)

        :ok =
          write_batch(store, touch_ops([
            {:put, key, ChainstateCodecV2.encode_header(serialized)}
          ]))

        :inserted

      {:error, reason} ->
        raise "rocksdb header read failed: #{reason}"
    end
  end

  @impl true
  def get_header_hash(%__MODULE__{} = store, chain, height) do
    case get_header(store, chain, height) do
      nil -> nil
      header -> header.block_hash
    end
  end

  @impl true
  def get_header(%__MODULE__{} = store, chain, height) do
    case RocksDb.get(store.db, ChainstateCodecV2.header_key(chain, height)) do
      {:ok, value} ->
        serialized = ChainstateCodecV2.decode_header(value)
        {header, _} = BlockHeaderCodec.deserialize(serialized)

        %{
          chain: chain,
          height: height,
          block_hash: BlockHeaderCodec.block_hash_hex(header),
          prev_hash: header.prev_block |> Hex.reverse() |> Hex.encode(),
          header_serialized_hex: Hex.encode(serialized)
        }

      :nil ->
        nil

      {:error, reason} ->
        raise "rocksdb header read failed: #{reason}"
    end
  end

  @impl true
  def header_count(%__MODULE__{} = store, chain), do: count_prefix(store, ChainstateCodecV2.header_prefix(chain))

  @impl true
  def record_block(%__MODULE__{} = store, chain, height, block_hash, stored) do
    value =
      ChainstateCodecV2.encode_block_index(%{
        block_hash: block_hash,
        file_number: stored.file_number,
        file_offset: stored.file_offset,
        block_size: stored.block_size
      })

    ops =
      [
        {:put, ChainstateCodecV2.block_index_key(chain, height), value},
        put_meta_op("block_count", Integer.to_string(max(meta_int(store, "block_count", 0), height + 1))),
        put_meta_op("stored_block_height", Integer.to_string(max(meta_int(store, "stored_block_height", -1), height))),
        put_meta_op("stored_block_hash", block_hash)
      ]

    write_batch(store, touch_ops(ops))
  end

  @impl true
  def get_block(%__MODULE__{} = store, chain, height) do
    case RocksDb.get(store.db, ChainstateCodecV2.block_index_key(chain, height)) do
      {:ok, value} -> ChainstateCodecV2.decode_block_index(chain, height, value)
      :nil -> nil
      {:error, reason} -> raise "rocksdb block index read failed: #{reason}"
    end
  end

  @impl true
  def block_count(%__MODULE__{} = store, chain) do
    case get_meta(store, "block_count") do
      nil ->
        count = count_prefix(store, ChainstateCodecV2.block_index_prefix(chain))
        :ok = put_meta(store, "block_count", Integer.to_string(count))
        count

      value ->
        parse_int(value, 0)
    end
  end

  @impl true
  def max_stored_block(%__MODULE__{} = store, chain) do
    case meta_int(store, "stored_block_height", -1) do
      height when height >= 0 ->
        get_block(store, chain, height) ||
          %{
            chain: chain,
            height: height,
            block_hash: get_meta(store, "stored_block_hash") || "",
            file_number: 0,
            file_offset: 0,
            block_size: 0
          }

      _ ->
        max_stored_block_by_scan(store, chain)
    end
  end

  @impl true
  def get_utxo(%__MODULE__{} = store, chain, txid, vout) do
    key = ChainstateCodecV2.utxo_key(chain, txid |> Hex.decode() |> Hex.reverse(), vout)

    case RocksDb.get(store.db, key) do
      {:ok, value} -> ChainstateCodecV2.decode_utxo(txid, vout, value)
      :nil -> nil
      {:error, reason} -> raise "rocksdb utxo read failed: #{reason}"
    end
  end

  @impl true
  def get_utxos(%__MODULE__{} = store, chain, outpoints) do
    normalized = Enum.map(outpoints, &normalize_outpoint!/1)

    keys =
      Enum.map(normalized, fn {txid, vout} ->
        ChainstateCodecV2.utxo_key(chain, txid |> Hex.decode() |> Hex.reverse(), vout)
      end)

    case RocksDb.multi_get(store.db, keys) do
      {:ok, values} ->
        normalized
        |> Enum.zip(values)
        |> Enum.map(fn
          {{txid, vout}, {:ok, value}} -> ChainstateCodecV2.decode_utxo(txid, vout, value)
          {_outpoint, :nil} -> nil
        end)

      {:error, reason} ->
        raise "rocksdb utxo multi_get failed: #{reason}"
    end
  end

  @impl true
  def insert_utxo(%__MODULE__{} = store, chain, utxo) do
    key = ChainstateCodecV2.utxo_key(chain, utxo.txid |> Hex.decode() |> Hex.reverse(), utxo.vout)
    value = ChainstateCodecV2.encode_utxo(utxo)
    write_batch(store, touch_ops([{:put, key, value}, adjust_counter_op(store, "utxo_count", 1)]))
  end

  @impl true
  def delete_utxo(%__MODULE__{} = store, chain, txid, vout) do
    key = ChainstateCodecV2.utxo_key(chain, txid |> Hex.decode() |> Hex.reverse(), vout)
    write_batch(store, touch_ops([{:delete, key}, adjust_counter_op(store, "utxo_count", -1)]))
  end

  @impl true
  def replace_utxo_undo(%__MODULE__{} = store, chain, height, entries) do
    write_batch(store, touch_ops([{:put, ChainstateCodecV2.undo_key(chain, height), ChainstateCodecV2.encode_undo(entries)}]))
  end

  @impl true
  def take_utxo_undo(%__MODULE__{} = store, chain, height) do
    key = ChainstateCodecV2.undo_key(chain, height)

    entries =
      case RocksDb.get(store.db, key) do
        {:ok, value} -> ChainstateCodecV2.decode_undo(value)
        :nil -> []
        {:error, reason} -> raise "rocksdb undo read failed: #{reason}"
      end

    :ok = write_batch(store, touch_ops([{:delete, key}]))
    entries
  end

  @impl true
  def delete_utxos_created_at_height(%__MODULE__{} = store, chain, height) do
    prefix = ChainstateCodecV2.utxo_prefix(chain)
    prefix_size = byte_size(prefix)

    ops =
      store
      |> scan(prefix)
      |> Enum.flat_map(fn {key, value} ->
        <<_prefix::binary-size(prefix_size), txid_internal::binary-size(32), vout::unsigned-big-32>> = key

        txid = txid_internal |> Hex.reverse() |> Hex.encode()
        utxo = ChainstateCodecV2.decode_utxo(txid, vout, value)
        if utxo.height == height, do: [{:delete, key}], else: []
      end)

    write_batch(store, touch_ops(ops ++ [adjust_counter_op(store, "utxo_count", -length(ops))]))
  end

  @impl true
  def utxo_count(%__MODULE__{} = store, chain) do
    case get_meta(store, "utxo_count") do
      nil ->
        count = count_prefix(store, ChainstateCodecV2.utxo_prefix(chain))
        :ok = put_meta(store, "utxo_count", Integer.to_string(count))
        count

      value ->
        parse_int(value, 0)
    end
  end

  def utxo_snapshot(%__MODULE__{} = store, chain) do
    prefix = ChainstateCodecV2.utxo_prefix(chain)

    store
    |> scan(prefix)
    |> Enum.map(fn {key, value} ->
      <<_prefix::binary-size(byte_size(prefix)), txid_internal::binary-size(32), vout::unsigned-big-32>> = key
      txid = txid_internal |> Hex.reverse() |> Hex.encode()
      utxo = ChainstateCodecV2.decode_utxo(txid, vout, value)
      [utxo.txid, utxo.vout, utxo.height, utxo.value_sats]
    end)
    |> Enum.sort()
  end

  @impl true
  def log_event(%__MODULE__{} = store, category, message, severity, details_json \\ nil) do
    event = %{
      category: category,
      message: message,
      severity: severity,
      details_json: details_json,
      created_at: utc_now_iso()
    }

    write_batch(store, touch_ops([{:put, ChainstateCodecV2.event_key(unique_id()), Jason.encode!(event)}]))
  end

  @impl true
  def latest_error(%__MODULE__{} = store) do
    store
    |> scan(ChainstateCodecV2.event_prefix())
    |> Enum.map(fn {key, value} -> {key, decode_json_atom_map(value)} end)
    |> Enum.sort_by(fn {key, _event} -> key end, :desc)
    |> Enum.find_value(fn {_key, event} -> if event.severity == "error", do: event.message, else: nil end)
  end

  @impl true
  def record_blocker(%__MODULE__{} = store, chain, blocker) do
    row = %{
      chain: chain,
      height: blocker.height,
      block_hash: blocker.block_hash_hex,
      txid: blocker.txid_hex,
      input_index: blocker.input_index,
      spent_script_pubkey_hex: blocker.spent_script_pubkey_hex,
      failure: blocker.message,
      missing_rule: blocker.missing_rule,
      source: "elixir-native",
      created_at: utc_now_iso()
    }

    write_batch(store, touch_ops([{:put, ChainstateCodecV2.blocker_key(chain), Jason.encode!(row)}]))
  end

  @impl true
  def latest_blocker(%__MODULE__{} = store, chain) do
    case RocksDb.get(store.db, ChainstateCodecV2.blocker_key(chain)) do
      {:ok, value} -> decode_json_atom_map(value)
      :nil -> nil
      {:error, reason} -> raise "rocksdb blocker read failed: #{reason}"
    end
  end

  @impl true
  def record_peer_connected(%__MODULE__{} = store, host, port, direction, services, peer_version, user_agent, start_height) do
    peer = %{
      host: host,
      port: port,
      connected_at: utc_now_iso(),
      direction: direction,
      services: services,
      peer_version: peer_version,
      user_agent: user_agent,
      start_height: start_height
    }

    write_batch(store, touch_ops([{:put, ChainstateCodecV2.peer_key(unique_id()), Jason.encode!(peer)}]))
  end

  @impl true
  def commit_block(%__MODULE__{} = store, chain, opts) do
    block_hash = Map.fetch!(opts, :block_hash)
    height = Map.fetch!(opts, :height)
    stored = Map.fetch!(opts, :stored)
    created = Map.get(opts, :created, [])
    spent = Map.get(opts, :spent, [])
    undo = Map.get(opts, :undo, [])
    header_serialized_hex = Map.get(opts, :header_serialized_hex)

    block_value =
      ChainstateCodecV2.encode_block_index(%{
        block_hash: block_hash,
        file_number: stored.file_number,
        file_offset: stored.file_offset,
        block_size: stored.block_size
      })

    base_ops =
      [
        {:put, ChainstateCodecV2.block_index_key(chain, height), block_value},
        {:put, ChainstateCodecV2.undo_key(chain, height), ChainstateCodecV2.encode_undo(undo)},
        {:put, ChainstateCodecV2.tip_key(chain), ChainstateCodecV2.encode_tip(height, block_hash)},
        put_meta_op("block_count", Integer.to_string(max(meta_int(store, "block_count", 0), height + 1))),
        put_meta_op("stored_block_height", Integer.to_string(max(meta_int(store, "stored_block_height", -1), height))),
        put_meta_op("stored_block_hash", block_hash),
        put_meta_op("utxo_count", Integer.to_string(max(meta_int(store, "utxo_count", 0) + length(created) - length(spent), 0))),
        put_meta_op("tip_height", Integer.to_string(height)),
        put_meta_op("tip_hash", block_hash)
      ]

    header_ops =
      if is_binary(header_serialized_hex) and header_serialized_hex != "" do
        [{:put, ChainstateCodecV2.header_key(chain, height), ChainstateCodecV2.encode_header(Hex.decode(header_serialized_hex))}]
      else
        []
      end

    ops =
      base_ops ++
        header_ops ++
        Enum.map(spent, fn {txid, vout} ->
          {:delete, ChainstateCodecV2.utxo_key(chain, txid |> Hex.decode() |> Hex.reverse(), vout)}
        end) ++
        Enum.map(created, fn utxo ->
          {:put, ChainstateCodecV2.utxo_key(chain, utxo.txid |> Hex.decode() |> Hex.reverse(), utxo.vout),
           ChainstateCodecV2.encode_utxo(utxo)}
        end)

    write_batch(store, touch_ops(ops))
  end

  defp reject_shim!(backend_path) do
    shim = Path.join(backend_path, @shim_file)

    if File.exists?(shim) do
      raise ArgumentError, "native RocksDB chainstate refuses legacy shim file #{shim}"
    end
  end

  defp write_batch(%__MODULE__{} = store, ops), do: RocksDb.write_batch(store.db, ops)

  defp put_meta_op(key, value), do: {:put, ChainstateCodecV2.metadata_key(key), to_string(value)}
  defp touch_ops(ops), do: ops ++ [put_meta_op("updated_at", utc_now_iso())]
  defp adjust_counter_op(store, key, delta), do: put_meta_op(key, Integer.to_string(max(meta_int(store, key, 0) + delta, 0)))

  defp backfill_operational_metadata(store, chain) do
    ops =
      []
      |> maybe_backfill("block_count", fn -> Integer.to_string(count_prefix(store, ChainstateCodecV2.block_index_prefix(chain))) end, store)
      |> maybe_backfill("utxo_count", fn -> Integer.to_string(count_prefix(store, ChainstateCodecV2.utxo_prefix(chain))) end, store)
      |> maybe_backfill("stored_block_height", fn ->
        case max_stored_block_by_scan(store, chain) do
          nil -> "-1"
          block -> Integer.to_string(block.height)
        end
      end, store)
      |> maybe_backfill("stored_block_hash", fn ->
        case max_stored_block_by_scan(store, chain) do
          nil -> ""
          block -> block.block_hash
        end
      end, store)

    if ops == [], do: :ok, else: write_batch(store, touch_ops(ops))
  end

  defp maybe_backfill(ops, key, value_fun, store) do
    if get_meta(store, key) == nil do
      [put_meta_op(key, value_fun.()) | ops]
    else
      ops
    end
  end

  defp count_prefix(store, prefix), do: store |> scan(prefix) |> length()

  defp max_stored_block_by_scan(store, chain) do
    prefix = ChainstateCodecV2.block_index_prefix(chain)

    store
    |> scan(prefix)
    |> Enum.map(fn {key, value} ->
      height = height_from_prefixed_key(key, prefix)
      ChainstateCodecV2.decode_block_index(chain, height, value)
    end)
    |> Enum.max_by(& &1.height, fn -> nil end)
  end

  defp scan(%__MODULE__{} = store, prefix) do
    case RocksDb.prefix_scan(store.db, prefix) do
      {:ok, rows} -> Enum.sort_by(rows, fn {key, _value} -> key end)
      {:error, reason} -> raise "rocksdb prefix scan failed: #{reason}"
    end
  end

  defp height_from_prefixed_key(key, prefix) do
    <<_prefix::binary-size(byte_size(prefix)), height::unsigned-big-32>> = key
    height
  end

  defp decode_json_atom_map(value), do: Jason.decode!(value, keys: :atoms)

  defp normalize_outpoint!(%{txid: txid, vout: vout}), do: {txid, vout}
  defp normalize_outpoint!({txid, vout}), do: {txid, vout}

  defp meta_int(store, key, default), do: get_meta(store, key) |> parse_int(default)

  defp parse_int(nil, default), do: default
  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp env_value(name, default), do: System.get_env(name) || default
  defp env_flag?(name), do: (System.get_env(name) || "") in ["1", "true", "TRUE", "yes", "YES"]

  defp unique_id, do: System.system_time(:microsecond) + :erlang.unique_integer([:positive])

  defp utc_now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp random_id do
    8
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
