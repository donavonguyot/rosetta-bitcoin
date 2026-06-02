defmodule Exbitnode.Storage.BlockStore do
  @moduledoc false

  defstruct [:blocks_dir, :magic, :file_number, :file_handle]

  def new(blocks_dir, magic) when is_binary(blocks_dir) and is_binary(magic) do
    File.mkdir_p!(blocks_dir)
    file_number = find_latest_file_number(blocks_dir)
    store = %__MODULE__{blocks_dir: blocks_dir, magic: magic, file_number: file_number, file_handle: nil}
    open_current_file(store, true)
  end

  def write_block(%__MODULE__{} = store, payload) when is_binary(payload) do
    store = ensure_open(store)
    path = block_file_path(store.blocks_dir, store.file_number)
    {:ok, stat} = File.stat(path)
    offset = stat.size
    record = store.magic <> <<byte_size(payload)::little-signed-32>> <> payload
    IO.binwrite(store.file_handle, record)
    :file.sync(store.file_handle)
    {store, %{file_number: store.file_number, file_offset: offset, block_size: byte_size(payload)}}
  end

  def read_block(%__MODULE__{} = store, file_number, offset, size) do
    path = block_file_path(store.blocks_dir, file_number)

    {:ok, file} = File.open(path, [:read, :binary])

    try do
      {:ok, magic} = :file.pread(file, offset, 4)

      if magic != store.magic do
        raise ArgumentError, "block file magic mismatch"
      end

      {:ok, len_bin} = :file.pread(file, offset + 4, 4)
      <<len::little-signed-32>> = len_bin

      if len != size do
        raise ArgumentError, "block size mismatch expected #{size} got #{len}"
      end

      {:ok, payload} = :file.pread(file, offset + 8, len)
      payload
    after
      File.close(file)
    end
  end

  def close(%__MODULE__{file_handle: nil}), do: :ok

  def close(%__MODULE__{file_handle: handle}) when not is_nil(handle) do
    File.close(handle)
    :ok
  end

  defp ensure_open(%__MODULE__{file_handle: nil} = store), do: open_current_file(store, true)
  defp ensure_open(%__MODULE__{} = store), do: store

  defp open_current_file(%__MODULE__{} = store, append?) do
    path = block_file_path(store.blocks_dir, store.file_number)
    mode = if append?, do: [:append, :binary, :raw], else: [:write, :binary, :raw]
    {:ok, handle} = File.open(path, mode)
    %{store | file_handle: handle}
  end

  defp block_file_path(blocks_dir, file_number) do
    Path.join(blocks_dir, "blk#{String.pad_leading(Integer.to_string(file_number), 5, "0")}.dat")
  end

  defp find_latest_file_number(blocks_dir) do
    case File.ls(blocks_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.starts_with?(&1, "blk"))
        |> Enum.filter(&String.ends_with?(&1, ".dat"))
        |> Enum.map(fn name ->
          name |> String.replace_prefix("blk", "") |> String.replace_suffix(".dat", "") |> String.to_integer()
        end)
        |> Enum.max(fn -> 0 end)

      {:error, _} ->
        0
    end
  end
end

defmodule Exbitnode.Storage.BlockStorage do
  @moduledoc false

  alias Exbitnode.Storage.BlockStore

  def store(%BlockStore{} = store, payload) do
    {_store, location} = BlockStore.write_block(store, payload)
    location
  end
end
