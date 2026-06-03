defmodule Exbitnode.Db.ChainstateSession do
  @moduledoc false

  alias Exbitnode.Db.RocksDbChainstateStore

  @forbidden_local_db_artifact "exbitnode.db"

  def open_native(data_dir, chain) do
    File.mkdir_p!(data_dir)
    reject_forbidden_local_db_artifacts!(data_dir)
    RocksDbChainstateStore.open(data_dir, chain)
  end

  def close(store), do: store.__struct__.close(store)

  def metadata(store), do: store.__struct__.metadata(store)

  def backend_name(_store), do: "rocksdb"

  def backend_path(store), do: store.backend_path

  def generation_id(store), do: store.generation_id

  def reject_forbidden_local_db_artifacts!(data_dir) do
    case forbidden_local_db_artifacts(data_dir) do
      [] ->
        :ok

      paths ->
        raise ArgumentError,
              "native chainstate refuses local DB artifacts in #{data_dir}: #{Enum.join(paths, ", ")}"
    end
  end

  def forbidden_local_db_artifacts_absent?(data_dir) do
    reject_forbidden_local_db_artifacts!(data_dir)
    true
  rescue
    ArgumentError -> false
  end

  def forbidden_local_db_artifacts(data_dir) do
    [
      @forbidden_local_db_artifact,
      "#{@forbidden_local_db_artifact}-wal",
      "#{@forbidden_local_db_artifact}-shm",
      "*.db",
      "*.db-wal",
      "*.db-shm",
      "*.sqlite",
      "*.sqlite3"
    ]
    |> Enum.flat_map(fn pattern ->
      Path.wildcard(Path.join(data_dir, pattern))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
