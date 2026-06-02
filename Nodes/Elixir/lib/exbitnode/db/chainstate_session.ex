defmodule Exbitnode.Db.ChainstateSession do
  @moduledoc false

  alias Exbitnode.Db.RocksDbChainstateStore

  @legacy_db "exbitnode.db"

  def open_native(data_dir, chain) do
    File.mkdir_p!(data_dir)
    reject_sqlite_artifacts!(data_dir)
    RocksDbChainstateStore.open(data_dir, chain)
  end

  def close(store), do: store.__struct__.close(store)

  def metadata(store), do: store.__struct__.metadata(store)

  def backend_name(_store), do: "rocksdb"

  def backend_path(store), do: store.backend_path

  def generation_id(store), do: store.generation_id

  def reject_sqlite_artifacts!(data_dir) do
    forbidden =
      [
        @legacy_db,
        "#{@legacy_db}-wal",
        "#{@legacy_db}-shm",
        "*.sqlite",
        "*.sqlite3",
        "*.db"
      ]
      |> Enum.flat_map(fn pattern ->
        Path.wildcard(Path.join(data_dir, pattern))
      end)
      |> Enum.uniq()

    case forbidden do
      [] ->
        :ok

      paths ->
        raise ArgumentError,
              "native chainstate refuses SQLite artifacts in #{data_dir}: #{Enum.join(paths, ", ")}"
    end
  end

  def sqlite_artifacts_absent?(data_dir) do
    reject_sqlite_artifacts!(data_dir)
    true
  rescue
    ArgumentError -> false
  end
end
