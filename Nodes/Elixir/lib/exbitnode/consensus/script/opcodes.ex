defmodule Exbitnode.Consensus.Script.Opcodes do
  @moduledoc false

  def op_0, do: 0x00
  def op_1, do: 0x51
  def op_16, do: 0x60
  def op_1negate, do: 0x4F
  def op_pushdata1, do: 0x4C
  def op_pushdata2, do: 0x4D
  def op_pushdata4, do: 0x4E
  def op_dup, do: 0x76
  def op_equal, do: 0x87
  def op_equalverify, do: 0x88
  def op_checksig, do: 0xAC
  def op_checksigverify, do: 0xAD
  def op_hash160, do: 0xA9
end
