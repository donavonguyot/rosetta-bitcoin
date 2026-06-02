defmodule Exbitnode.Consensus.Connect.ConnectBlockError do
  defexception [:message]
end

defmodule Exbitnode.Consensus.Connect.ValidationBlocker do
  defexception [:message, :height, :block_hash_hex, :txid_hex, :input_index, :spent_script_pubkey_hex, :missing_rule]

  @impl true
  def exception(opts) do
    struct!(__MODULE__, opts)
  end

  def from_unsupported_template(height, block_hash_hex, txid_hex, input_index, script_pubkey) do
    template = Exbitnode.Consensus.Script.ScriptTemplates.describe(script_pubkey)

    %__MODULE__{
      message: "unsupported scriptPubKey template #{template}",
      height: height,
      block_hash_hex: block_hash_hex,
      txid_hex: txid_hex,
      input_index: input_index,
      spent_script_pubkey_hex: Exbitnode.Util.Hex.encode(script_pubkey),
      missing_rule: "unsupported_script_template"
    }
  end
end
