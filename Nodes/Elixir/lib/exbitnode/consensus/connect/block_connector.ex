defmodule Exbitnode.Consensus.Connect.BlockConnector do
  @moduledoc """
  Block-local UTXO view, script verification, then atomic chainstate commit.
  Missing rules become validation blockers.
  """

  alias Exbitnode.Consensus.{
    BlockValidationError,
    BlockValidator,
    ConsensusConstants,
    Merkle
  }

  alias Exbitnode.Consensus.Connect.{BlockUtxoView, ConnectBlockError, ValidationBlocker}

  alias Exbitnode.Consensus.Script.{
    ScriptVerify,
    ScriptVerifyError,
    ScriptVerifyRunner,
    UnsupportedScriptRule
  }

  alias Exbitnode.Consensus.Tx.Transaction
  alias Exbitnode.Chainstate.Tracker, as: ChainstateTracker
  alias Exbitnode.Messages.BlockHeaderCodec
  alias Exbitnode.Util.Hex

  def connect(
        conn,
        chain,
        height,
        payload,
        expected_prev_internal,
        expected_hash_internal,
        stored \\ nil,
        opts \\ []
      ) do
    connect_started_at = System.monotonic_time(:microsecond)

    validated =
      case Keyword.fetch(opts, :expected_validated_height) do
        {:ok, height} -> height
        :error -> ChainstateTracker.get_validated_height(conn, chain)
      end

    if height != validated + 1 do
      raise ConnectBlockError,
            "cannot connect height #{height} on top of validated tip #{validated}"
    end

    block =
      try do
        BlockValidator.validate_block(payload, expected_prev_internal, expected_hash_internal)
      rescue
        e in BlockValidationError ->
          reraise ConnectBlockError, [message: e.message], __STACKTRACE__
      end

    block_hash_hex = BlockHeaderCodec.block_hash_hex(block.header)
    Process.put(:exbitnode_script_verify_us, 0)
    Process.put(:exbitnode_script_runner_wait_us, 0)
    Process.put(:exbitnode_utxo_apply_us, 0)

    {utxo_load_us, loaded_prevouts} =
      timed(fn -> preload_external_prevouts(conn, chain, block) end)

    view = BlockUtxoView.new(conn, chain, height, loaded_prevouts)

    view =
      block.transactions
      |> Enum.reject(&Transaction.coinbase?/1)
      |> Enum.reduce(view, fn tx, acc_view ->
        txid = Merkle.transaction_txid(tx)
        txid_hex = txid |> Hex.reverse() |> Hex.encode()

        acc_view =
          validate_non_coinbase_transaction(acc_view, block_hash_hex, height, txid_hex, tx)

        Enum.reduce(Enum.with_index(tx.outputs), acc_view, fn {output, vout}, inner_view ->
          if spendable_output?(output.script_pubkey) do
            BlockUtxoView.create(
              inner_view,
              txid,
              vout,
              output.value,
              output.script_pubkey,
              false
            )
          else
            inner_view
          end
        end)
      end)

    coinbase = hd(block.transactions)
    coinbase_txid = Merkle.transaction_txid(coinbase)

    view =
      Enum.reduce(Enum.with_index(coinbase.outputs), view, fn {output, vout}, acc_view ->
        if height > 0 and spendable_output?(output.script_pubkey) do
          BlockUtxoView.create(
            acc_view,
            coinbase_txid,
            vout,
            output.value,
            output.script_pubkey,
            true
          )
        else
          acc_view
        end
      end)

    {commit_us, :ok} =
      timed(fn ->
        ChainstateTracker.commit_block(conn, chain, %{
          height: height,
          block_hash: block_hash_hex,
          stored: stored || default_stored(payload),
          header_serialized_hex: BlockHeaderCodec.serialize(block.header) |> Hex.encode(),
          created: BlockUtxoView.created_utxos(view),
          spent: BlockUtxoView.external_spent_outpoints(view),
          undo: BlockUtxoView.external_spend_undo_entries(view)
        })
      end)

    connect_us = System.monotonic_time(:microsecond) - connect_started_at

    %{
      height: height,
      block_hash_hex: block_hash_hex,
      utxos_created: view.created_count,
      timing: %{
        utxo_load: utxo_load_us,
        script_verify: Process.get(:exbitnode_script_verify_us, 0),
        script_runner_wait: Process.get(:exbitnode_script_runner_wait_us, 0),
        utxo_apply: Process.get(:exbitnode_utxo_apply_us, 0),
        commit: commit_us,
        block_connect_store_commit: connect_us
      }
    }
  end

  def disconnect(conn, chain, height) do
    validated = ChainstateTracker.get_validated_height(conn, chain)

    cond do
      validated != height ->
        raise ConnectBlockError,
              "cannot disconnect height #{height}: validated tip is #{validated}"

      height < 1 ->
        raise ConnectBlockError, "cannot disconnect genesis (height < 1)"

      true ->
        prev_hash_hex = ChainstateTracker.get_header_hash(conn, chain, height - 1)

        if is_nil(prev_hash_hex) do
          raise ConnectBlockError, "missing header at height #{height - 1}"
        end

        undo_entries = ChainstateTracker.take_utxo_undo(conn, chain, height)
        :ok = ChainstateTracker.delete_utxos_created_at_height(conn, chain, height)

        Enum.each(undo_entries, fn entry ->
          ChainstateTracker.insert_utxo(conn, chain, %{
            txid: entry.txid,
            vout: entry.vout,
            height: entry.utxo_height,
            value_sats: entry.value_sats,
            script_pubkey_hex: entry.script_pubkey_hex,
            coinbase: entry.coinbase
          })
        end)

        ChainstateTracker.set_validated_tip(conn, chain, height - 1, prev_hash_hex)

        :ok
    end
  end

  def spendable_output?(script_pubkey) when is_binary(script_pubkey),
    do: byte_size(script_pubkey) > 0 and :binary.at(script_pubkey, 0) != 0x6A

  defp preload_external_prevouts(conn, chain, block) do
    txids = Enum.map(block.transactions, &Merkle.transaction_txid/1)
    same_block_outputs = same_block_outputs(block, txids)

    outpoints =
      block.transactions
      |> Enum.reject(&Transaction.coinbase?/1)
      |> Enum.flat_map(fn tx ->
        Enum.map(tx.inputs, &BlockUtxoView.outpoint_tuple(&1.previous_output))
      end)
      |> Enum.reject(&MapSet.member?(same_block_outputs, &1))
      |> Enum.uniq()

    conn
    |> ChainstateTracker.get_utxos(chain, outpoints)
    |> Enum.zip(outpoints)
    |> Enum.flat_map(fn
      {nil, _outpoint} ->
        []

      {utxo, outpoint} ->
        [{BlockUtxoView.outpoint_key(outpoint), BlockUtxoView.normalize_utxo(utxo)}]
    end)
    |> Map.new()
  end

  defp same_block_outputs(block, txids) do
    block.transactions
    |> Enum.zip(txids)
    |> Enum.flat_map(fn {tx, txid} ->
      tx.outputs
      |> Enum.with_index()
      |> Enum.flat_map(fn {output, vout} ->
        if spendable_output?(output.script_pubkey) do
          [{txid |> Hex.reverse() |> Hex.encode(), vout}]
        else
          []
        end
      end)
    end)
    |> MapSet.new()
  end

  defp default_stored(payload) do
    %{file_number: 0, file_offset: 0, block_size: byte_size(payload)}
  end

  defp validate_non_coinbase_transaction(view, block_hash_hex, height, txid_hex, tx) do
    {utxo_infos, _} =
      Enum.reduce(tx.inputs, {[], MapSet.new()}, fn input, {infos, seen} ->
        lookup = BlockUtxoView.lookup_key(input.previous_output)

        if MapSet.member?(seen, lookup) do
          raise ConnectBlockError, "double spend of #{lookup}"
        end

        utxo = BlockUtxoView.get(view, input.previous_output)

        if utxo == nil do
          raise ConnectBlockError, "missing UTXO #{lookup}"
        end

        if utxo.coinbase and height - utxo.height < ConsensusConstants.coinbase_maturity() do
          raise ConnectBlockError,
                "coinbase output not mature at height #{height} (created at #{utxo.height})"
        end

        {[utxo | infos], MapSet.put(seen, lookup)}
      end)

    utxo_infos = Enum.reverse(utxo_infos)

    spent_prevouts =
      Enum.map(utxo_infos, fn utxo ->
        {utxo.value_sats, BlockUtxoView.script_pubkey(utxo)}
      end)

    jobs =
      utxo_infos
      |> Enum.with_index()
      |> Enum.map(fn {utxo, input_index} ->
        %{
          tx: tx,
          input_index: input_index,
          utxo: utxo,
          spent_prevouts: spent_prevouts,
          height: height,
          block_hash_hex: block_hash_hex,
          txid_hex: txid_hex
        }
      end)

    {script_us, :ok} = timed(fn -> ScriptVerifyRunner.run(jobs, &verify_script_job!/1) end)
    bump_timing(:exbitnode_script_verify_us, script_us)
    bump_timing(:exbitnode_script_runner_wait_us, script_us)

    input_total = Enum.reduce(utxo_infos, 0, fn utxo, total -> total + utxo.value_sats end)

    output_total = Enum.reduce(tx.outputs, 0, fn output, acc -> acc + output.value end)

    if input_total < output_total do
      raise ConnectBlockError, "transaction outputs exceed inputs"
    end

    {utxo_apply_us, view} =
      timed(fn ->
        Enum.reduce(tx.inputs, view, fn input, acc_view ->
          BlockUtxoView.spend(acc_view, input.previous_output)
        end)
      end)

    bump_timing(:exbitnode_utxo_apply_us, utxo_apply_us)
    view
  end

  defp verify_script_job!(%{
         tx: tx,
         input_index: input_index,
         utxo: utxo,
         spent_prevouts: spent_prevouts,
         height: height,
         block_hash_hex: block_hash_hex,
         txid_hex: txid_hex
       }) do
    script_pubkey = BlockUtxoView.script_pubkey(utxo)

    try do
      :ok =
        ScriptVerify.verify_transaction_input(
          tx,
          input_index,
          script_pubkey,
          utxo.value_sats,
          spent_prevouts
        )
    rescue
      e in UnsupportedScriptRule ->
        raise ValidationBlocker,
          message: e.message,
          height: height,
          block_hash_hex: block_hash_hex,
          txid_hex: txid_hex,
          input_index: input_index,
          spent_script_pubkey_hex: utxo.script_pubkey_hex,
          missing_rule: e.rule

      e in ScriptVerifyError ->
        if String.contains?(e.message, "unsupported scriptPubKey template") do
          raise ValidationBlocker.from_unsupported_template(
                  height,
                  block_hash_hex,
                  txid_hex,
                  input_index,
                  script_pubkey
                )
        end

        raise ValidationBlocker,
          message: e.message,
          height: height,
          block_hash_hex: block_hash_hex,
          txid_hex: txid_hex,
          input_index: input_index,
          spent_script_pubkey_hex: utxo.script_pubkey_hex,
          missing_rule: "script_verification_failed"
    end
  end

  defp timed(fun) do
    start = System.monotonic_time(:microsecond)
    result = fun.()
    {System.monotonic_time(:microsecond) - start, result}
  end

  defp bump_timing(key, delta) do
    Process.put(key, Process.get(key, 0) + delta)
    :ok
  end
