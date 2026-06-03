defmodule Exbitnode.Config.NodePaths do
  @moduledoc false

  @default_chain "testnet4"
  @default_data_dir "./data-elixir"
  @lock_file ".exbitnode.lock"

  def default_chain, do: @default_chain
  def lock_file_name, do: @lock_file

  def data_dir_from_env do
    System.get_env("DATA_DIR", @default_data_dir) |> Path.expand()
  end

  def chain_from_env do
    System.get_env("CHAIN", @default_chain)
  end

  def chainstate_backend_from_env do
    System.get_env("CHAINSTATE_BACKEND", "rocksdb")
  end

  def rocksdb_path(data_dir \\ nil) do
    dir = data_dir || data_dir_from_env()
    Path.join(dir, "chainstate-rocksdb")
  end

  def parse_peers(nil, default_port), do: [{"127.0.0.1", default_port}]

  def parse_peers(peers, default_port) when is_binary(peers) do
    peers
    |> String.split(",", trim: true)
    |> Enum.map(fn entry ->
      case String.split(entry, ":", parts: 2) do
        [host, port] -> {host, String.to_integer(port)}
        [host] -> {host, default_port}
      end
    end)
  end

  def parse_int(nil, default), do: default

  def parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

  def parse_bool(nil, default), do: default

  def parse_bool(value, default) when is_binary(value) do
    case String.downcase(value) do
      "1" -> true
      "true" -> true
      "yes" -> true
      "0" -> false
      "false" -> false
      "no" -> false
      _ -> default
    end
  end
end
