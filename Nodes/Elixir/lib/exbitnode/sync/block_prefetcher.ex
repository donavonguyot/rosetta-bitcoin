defmodule Exbitnode.Sync.BlockPrefetcher do
  @moduledoc false

  alias Exbitnode.Chainstate.Tracker, as: ChainstateTracker
  alias Exbitnode.P2p.PeerServer
  alias Exbitnode.Util.Hex

  defstruct [:depth, tasks: %{}]

  def new(depth), do: %__MODULE__{depth: max(depth, 0), tasks: %{}}

  def ensure(%__MODULE__{depth: depth} = prefetcher, _peer_pid, _chain, _conn, _next_height)
      when depth <= 0,
      do: prefetcher

  def ensure(%__MODULE__{} = prefetcher, peer_pid, chain, conn, next_height) do
    wanted =
      next_height..(next_height + prefetcher.depth - 1)
      |> Enum.flat_map(fn height ->
        case ChainstateTracker.get_header_hash(conn, chain, height) do
          nil -> []
          hash_hex -> [{height, Hex.reverse(Hex.decode(hash_hex))}]
        end
      end)

    tasks =
      Enum.reduce(wanted, prefetcher.tasks, fn {height, block_hash_internal}, tasks ->
        if Map.has_key?(tasks, height) do
          tasks
        else
          Map.put(tasks, height, Task.async(fn -> {height, PeerServer.request_block(peer_pid, block_hash_internal)} end))
        end
      end)

    keep = MapSet.new(Enum.map(wanted, fn {height, _hash} -> height end))

    stale =
      tasks
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(keep, &1))

    tasks =
      Enum.reduce(stale, tasks, fn height, acc ->
        acc
        |> Map.fetch!(height)
        |> Task.shutdown(:brutal_kill)

        Map.delete(acc, height)
      end)

    %{prefetcher | tasks: tasks}
  end

  def pop(%__MODULE__{} = prefetcher, height) do
    case Map.pop(prefetcher.tasks, height) do
      {nil, tasks} ->
        {%{prefetcher | tasks: tasks}, :miss}

      {task, tasks} ->
        result =
          try do
            case Task.await(task, 140_000) do
              {^height, result} -> result
              {_other_height, result} -> result
            end
          catch
            :exit, reason -> {:error, reason}
          end

        {%{prefetcher | tasks: tasks}, result}
    end
  end

  def cancel_all(%__MODULE__{} = prefetcher) do
    Enum.each(prefetcher.tasks, fn {_height, task} -> Task.shutdown(task, :brutal_kill) end)
    %{prefetcher | tasks: %{}}
  end
end
