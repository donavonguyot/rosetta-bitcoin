defmodule Exbitnode.Storage.DatadirLock do
  @moduledoc """
  Single-writer datadir lock for sync/connect paths (`.exbitnode.lock`).
  """

  alias Exbitnode.Config.NodePaths

  defmodule BusyError do
    defexception [:message]
  end

  def acquire(data_dir) do
    File.mkdir_p!(data_dir)
    path = Path.join(data_dir, NodePaths.lock_file_name())
    remove_stale_lock(path)

    case File.open(path, [:write, :read, :binary, :exclusive]) do
      {:ok, file} ->
        pid = System.pid()
        cmd = Enum.join(System.argv(), " ")
        IO.write(file, "#{pid} #{cmd}\n")
        {:ok, %{file: file, path: path}}

      {:error, reason} ->
        raise BusyError, "datadir lock busy at #{path}: #{inspect(reason)}"
    end
  end

  def release(%{file: file, path: path}) do
    File.close(file)

    case File.rm(path) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  def inspect_lock(data_dir) do
    path = Path.join(data_dir, NodePaths.lock_file_name())

    unless File.exists?(path) do
      return_idle()
    end

    case File.read(path) do
      {:ok, ""} ->
        File.rm(path)
        return_idle()

      {:ok, contents} ->
        line = contents |> String.trim()

        case String.split(line, " ", parts: 2) do
          [pid_str, command] ->
            if pid_alive?(pid_str) do
              {true, String.to_integer(pid_str), command}
            else
              File.rm(path)
              return_idle()
            end

          [pid_str] ->
            if pid_alive?(pid_str) do
              {true, String.to_integer(pid_str), nil}
            else
              File.rm(path)
              return_idle()
            end

          _ ->
            File.rm(path)
            return_idle()
        end

      {:error, :enoent} ->
        return_idle()

      {:error, _} ->
        {true, nil, nil}
    end
  end

  defp return_idle, do: {false, nil, nil}

  defp pid_alive?(pid_str) do
    case Integer.parse(pid_str) do
      {pid, _} ->
        case :os.type() do
          {:unix, :darwin} -> File.exists?("/proc/#{pid}") or kill_check(pid)
          _ -> kill_check(pid)
        end

      :error ->
        false
    end
  end

  defp kill_check(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp remove_stale_lock(path) do
    case inspect_lock(Path.dirname(path)) do
      {false, _, _} -> :ok
      _ -> :ok
    end
  end
end