end

defmodule Exbitnode.Consensus.Connect.BlockUtxoView do
  @moduledoc false

  alias Exbitnode.Consensus.Tx.OutPoint
  alias Exbitnode.Consensus.Connect.ConnectBlockError
  alias Exbitnode.Util.Hex

  defstruct [
    :conn,
    :chain,
    :height,
    :created,
    :loaded,
    :spent,
    :external_spent,
    :external_undo,
    :created_count
  ]

  def new(conn, chain, height, loaded \\ %{}) do
    %__MODULE__{
      conn: conn,
      chain: chain,
      height: height,
      created: %{},
      loaded: loaded,
      spent: MapSet.new(),
      external_spent: MapSet.new(),
      external_undo: [],
      created_count: 0
    }
  end

  def outpoint_tuple(%OutPoint{hash: hash, index: index}) do
    {hash |> Hex.reverse() |> Hex.encode(), index}
  end

  def lookup_key({txid, vout}), do: "#{txid}:#{vout}"

  def lookup_key(%OutPoint{hash: hash, index: index}) do
    "#{hash |> Hex.reverse() |> Hex.encode()}:#{index}"
  end

  def outpoint_key({txid, vout}), do: {txid, vout}
  def outpoint_key(%OutPoint{} = outpoint), do: outpoint |> outpoint_tuple() |> outpoint_key()

  def normalize_utxo(%{script_pubkey: script_pubkey} = utxo) when is_binary(script_pubkey),
    do: utxo

  def normalize_utxo(%{script_pubkey_hex: script_pubkey_hex} = utxo) do
    Map.put(utxo, :script_pubkey, Hex.decode(script_pubkey_hex))
  end

  def script_pubkey(%{script_pubkey: script_pubkey}) when is_binary(script_pubkey),
    do: script_pubkey

  def script_pubkey(%{script_pubkey_hex: script_pubkey_hex}), do: Hex.decode(script_pubkey_hex)

  def get(%__MODULE__{} = view, %OutPoint{} = outpoint) do
    key = outpoint_key(outpoint)

    cond do
      MapSet.member?(view.spent, key) ->
        nil

      Map.has_key?(view.created, key) ->
        Map.get(view.created, key)

      true ->
        Map.get(view.loaded, key)
    end
  end

  def create(%__MODULE__{} = view, txid_internal, vout, value, script_pubkey, coinbase?) do
    txid_hex = txid_internal |> Hex.reverse() |> Hex.encode()
    key = {txid_hex, vout}

    utxo = %{
      txid: txid_hex,
      vout: vout,
      height: view.height,
      value_sats: value,
      script_pubkey_hex: Hex.encode(script_pubkey),
      script_pubkey: script_pubkey,
      coinbase: coinbase?
    }

    %{view | created: Map.put(view.created, key, utxo), created_count: view.created_count + 1}
  end

  def spend(%__MODULE__{} = view, %OutPoint{} = outpoint) do
    key = outpoint_key(outpoint)
    display_key = lookup_key(outpoint)
    utxo = get(view, outpoint)

    if utxo == nil do
      raise ConnectBlockError, "missing UTXO to spend #{display_key}"
    end

    external_undo =
      if Map.has_key?(view.created, key) do
        view.external_undo
      else
        [
          %{
            txid: utxo.txid,
            vout: utxo.vout,
            utxo_height: utxo.height,
            value_sats: utxo.value_sats,
            script_pubkey_hex: utxo.script_pubkey_hex,
            coinbase: utxo.coinbase
          }
          | view.external_undo
        ]
      end

    external_spent =
      if Map.has_key?(view.created, key) do
        view.external_spent
      else
        MapSet.put(view.external_spent, key)
      end

    %{
      view
      | spent: MapSet.put(view.spent, key),
        external_spent: external_spent,
        created: Map.delete(view.created, key),
        external_undo: external_undo
    }
  end

  def external_spend_undo_entries(%__MODULE__{external_undo: entries}), do: Enum.reverse(entries)

  def external_spent_outpoints(%__MODULE__{} = view) do
    view.external_spent
    |> Enum.map(fn {txid, vout} -> {txid, vout} end)
    |> Enum.sort()
  end

  def created_utxos(%__MODULE__{created: created}),
    do: created |> Map.values() |> Enum.sort_by(&{&1.txid, &1.vout})
end
