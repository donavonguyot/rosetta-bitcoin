defmodule Exbitnode.Consensus.Script.ScriptTemplates do
  @moduledoc false

  alias Exbitnode.Consensus.Script.Opcodes

  def is_p2pk?(script) when is_binary(script) do
    (byte_size(script) == 35 and :binary.at(script, 0) == 0x21 and
       :binary.at(script, byte_size(script) - 1) == Opcodes.op_checksig()) or
      (byte_size(script) == 67 and :binary.at(script, 0) == 0x41 and
         :binary.at(script, byte_size(script) - 1) == Opcodes.op_checksig())
  end

  def is_p2pkh?(script) when is_binary(script) do
    byte_size(script) == 25 and
      match?(
        <<0x76, 0xA9, 0x14, _::binary-size(20), 0x88, 0xAC>>,
        script
      )
  end

  def is_p2wpkh?(script) when is_binary(script) do
    byte_size(script) == 22 and match?(<<0x00, 0x14, _::binary-size(20)>>, script)
  end

  def is_p2wsh?(script) when is_binary(script) do
    byte_size(script) == 34 and match?(<<0x00, 0x20, _::binary-size(32)>>, script)
  end

  def is_p2sh?(script) when is_binary(script) do
    byte_size(script) == 23 and match?(<<0xA9, 0x14, _::binary-size(20), 0x87>>, script)
  end

  def is_p2tr?(script) when is_binary(script) do
    byte_size(script) == 34 and match?(<<0x51, 0x20, _::binary-size(32)>>, script)
  end

  def is_bare_op_n?(script) when is_binary(script) do
    byte_size(script) == 1 and :binary.at(script, 0) >= Opcodes.op_1() and
      :binary.at(script, 0) <= Opcodes.op_16()
  end

  def describe(script) when is_binary(script) do
    cond do
      is_p2pk?(script) -> "P2PK"
      is_p2pkh?(script) -> "P2PKH"
      is_p2wpkh?(script) -> "P2WPKH"
      is_p2wsh?(script) -> "P2WSH"
      is_p2sh?(script) -> "P2SH"
      is_p2tr?(script) -> "P2TR"
      is_bare_op_n?(script) -> "bare_op_n"
      true -> "unknown"
    end
  end
end
