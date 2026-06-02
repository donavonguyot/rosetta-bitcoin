defmodule Exbitnode.Consensus.Script.ScriptVerifyError do
  defexception [:message]
end

defmodule Exbitnode.Consensus.Script.UnsupportedScriptRule do
  defexception [:message, :rule]

  @impl true
  def exception(opts) do
    rule = Keyword.fetch!(opts, :rule)
    message = Keyword.get(opts, :message, "unsupported script rule")
    %__MODULE__{message: message, rule: rule}
  end
end

defmodule Exbitnode.Consensus.Script.ScriptVerify do
  @moduledoc false

  alias Exbitnode.Consensus.Script.{
    Interpreter,
    ScriptTemplates,
    ScriptVerifyError,
    UnsupportedScriptRule
  }

  def verify_transaction_input(tx, input_index, script_pubkey, amount, spent_prevouts \\ nil)
      when is_binary(script_pubkey) do
    if input_index >= length(tx.inputs) do
      raise ScriptVerifyError, "input index out of range"
    end

    witness_version = witness_program_version(script_pubkey)

    if witness_version != nil and witness_version > 1 do
      raise ScriptVerifyError, "unsupported witness program version #{witness_version}"
    end

    unless supported_template?(script_pubkey) do
      raise ScriptVerifyError, "unsupported scriptPubKey template"
    end

    if ScriptTemplates.is_p2wsh?(script_pubkey) or ScriptTemplates.is_p2sh?(script_pubkey) do
      raise UnsupportedScriptRule,
        rule: "script_interpreter_not_implemented",
        message:
          "script verification not yet implemented for template #{ScriptTemplates.describe(script_pubkey)}"
    end

    input = Enum.at(tx.inputs, input_index)

    witness =
      if input_index < length(tx.witness) do
        Enum.at(tx.witness, input_index)
      else
        []
      end

    if Interpreter.verify_script(
         input.script_sig,
         script_pubkey,
         tx,
         input_index,
         amount,
         witness,
         spent_prevouts
       ) do
      :ok
    else
      raise ScriptVerifyError, "script verification failed for input #{input_index}"
    end
  end

  defp supported_template?(script_pubkey) do
    ScriptTemplates.is_p2pk?(script_pubkey) or ScriptTemplates.is_p2pkh?(script_pubkey) or
      ScriptTemplates.is_p2wpkh?(script_pubkey) or ScriptTemplates.is_p2wsh?(script_pubkey) or
      ScriptTemplates.is_p2sh?(script_pubkey) or ScriptTemplates.is_p2tr?(script_pubkey) or
      ScriptTemplates.is_bare_op_n?(script_pubkey)
  end

  defp witness_program_version(script) when byte_size(script) < 2, do: nil

  defp witness_program_version(<<0x00, _rest::binary>>), do: 0
  defp witness_program_version(<<0x51, _rest::binary>>), do: 1
  defp witness_program_version(_), do: nil
end
