defmodule Exbitnode.Consensus.Tx.OutPoint do
  @moduledoc false
  defstruct [:hash, :index]
end

defmodule Exbitnode.Consensus.Tx.TxIn do
  @moduledoc false
  defstruct [:previous_output, :script_sig, :sequence]
end

defmodule Exbitnode.Consensus.Tx.TxOut do
  @moduledoc false
  defstruct [:value, :script_pubkey]
end

defmodule Exbitnode.Consensus.Tx.Transaction do
  @moduledoc false

  alias Exbitnode.Consensus.Tx.{OutPoint, TxIn}

  defstruct [:version, :inputs, :outputs, :lock_time, :witness]

  def coinbase?(%__MODULE__{
        inputs: [%TxIn{previous_output: %OutPoint{hash: hash, index: index}} | _]
      }) do
    zero_hash = :binary.copy(<<0>>, 32)
    hash == zero_hash and index == 0xFFFF_FFFF
  end

  def coinbase?(_), do: false
end
