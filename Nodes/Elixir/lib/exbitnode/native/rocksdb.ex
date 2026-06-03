defmodule :exbitnode_native_rocksdb do
  @moduledoc false

  @on_load :load_nif

  def load_nif do
    load_from_candidates("exbitnode_native_rocksdb")
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

  def open(_path), do: :erlang.nif_error(:nif_not_loaded)
  def close(_db), do: :erlang.nif_error(:nif_not_loaded)
  def get(_db, _key), do: :erlang.nif_error(:nif_not_loaded)
  def put(_db, _key, _value), do: :erlang.nif_error(:nif_not_loaded)
  def delete(_db, _key), do: :erlang.nif_error(:nif_not_loaded)
  def write_batch(_db, _ops), do: :erlang.nif_error(:nif_not_loaded)
  def multi_get(_db, _keys), do: :erlang.nif_error(:nif_not_loaded)
  def prefix_scan(_db, _prefix), do: :erlang.nif_error(:nif_not_loaded)
end

defmodule Exbitnode.Native.RocksDb do
  @moduledoc false

  def open(path) when is_binary(path), do: :exbitnode_native_rocksdb.open(path)
  def close(db), do: :exbitnode_native_rocksdb.close(db)
  def get(db, key) when is_binary(key), do: :exbitnode_native_rocksdb.get(db, key)
  def put(db, key, value) when is_binary(key) and is_binary(value), do: :exbitnode_native_rocksdb.put(db, key, value)
  def delete(db, key) when is_binary(key), do: :exbitnode_native_rocksdb.delete(db, key)
  def write_batch(db, ops) when is_list(ops), do: :exbitnode_native_rocksdb.write_batch(db, ops)
  def multi_get(db, keys) when is_list(keys), do: :exbitnode_native_rocksdb.multi_get(db, keys)
  def prefix_scan(db, prefix) when is_binary(prefix), do: :exbitnode_native_rocksdb.prefix_scan(db, prefix)
end
