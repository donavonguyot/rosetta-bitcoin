defmodule Exbitnode.Db.ChainstateSession do
  @moduledoc false

  alias Exbitnode.Db.RocksDbChainstateStore

  def open_native(data_dir, chain) do
    File.mkdir_p!(data_dir)
    RocksDbChainstateStore.open(data_dir, chain)
  end

  def close(store), do: store.__struct__.close(store)

  def metadata(store), do: store.__struct__.metadata(store)

  def backend_name(_store), do: "rocksdb"

  def backend_path(store), do: store.backend_path

  def generation_id(store), do: store.generation_id
end
