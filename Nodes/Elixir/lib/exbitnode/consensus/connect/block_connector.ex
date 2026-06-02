defmodule Exbitnode.Consensus.Connect.BlockConnector do
  @moduledoc false

  alias Exbitnode.Consensus.{
    BlockValidationError,
    BlockValidator,
    ConsensusConstants,
    Merkle
  }

  alias Exbitnode.Consensus.Connect.{BlockUtxoView, ConnectBlockError, ValidationBlocker}
  alias Exbitnode.Consensus.Script.{ScriptVerify, ScriptVerifyError, UnsupportedScriptRule}
  alias Exbitnode.Consensus.Tx.Transaction
  alias Exbitnode.Db.{ProjectTracker, Sql}
  alias Exbitnode.Messages.BlockHeaderCodec
  alias Exbitnode.Util.Hex

  def connect(conn, chain, height, payload, expected_prev_internal, expected_hash_internal) do
    validated = ProjectTracker.get_validated_height(conn, chain)

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
    view = BlockUtxoView.new(conn, chain, height)

    view =
      block.transactions
      |> Enum.reject(&Transaction.coinbase?/1)
      |> Enum.reduce(view, fn tx, acc_view ->
        txid = Merkle.transaction_txid(tx)
        txid_hex = txid |> Hex.reverse() |> Hex.encode()
        acc_view = validate_non_coinbase_transaction(acc_view, block_hash_hex, height, txid_hex, tx)

        Enum.reduce(Enum.with_index(tx.outputs), acc_view, fn {output, vout}, inner_view ->
          if spendable_output?(output.script_pubkey) do
            BlockUtxoView.create(inner_view, txid, vout, output.value, output.script_pubkey, false)
          else
            inner_view
          end
        end)
      end)

    coinbase = hd(block.transactions)
    coinbase_txid = Merkle.transaction_txid(coinbase)

    view =
      Enum.reduce(Enum.with_index(coinbase.outputs), view, fn {output, vout}, acc_view ->
        if spendable_output?(output.script_pubkey) do
          BlockUtxoView.create(acc_view, coinbase_txid, vout, output.value, output.script_pubkey, true)
        else
          acc_view
        end
      end)

    undo_entries = BlockUtxoView.external_spend_undo_entries(view)

    Sql.with_transaction(conn, fn tx_conn ->
      BlockUtxoView.apply(view, tx_conn)
      ProjectTracker.replace_utxo_undo(tx_conn, chain, height, undo_entries)
      ProjectTracker.set_validated_tip(tx_conn, chain, height, block_hash_hex)
    end)

    %{height: height, block_hash_hex: block_hash_hex, utxos_created: view.created_count}
  end

  def disconnect(conn, chain, height) do
    validated = ProjectTracker.get_validated_height(conn, chain)

    cond do
      validated != height ->
        raise ConnectBlockError,
              "cannot disconnect height #{height}: validated tip is #{validated}"

      height < 1 ->
        raise ConnectBlockError, "cannot disconnect genesis (height < 1)"

      true ->
        prev_hash_hex = ProjectTracker.get_header_hash(conn, chain, height - 1)

        if is_nil(prev_hash_hex) do
          raise ConnectBlockError, "missing header at height #{height - 1}"
        end

        Sql.with_transaction(conn, fn tx_conn ->
          undo_entries = ProjectTracker.take_utxo_undo(tx_conn, chain, height)
          :ok = ProjectTracker.delete_utxos_created_at_height(tx_conn, chain, height)

          Enum.each(undo_entries, fn entry ->
            ProjectTracker.insert_utxo(tx_conn, chain, %{
              txid: entry.txid,
              vout: entry.vout,
              height: entry.utxo_height,
              value_sats: entry.value_sats,
              script_pubkey_hex: entry.script_pubkey_hex,
              coinbase: entry.coinbase
            })
          end)

          ProjectTracker.set_validated_tip(tx_conn, chain, height - 1, prev_hash_hex)
        end)

        :ok
    end
  end

  def spendable_output?(script_pubkey) when is_binary(script_pubkey), do: byte_size(script_pubkey) > 0

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
        {utxo.value_sats, Hex.decode(utxo.script_pubkey_hex)}
      end)

    input_total =
      utxo_infos
      |> Enum.with_index()
      |> Enum.reduce(0, fn {utxo, input_index}, total ->
        script_pubkey = Hex.decode(utxo.script_pubkey_hex)

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

        total + utxo.value_sats
      end)

    output_total = Enum.reduce(tx.outputs, 0, fn output, acc -> acc + output.value end)

    if input_total < output_total do
      raise ConnectBlockError, "transaction outputs exceed inputs"
    end

    Enum.reduce(tx.inputs, view, fn input, acc_view ->
      BlockUtxoView.spend(acc_view, input.previous_output)
    end)
  end
end

defmodule Exbitnode.Consensus.Connect.BlockUtxoView do
  @moduledoc false

  alias Exbitnode.Consensus.Tx.OutPoint
  alias Exbitnode.Consensus.Connect.ConnectBlockError
  alias Exbitnode.Db.ProjectTracker
  alias Exbitnode.Util.Hex

  defstruct [:conn, :chain, :height, :overlay, :spent, :external_undo, :created_count]

  def new(conn, chain, height) do
    %__MODULE__{
      conn: conn,
      chain: chain,
      height: height,
      overlay: %{},
      spent: MapSet.new(),
      external_undo: [],
      created_count: 0
    }
  end

  def lookup_key(%OutPoint{hash: hash, index: index}) do
    "#{hash |> Hex.reverse() |> Hex.encode()}:#{index}"
  end

  def get(%__MODULE__{} = view, %OutPoint{} = outpoint) do
    key = lookup_key(outpoint)

    cond do
      MapSet.member?(view.spent, key) ->
        nil

      Map.has_key?(view.overlay, key) ->
        Map.get(view.overlay, key)

      true ->
        [txid, vout] = String.split(key, ":", parts: 2)
        ProjectTracker.get_utxo(view.conn, view.chain, txid, String.to_integer(vout))
    end
  end

  def create(%__MODULE__{} = view, txid_internal, vout, value, script_pubkey, coinbase?) do
    txid_hex = txid_internal |> Hex.reverse() |> Hex.encode()
    key = "#{txid_hex}:#{vout}"

    utxo = %{
      txid: txid_hex,
      vout: vout,
      height: view.height,
      value_sats: value,
      script_pubkey_hex: Hex.encode(script_pubkey),
      coinbase: coinbase?
    }

    %{view | overlay: Map.put(view.overlay, key, utxo), created_count: view.created_count + 1}
  end

  def spend(%__MODULE__{} = view, %OutPoint{} = outpoint) do
    key = lookup_key(outpoint)
    utxo = get(view, outpoint)

    if utxo == nil do
      raise ConnectBlockError, "missing UTXO to spend #{key}"
    end

    external_undo =
      if Map.has_key?(view.overlay, key) do
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

    %{
      view
      | spent: MapSet.put(view.spent, key),
        overlay: Map.delete(view.overlay, key),
        external_undo: external_undo
    }
  end

  def external_spend_undo_entries(%__MODULE__{external_undo: entries}), do: Enum.reverse(entries)

  def apply(%__MODULE__{} = view, conn) do
    Enum.each(view.spent, fn key ->
      [txid, vout] = String.split(key, ":", parts: 2)
      ProjectTracker.delete_utxo(conn, view.chain, txid, String.to_integer(vout))
    end)

    Enum.each(view.overlay, fn {_key, utxo} ->
      ProjectTracker.insert_utxo(conn, view.chain, utxo)
    end)

    :ok
  end
end
