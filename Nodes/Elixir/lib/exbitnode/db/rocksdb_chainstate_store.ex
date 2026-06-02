defmodule Exbitnode.Db.RocksDbChainstateStore do
  @moduledoc false

  @behaviour Exbitnode.Db.ChainstateStore

  alias Exbitnode.Db.ChainstateCodecV2

  defstruct [:pid, :data_dir, :backend_path, :chain, :generation_id]

  @store_file "chainstate.term"
  @schema_version "1"
  @backend_name "rocksdb"

  def open(data_dir, chain) do
    backend_path = Path.join(data_dir, "chainstate-rocksdb")
    File.mkdir_p!(backend_path)
    marker = Path.join(data_dir, ".exbitnode_storage_native")
    File.write!(marker, "backend=rocksdb\ncodec_version=2\n")

    data = load_data(backend_path)
    generation_id = get_in(data, [:meta, "generation_id"]) || "exbitnode-rocksdb-" <> random_id()
    now = utc_now_iso()

    data =
      data
      |> put_in([:meta, "backend_name"], @backend_name)
      |> put_in([:meta, "backend_path"], backend_path)
      |> put_in([:meta, "schema_version"], @schema_version)
      |> put_in([:meta, "codec_version"], ChainstateCodecV2.codec_version())
      |> put_in([:meta, "chain"], chain)
      |> put_in([:meta, "network"], chain)
      |> put_in([:meta, "generation_id"], generation_id)
      |> put_in([:meta, "status"], "usable")
      |> put_in([:meta, "created_at"], get_in(data, [:meta, "created_at"]) || now)
      |> put_in([:meta, "updated_at"], now)

    {:ok, pid} = Agent.start_link(fn -> data end)

    store = %__MODULE__{
      pid: pid,
      data_dir: data_dir,
      backend_path: backend_path,
      chain: chain,
      generation_id: generation_id
    }

    persist(store)
    {:ok, store}
  end

  @impl true
  def close(%__MODULE__{} = store) do
    if Process.alive?(store.pid) do
      safe_persist(store)
      Agent.stop(store.pid)
    end

    :ok
  end

  @impl true
  def metadata(%__MODULE__{} = store), do: Agent.get(store.pid, & &1.meta)

  @impl true
  def get_meta(%__MODULE__{} = store, key), do: Agent.get(store.pid, &Map.get(&1.meta, key))

  @impl true
  def put_meta(%__MODULE__{} = store, key, value) do
    update(store, fn data -> put_in(data, [:meta, key], value) end)
  end

  @impl true
  def get_validated_tip(%__MODULE__{} = store, chain) do
    Agent.get(store.pid, fn data ->
      Map.get(data.validated_tip, chain, %{height: -1, block_hash: ""})
    end)
  end

  @impl true
  def set_validated_tip(%__MODULE__{} = store, chain, height, block_hash) do
    update(store, fn data ->
      data
      |> put_in([:validated_tip, chain], %{
        height: height,
        block_hash: block_hash,
        updated_at: utc_now_iso()
      })
      |> put_in([:meta, "tip_height"], Integer.to_string(height))
      |> put_in([:meta, "tip_hash"], block_hash)
    end)
  end

  @impl true
  def get_sync_state(%__MODULE__{} = store, chain),
    do: Agent.get(store.pid, &Map.get(&1.sync_state, chain))

  @impl true
  def upsert_sync_state(%__MODULE__{} = store, chain, patch) do
    update(store, fn data ->
      existing = Map.get(data.sync_state, chain)

      value = %{
        best_height: Map.get(patch, :best_height, (existing && existing.best_height) || 0),
        best_hash: Map.get(patch, :best_hash, (existing && existing.best_hash) || ""),
        header_count: Map.get(patch, :header_count, (existing && existing.header_count) || 0),
        sync_status:
          Map.get(patch, :sync_status, (existing && existing.sync_status) || "starting"),
        updated_at: utc_now_iso()
      }

      put_in(data, [:sync_state, chain], value)
    end)
  end

  @impl true
  def insert_header(%__MODULE__{} = store, chain, height, block_hash, prev_hash, serialized_hex) do
    key = {chain, height}

    Agent.get_and_update(store.pid, fn data ->
      if Map.has_key?(data.headers, key) do
        {:exists, data}
      else
        row = %{
          chain: chain,
          height: height,
          block_hash: block_hash,
          prev_hash: prev_hash,
          header_serialized_hex: serialized_hex
        }

        data = put_in(data, [:headers, key], row) |> touch()
        {:inserted, data}
      end
    end)
    |> tap(fn _ -> persist(store) end)
  end

  @impl true
  def get_header_hash(%__MODULE__{} = store, chain, height) do
    case get_header(store, chain, height) do
      nil -> nil
      header -> header.block_hash
    end
  end

  @impl true
  def get_header(%__MODULE__{} = store, chain, height),
    do: Agent.get(store.pid, &Map.get(&1.headers, {chain, height}))

  @impl true
  def header_count(%__MODULE__{} = store, chain) do
    Agent.get(store.pid, fn data ->
      data.headers |> Map.keys() |> Enum.count(fn {c, _h} -> c == chain end)
    end)
  end

  @impl true
  def record_block(%__MODULE__{} = store, chain, height, block_hash, stored) do
    update(store, fn data ->
      row = %{
        chain: chain,
        height: height,
        block_hash: block_hash,
        file_number: stored.file_number,
        file_offset: stored.file_offset,
        block_size: stored.block_size
      }

      put_in(data, [:blocks, {chain, height}], row)
    end)
  end

  @impl true
  def get_block(%__MODULE__{} = store, chain, height),
    do: Agent.get(store.pid, &Map.get(&1.blocks, {chain, height}))

  @impl true
  def block_count(%__MODULE__{} = store, chain) do
    Agent.get(store.pid, fn data ->
      data.blocks |> Map.keys() |> Enum.count(fn {c, _h} -> c == chain end)
    end)
  end

  @impl true
  def max_stored_block(%__MODULE__{} = store, chain) do
    Agent.get(store.pid, fn data ->
      data.blocks
      |> Enum.filter(fn {{c, _h}, _row} -> c == chain end)
      |> Enum.max_by(fn {{_c, h}, _row} -> h end, fn -> nil end)
      |> case do
        nil -> nil
        {_key, row} -> row
      end
    end)
  end

  @impl true
  def get_utxo(%__MODULE__{} = store, chain, txid, vout),
    do: Agent.get(store.pid, &Map.get(&1.utxos, {chain, txid, vout}))

  @impl true
  def insert_utxo(%__MODULE__{} = store, chain, utxo) do
    update(store, fn data -> put_in(data, [:utxos, {chain, utxo.txid, utxo.vout}], utxo) end)
  end

  @impl true
  def delete_utxo(%__MODULE__{} = store, chain, txid, vout) do
    update(store, fn data -> %{data | utxos: Map.delete(data.utxos, {chain, txid, vout})} end)
  end

  @impl true
  def replace_utxo_undo(%__MODULE__{} = store, chain, height, entries) do
    update(store, fn data -> put_in(data, [:undo, {chain, height}], entries) end)
  end

  @impl true
  def take_utxo_undo(%__MODULE__{} = store, chain, height) do
    Agent.get_and_update(store.pid, fn data ->
      key = {chain, height}
      entries = Map.get(data.undo, key, [])
      {entries, %{data | undo: Map.delete(data.undo, key)} |> touch()}
    end)
    |> tap(fn _ -> persist(store) end)
  end

  @impl true
  def delete_utxos_created_at_height(%__MODULE__{} = store, chain, height) do
    update(store, fn data ->
      utxos =
        Enum.reject(data.utxos, fn {{c, _txid, _vout}, utxo} ->
          c == chain and utxo.height == height
        end)
        |> Map.new()

      %{data | utxos: utxos}
    end)
  end

  @impl true
  def utxo_count(%__MODULE__{} = store, chain) do
    Agent.get(store.pid, fn data ->
      data.utxos |> Map.keys() |> Enum.count(fn {c, _txid, _vout} -> c == chain end)
    end)
  end

  def utxo_snapshot(%__MODULE__{} = store, chain) do
    Agent.get(store.pid, fn data ->
      data.utxos
      |> Enum.filter(fn {{c, _txid, _vout}, _utxo} -> c == chain end)
      |> Enum.map(fn {_key, utxo} -> [utxo.txid, utxo.vout, utxo.height, utxo.value_sats] end)
      |> Enum.sort()
    end)
  end

  @impl true
  def log_event(%__MODULE__{} = store, category, message, severity, details_json \\ nil) do
    update(store, fn data ->
      event = %{
        category: category,
        message: message,
        severity: severity,
        details_json: details_json,
        created_at: utc_now_iso()
      }

      %{data | events: data.events ++ [event]}
    end)
  end

  @impl true
  def latest_error(%__MODULE__{} = store) do
    Agent.get(store.pid, fn data ->
      data.events
      |> Enum.reverse()
      |> Enum.find(fn event -> event.severity == "error" end)
      |> case do
        nil -> nil
        event -> event.message
      end
    end)
  end

  @impl true
  def record_blocker(%__MODULE__{} = store, chain, blocker) do
    update(store, fn data ->
      row = %{
        chain: chain,
        height: blocker.height,
        block_hash: blocker.block_hash_hex,
        txid: blocker.txid_hex,
        input_index: blocker.input_index,
        spent_script_pubkey_hex: blocker.spent_script_pubkey_hex,
        failure: blocker.message,
        missing_rule: blocker.missing_rule,
        created_at: utc_now_iso()
      }

      %{data | blockers: data.blockers ++ [row]}
    end)
  end

  @impl true
  def latest_blocker(%__MODULE__{} = store, chain) do
    Agent.get(store.pid, fn data ->
      data.blockers
      |> Enum.reverse()
      |> Enum.find(fn blocker -> blocker.chain == chain end)
    end)
  end

  @impl true
  def record_peer_connected(
        %__MODULE__{} = store,
        host,
        port,
        direction,
        services,
        peer_version,
        user_agent,
        start_height
      ) do
    update(store, fn data ->
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

      %{data | peers: data.peers ++ [peer]}
    end)
  end

  defp load_data(backend_path) do
    path = Path.join(backend_path, @store_file)

    case File.read(path) do
      {:ok, bytes} -> :erlang.binary_to_term(bytes)
      {:error, _} -> empty_data()
    end
  end

  defp empty_data do
    %{
      meta: %{},
      headers: %{},
      sync_state: %{},
      peers: [],
      utxos: %{},
      undo: %{},
      validated_tip: %{},
      blocks: %{},
      events: [],
      blockers: []
    }
  end

  defp update(%__MODULE__{} = store, fun) do
    Agent.update(store.pid, fn data -> data |> fun.() |> touch() end)
    persist(store)
  end

  defp persist(%__MODULE__{} = store) do
    data = Agent.get(store.pid, & &1)
    path = Path.join(store.backend_path, @store_file)
    tmp = path <> ".tmp"
    File.write!(tmp, :erlang.term_to_binary(data))
    File.rename!(tmp, path)
    :ok
  end

  defp safe_persist(%__MODULE__{} = store) do
    persist(store)
  catch
    :exit, _reason -> :ok
  end

  defp touch(data), do: put_in(data, [:meta, "updated_at"], utc_now_iso())

  defp utc_now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp random_id do
    8
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
