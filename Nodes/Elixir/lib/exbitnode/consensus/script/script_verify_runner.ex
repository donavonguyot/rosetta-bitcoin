defmodule Exbitnode.Consensus.Script.ScriptVerifyRunner do
  @moduledoc false

  def run(jobs, verify_fun) when is_list(jobs) and is_function(verify_fun, 1) do
    if parallel_enabled?() and length(jobs) >= min_inputs() do
      run_parallel(jobs, verify_fun)
    else
      Enum.each(jobs, verify_fun)
      :ok
    end
  end

  defp run_parallel(jobs, verify_fun) do
    jobs
    |> Task.async_stream(
      fn job ->
        try do
          verify_fun.(job)
          {:ok, input_index(job)}
        rescue
          e -> {:error, input_index(job), e}
        end
      end,
      max_concurrency: threads(),
      ordered: false,
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, -1, RuntimeError.exception("script verification task exited: #{inspect(reason)}")}
    end)
    |> Enum.filter(&match?({:error, _input_index, _error}, &1))
    |> Enum.sort_by(fn {:error, input_index, _error} -> input_index end)
    |> case do
      [] ->
        :ok

      [{:error, _input_index, error} | _] ->
        raise error
    end
  end

  defp input_index(%{input_index: input_index}), do: input_index

  defp parallel_enabled? do
    (System.get_env("PAR_SCRIPT_VERIFY") || "") in ["1", "true", "TRUE", "yes", "YES"]
  end

  defp threads do
    System.get_env("PAR_SCRIPT_THREADS")
    |> parse_positive(System.schedulers_online())
  end

  defp min_inputs do
    System.get_env("PAR_SCRIPT_MIN_INPUTS")
    |> parse_positive(2)
  end

  defp parse_positive(nil, default), do: default

  defp parse_positive(value, default) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end
end
