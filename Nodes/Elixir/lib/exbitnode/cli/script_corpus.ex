defmodule Exbitnode.CLI.ScriptCorpus do
  @moduledoc false

  alias Exbitnode.Consensus.Script.{ScriptVerify, ScriptVerifyError, UnsupportedScriptRule}
  alias Exbitnode.Consensus.Tx.TransactionParser
  alias Exbitnode.Util.Hex

  def run(args) do
    Application.ensure_all_started(:exbitnode)

    opts = parse_args(args)
    manifest_path = Map.get(opts, "manifest", default_manifest_path())
    result_path = Map.get(opts, "result-path", default_result_path())
    fixtures_root = Path.dirname(manifest_path)

    manifest = manifest_path |> File.read!() |> Jason.decode!()
    selected_fixture = Map.get(opts, "fixture")
    stop_on_failure = Map.get(opts, "stop-on-failure") == true

    results =
      manifest["fixtures"]
      |> maybe_filter_fixture(selected_fixture)
      |> run_fixtures(fixtures_root, stop_on_failure)

    passed = Enum.count(results, &(&1.result == "passed"))
    failed = Enum.count(results, &(&1.result == "failed"))

    output = %{
      implementation: "ElixirNode",
      runner: "mix script.corpus",
      manifest: manifest_path,
      captured_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      fixture_count: length(results),
      passed: passed,
      failed: failed,
      results: results
    }

    json = Jason.encode!(output, pretty: true)
    File.mkdir_p!(Path.dirname(result_path))
    File.write!(result_path, json <> "\n")
    IO.puts(json)

    if failed == 0, do: 0, else: 1
  end

  defp maybe_filter_fixture(fixtures, nil), do: fixtures

  defp maybe_filter_fixture(fixtures, fixture_id) do
    Enum.filter(fixtures, &(&1["fixture_id"] == fixture_id))
  end

  defp run_fixtures(fixtures, fixtures_root, false) do
    Enum.map(fixtures, &run_fixture(&1, fixtures_root))
  end

  defp run_fixtures(fixtures, fixtures_root, true) do
    fixtures
    |> Enum.reduce_while([], fn fixture, acc ->
      result = run_fixture(fixture, fixtures_root)
      next = [result | acc]

      if result.result == "failed" do
        {:halt, next}
      else
        {:cont, next}
      end
    end)
    |> Enum.reverse()
  end

  defp run_fixture(fixture, fixtures_root) do
    input_index = fixture["input_index"] || 0

    try do
      tx_hex = read_fixture_file!(fixture, fixtures_root, "tx")
      prevouts = read_prevouts!(fixture, fixtures_root)
      {tx, _offset} = TransactionParser.parse(Hex.decode(tx_hex), 0, true)
      prevout = Enum.at(prevouts, input_index) || hd(prevouts)
      prev_spk = Hex.decode(prevout["spk"])
      amount = prevout["amount"] || prev_amount_sats(fixture)

      spent_prevouts =
        Enum.map(prevouts, fn row ->
          {row["amount"], Hex.decode(row["spk"])}
        end)

      :ok = ScriptVerify.verify_transaction_input(tx, input_index, prev_spk, amount, spent_prevouts)

      fixture_result(fixture, "passed", "", "", "", input_index)
    rescue
      e ->
        failure = Exception.message(e)

        fixture_result(
          fixture,
          "failed",
          failure,
          failure_type(e),
          failure_stage(failure),
          input_index
        )
    end
  end

  defp fixture_result(fixture, result, failure, failure_type, failure_stage, input_index) do
    %{
      fixture_id: fixture["fixture_id"],
      height: fixture["height"],
      txid: get_in(fixture, ["raw_meta", "txid"]) || fixture["txid"] || "",
      input_index: input_index,
      result: result,
      failure: failure,
      failure_type: failure_type,
      failure_stage: failure_stage,
      required_rules: fixture["required_rules"] || []
    }
  end

  defp read_fixture_file!(fixture, root, category) do
    [relative | _] = get_in(fixture, ["files", category])
    Path.join(root, relative) |> File.read!() |> String.trim()
  end

  defp read_fixture_json!(fixture, root, category) do
    fixture
    |> read_fixture_file!(root, category)
    |> Jason.decode!()
  end

  defp read_prevouts!(fixture, root) do
    if get_in(fixture, ["files", "prevouts"]) do
      read_fixture_json!(fixture, root, "prevouts")
    else
      spk_hex = read_fixture_file!(fixture, root, "prev_spk")
      [%{"amount" => prev_amount_sats(fixture), "spk" => spk_hex}]
    end
  end

  defp prev_amount_sats(fixture) do
    fixture["prev_amount_sats"] || get_in(fixture, ["raw_meta", "prev_amount_sats"])
  end

  defp failure_type(%UnsupportedScriptRule{rule: rule}), do: rule
  defp failure_type(%ScriptVerifyError{}), do: "script_verify_error"
  defp failure_type(%RuntimeError{}), do: "runtime_error"
  defp failure_type(%FunctionClauseError{}), do: "function_clause"
  defp failure_type(%MatchError{}), do: "match_error"
  defp failure_type(_), do: "exception"

  defp failure_stage(message) do
    text = String.downcase(message)

    cond do
      text =~ "taproot" or text =~ "tapscript" -> "taproot"
      text =~ "sighash" -> "sighash"
      text =~ "opcode" or text =~ "op_" -> "opcode"
      text =~ "stack" -> "stack"
      text =~ "template" or text =~ "scriptpubkey" -> "template"
      text =~ "signature" or text =~ "secp256k1" or text =~ "schnorr" -> "crypto"
      true -> "stack"
    end
  end

  defp parse_args(args) do
    parse_args(args, %{})
  end

  defp parse_args([], acc), do: acc
  defp parse_args(["--" <> key | rest], acc) do
    case rest do
      [<<"--", _::binary>> | _] -> parse_args(rest, Map.put(acc, key, true))
      [value | tail] -> parse_args(tail, Map.put(acc, key, value))
      [] -> Map.put(acc, key, true)
    end
  end

  defp parse_args([_ | rest], acc) do
    parse_args(rest, acc)
  end

  defp default_manifest_path do
    Path.expand("../../NodeCore/conformance/fixtures/scripts/manifest.json", File.cwd!())
  end

  defp default_result_path do
    date = Date.utc_today() |> Date.to_iso8601(:basic)
    Path.expand("../../NodeCore/conformance/results/elixir_script_corpus_#{date}.json", File.cwd!())
  end
end
