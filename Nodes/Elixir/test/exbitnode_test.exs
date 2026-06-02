defmodule Exbitnode.Wire.MessageFramerTest do
  use ExUnit.Case, async: true

  alias Exbitnode.Chain.ChainRegistry
  alias Exbitnode.Wire.{MessageFramer, WireSerialize}

  test "build and parse message frame with checksum" do
    magic = ChainRegistry.get("testnet4").magic
    payload = WireSerialize.pack_int32_le(42)

    frame = MessageFramer.build_message(magic, "ping", payload)
    header = MessageFramer.parse_header(frame)

    assert header.magic == magic
    assert header.command == "ping"
    assert header.length == byte_size(payload)

    payload_out = binary_part(frame, MessageFramer.header_size(), header.length)
    assert MessageFramer.verify_checksum(payload_out, header.checksum)
  end

  test "checksum uses double sha256 first four bytes" do
    payload = <<1, 2, 3>>
    checksum = WireSerialize.message_checksum(payload)
    assert byte_size(checksum) == 4
    assert checksum == binary_part(WireSerialize.double_sha256(payload), 0, 4)
  end
end

defmodule Exbitnode.Chain.GenesisTest do
  use ExUnit.Case, async: true

  alias Exbitnode.Chain.Genesis
  alias Exbitnode.Messages.BlockHeaderCodec

  test "testnet4 genesis hash matches known value" do
    assert Genesis.testnet4_hash() == BlockHeaderCodec.block_hash_hex(Genesis.testnet4())
    assert String.length(Genesis.testnet4_hash()) == 64
  end
end

defmodule Exbitnode.Consensus.HeaderValidatorTest do
  use ExUnit.Case, async: true

  alias Exbitnode.Chain.Genesis
  alias Exbitnode.Consensus.HeaderValidator
  alias Exbitnode.Messages.BlockHeaderCodec

  test "genesis header validates against zero prev hash" do
    header = Genesis.testnet4()
    assert :ok = HeaderValidator.validate_header(header, <<0::256>>)
  end

  test "rejects prev hash mismatch" do
    header = Genesis.testnet4()

    assert_raise Exbitnode.Consensus.HeaderValidationError, "prev block hash mismatch", fn ->
      HeaderValidator.validate_header(header, <<1::256>>)
    end
  end

  test "pow target check uses header hash" do
    header = %{Genesis.testnet4() | nonce: 0}

    assert_raise Exbitnode.Consensus.HeaderValidationError, "header does not meet proof-of-work target", fn ->
      HeaderValidator.validate_header(header, <<0::256>>)
    end

    assert BlockHeaderCodec.block_hash(Genesis.testnet4()) != BlockHeaderCodec.block_hash(header)
  end
end

defmodule Exbitnode.Wire.WireSerializeTest do
  use ExUnit.Case, async: true

  alias Exbitnode.Wire.WireSerialize

  test "compact size roundtrip" do
    for value <- [0, 252, 253, 65535, 65536, 1_000_000] do
      encoded = WireSerialize.write_compact_size(value)
      {decoded, bytes_read} = WireSerialize.read_compact_size_at(encoded, 0)
      assert decoded == value
      assert bytes_read == byte_size(encoded)
    end
  end
end

defmodule Exbitnode.Db.DatabaseTest do
  use ExUnit.Case, async: false

  alias Exbitnode.Chain.Genesis
  alias Exbitnode.Db.{Database, ProjectTracker}

  setup do
    path = Path.join(System.tmp_dir!(), "exbitnode_test_#{:rand.uniform(1_000_000)}.db")
    on_exit(fn -> File.rm(path) end)
    {:ok, conn} = Database.open(path)
    on_exit(fn -> Database.close(conn) end)
    {:ok, conn: conn, path: path}
  end

  test "schema initializes and stores genesis", %{conn: conn} do
    ProjectTracker.ensure_genesis(conn, "testnet4", Genesis.testnet4(), Genesis.testnet4_hash())
    assert ProjectTracker.header_count(conn) == 1
    assert ProjectTracker.get_header_hash(conn, "testnet4", 0) == Genesis.testnet4_hash()
    state = ProjectTracker.get_sync_state(conn, "testnet4")
    assert state.best_height == 0
    assert state.sync_status == "starting"
  end
end

defmodule Exbitnode.Consensus.MerkleTest do
  use ExUnit.Case, async: true

  alias Exbitnode.Consensus.Merkle
  alias Exbitnode.Util.Hex

  test "single hash merkle root is identity" do
    hash = Hex.decode("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
    root = Merkle.compute_root([hash])
    assert Hex.encode(root) == Hex.encode(hash)
  end
end

defmodule Exbitnode.Consensus.BlockConnectTest do
  use ExUnit.Case, async: false

  alias Exbitnode.Chain.Genesis
  alias Exbitnode.Consensus.Block.BlockDeserializer
  alias Exbitnode.Consensus.Connect.BlockConnector
  alias Exbitnode.Consensus.Merkle
  alias Exbitnode.Db.{Database, ProjectTracker}
  alias Exbitnode.Messages.BlockHeaderCodec
  alias Exbitnode.Consensus.Tx.{OutPoint, Transaction, TxIn, TxOut, TransactionParser}
  alias Exbitnode.Util.Hex
  alias Exbitnode.Wire.WireSerialize

  setup do
    path = Path.join(System.tmp_dir!(), "exbitnode_connect_#{:rand.uniform(1_000_000)}.db")
    on_exit(fn -> File.rm(path) end)
    {:ok, conn} = Database.open(path)
    on_exit(fn -> Database.close(conn) end)
    ProjectTracker.ensure_genesis(conn, "testnet4", Genesis.testnet4(), Genesis.testnet4_hash())
    {:ok, conn: conn}
  end

  test "parses synthetic genesis-like block payload", %{conn: _conn} do
    coinbase = %Transaction{
      version: 1,
      inputs: [
        %TxIn{
          previous_output: %OutPoint{hash: :binary.copy(<<0>>, 32), index: 0xFFFF_FFFF},
          script_sig: <<4, 255, 255>>,
          sequence: 0xFFFF_FFFF
        }
      ],
      outputs: [%TxOut{value: 50_000_000_000, script_pubkey: <<>>}],
      lock_time: 0,
      witness: []
    }

    header = %{Genesis.testnet4() | merkle_root: Merkle.block_merkle_root([coinbase])}
    tx_bytes = TransactionParser.serialize(coinbase, false)
    payload = BlockHeaderCodec.serialize(header) <> WireSerialize.write_compact_size(1) <> tx_bytes
    block = BlockDeserializer.deserialize(payload)
    assert length(block.transactions) == 1
    assert Transaction.coinbase?(hd(block.transactions))
    assert block.header.merkle_root == Merkle.block_merkle_root(block.transactions)
  end

  test "connects genesis block from synthetic payload", %{conn: conn} do
    coinbase = %Transaction{
      version: 1,
      inputs: [
        %TxIn{
          previous_output: %OutPoint{hash: :binary.copy(<<0>>, 32), index: 0xFFFF_FFFF},
          script_sig: <<4, 255, 255>>,
          sequence: 0xFFFF_FFFF
        }
      ],
      outputs: [],
      lock_time: 0,
      witness: []
    }

    header = %{Genesis.testnet4() | merkle_root: Merkle.block_merkle_root([coinbase])}
    tx_bytes = TransactionParser.serialize(coinbase, false)
    payload = BlockHeaderCodec.serialize(header) <> WireSerialize.write_compact_size(1) <> tx_bytes

    result =
      BlockConnector.connect(
        conn,
        "testnet4",
        0,
        payload,
        :binary.copy(<<0>>, 32),
        BlockHeaderCodec.block_hash(header)
      )

    assert result.height == 0
    assert ProjectTracker.get_validated_height(conn, "testnet4") == 0
    assert ProjectTracker.block_count(conn, "testnet4") == 0
  end

  test "disconnect rewinds tip and removes block utxos", %{conn: conn} do
    connect_genesis!(conn)

    coinbase = %Transaction{
      version: 1,
      inputs: [
        %TxIn{
          previous_output: %OutPoint{hash: :binary.copy(<<0>>, 32), index: 0xFFFF_FFFF},
          script_sig: <<4, 1>>,
          sequence: 0xFFFF_FFFF
        }
      ],
      outputs: [%TxOut{value: 50_000_000_000, script_pubkey: <<0x51, 0x20>> <> :binary.copy(<<0>>, 32)}],
      lock_time: 0,
      witness: []
    }

    prev_internal = BlockHeaderCodec.block_hash(Genesis.testnet4())
    header1 = %{Genesis.testnet4() | prev_block: prev_internal, merkle_root: Merkle.block_merkle_root([coinbase])}
    hash1_internal = BlockHeaderCodec.block_hash(header1)
    tx_bytes = TransactionParser.serialize(coinbase, false)
    payload1 = BlockHeaderCodec.serialize(header1) <> WireSerialize.write_compact_size(1) <> tx_bytes

    BlockConnector.connect(conn, "testnet4", 1, payload1, prev_internal, hash1_internal)
    assert ProjectTracker.get_validated_height(conn, "testnet4") == 1
    assert ProjectTracker.utxo_count(conn, "testnet4") == 1

    :ok = BlockConnector.disconnect(conn, "testnet4", 1)
    assert ProjectTracker.get_validated_height(conn, "testnet4") == 0
    assert ProjectTracker.utxo_count(conn, "testnet4") == 0
  end

  test "disconnect restores externally spent utxo and reconnect block", %{conn: conn} do
    connect_genesis!(conn)

    coinbase = %Transaction{
      version: 1,
      inputs: [
        %TxIn{
          previous_output: %OutPoint{hash: :binary.copy(<<0>>, 32), index: 0xFFFF_FFFF},
          script_sig: <<4, 1>>,
          sequence: 0xFFFF_FFFF
        }
      ],
      outputs: [%TxOut{value: 50_000_000_000, script_pubkey: <<0x51, 0x20>> <> :binary.copy(<<0>>, 32)}],
      lock_time: 0,
      witness: []
    }

    prev_internal = BlockHeaderCodec.block_hash(Genesis.testnet4())
    header1 = %{Genesis.testnet4() | prev_block: prev_internal, merkle_root: Merkle.block_merkle_root([coinbase])}
    hash1_internal = BlockHeaderCodec.block_hash(header1)
    hash1_hex = hash1_internal |> Hex.reverse() |> Hex.encode()

    tx_bytes = TransactionParser.serialize(coinbase, false)
    payload1 = BlockHeaderCodec.serialize(header1) <> WireSerialize.write_compact_size(1) <> tx_bytes

    ProjectTracker.insert_header(conn, "testnet4", 1, hash1_hex, Genesis.testnet4_hash(), "")
    BlockConnector.connect(conn, "testnet4", 1, payload1, prev_internal, hash1_internal)

    coinbase_txid = Merkle.transaction_txid(coinbase) |> Hex.reverse() |> Hex.encode()
    utxos_after_1 = snapshot_utxos(conn)

    coinbase2 = %Transaction{
      version: 1,
      inputs: [
        %TxIn{
          previous_output: %OutPoint{hash: :binary.copy(<<0>>, 32), index: 0xFFFF_FFFF},
          script_sig: <<4, 2>>,
          sequence: 0xFFFF_FFFF
        }
      ],
      outputs: [],
      lock_time: 0,
      witness: []
    }

    header2 = %{header1 | prev_block: hash1_internal, merkle_root: Merkle.block_merkle_root([coinbase2])}
    hash2_internal = BlockHeaderCodec.block_hash(header2)
    hash2_hex = hash2_internal |> Hex.reverse() |> Hex.encode()
    payload2 = BlockHeaderCodec.serialize(header2) <> WireSerialize.write_compact_size(1) <> TransactionParser.serialize(coinbase2, false)

    ProjectTracker.insert_header(conn, "testnet4", 2, hash2_hex, hash1_hex, "")
    BlockConnector.connect(conn, "testnet4", 2, payload2, hash1_internal, hash2_internal)
    snapshot_after_two = snapshot_utxos(conn)

    assert ProjectTracker.get_validated_height(conn, "testnet4") == 2
    :ok = BlockConnector.disconnect(conn, "testnet4", 2)

    assert ProjectTracker.get_validated_height(conn, "testnet4") == 1
    assert snapshot_utxos(conn) == utxos_after_1
    assert ProjectTracker.get_utxo(conn, "testnet4", coinbase_txid, 0) != nil

    BlockConnector.connect(conn, "testnet4", 2, payload2, hash1_internal, hash2_internal)
    assert ProjectTracker.get_validated_height(conn, "testnet4") == 2
    assert snapshot_utxos(conn) == snapshot_after_two
  end

  defp connect_genesis!(conn) do
    coinbase = %Transaction{
      version: 1,
      inputs: [
        %TxIn{
          previous_output: %OutPoint{hash: :binary.copy(<<0>>, 32), index: 0xFFFF_FFFF},
          script_sig: <<4, 255, 255>>,
          sequence: 0xFFFF_FFFF
        }
      ],
      outputs: [],
      lock_time: 0,
      witness: []
    }

    header = %{Genesis.testnet4() | merkle_root: Merkle.block_merkle_root([coinbase])}
    tx_bytes = TransactionParser.serialize(coinbase, false)
    payload = BlockHeaderCodec.serialize(header) <> WireSerialize.write_compact_size(1) <> tx_bytes

    BlockConnector.connect(
      conn,
      "testnet4",
      0,
      payload,
      :binary.copy(<<0>>, 32),
      BlockHeaderCodec.block_hash(header)
    )
  end

  defp snapshot_utxos(conn) do
    Exbitnode.Db.Sql.query_all(
      conn,
      "SELECT txid, vout, height, value_sats FROM utxos WHERE chain = 'testnet4' ORDER BY txid, vout",
      []
    )
    |> Enum.sort()
  end
end

defmodule Exbitnode.Consensus.ScriptVerifyTest do
  use ExUnit.Case, async: true

  alias Exbitnode.Consensus.Script.ScriptVerify
  alias Exbitnode.Consensus.Tx.TransactionParser
  alias Exbitnode.Util.Hex

  @block739_fixture Path.join([__DIR__, "fixtures", "block739_tx.hex"])
  @block739_prev_spk "0014a54e2a1ec06389203887661535ed118b7d053889"
  @block6975_fixture Path.join([__DIR__, "fixtures", "block6975_tx.hex"])
  @block6975_prev_spk "512096519126915cde17e68250819b504b3fda380b8d98e3540a3f2baa3b011eb29c"

  test "real testnet4 block739 P2WPKH input0 accepted" do
    tx_hex = File.read!(@block739_fixture) |> String.trim()
    {tx, _} = TransactionParser.parse(Hex.decode(tx_hex))
    prev_spk = Hex.decode(@block739_prev_spk)

    assert :ok = ScriptVerify.verify_transaction_input(tx, 0, prev_spk, 5_000_000_000)
  end

  test "real testnet4 block6975 P2TR key-path input0 accepted" do
    tx_hex = File.read!(@block6975_fixture) |> String.trim()
    {tx, _} = TransactionParser.parse(Hex.decode(tx_hex))
    prev_spk = Hex.decode(@block6975_prev_spk)
    spent_prevouts = [{64_300_000_000, prev_spk}]

    assert :ok =
             ScriptVerify.verify_transaction_input(tx, 0, prev_spk, 64_300_000_000, spent_prevouts)
  end
end

defmodule Exbitnode.Util.CryptoUtilTest do
  use ExUnit.Case, async: true

  alias Exbitnode.Util.{CryptoUtil, Hex}

  test "hash160 uses sha256 then ripemd160" do
    data = Hex.decode("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
    assert byte_size(CryptoUtil.hash160(data)) == 20
    assert CryptoUtil.hash160(data) != :crypto.hash(:sha256, data)
  end
end

defmodule Exbitnode.Db.ProjectTrackerTest do
  use ExUnit.Case, async: false

  alias Exbitnode.Chain.Genesis
  alias Exbitnode.Db.{Database, ProjectTracker, Sql}

  setup do
    path = Path.join(System.tmp_dir!(), "exbitnode_tracker_#{:rand.uniform(1_000_000)}.db")
    on_exit(fn -> File.rm(path) end)
    {:ok, conn} = Database.open(path)
    on_exit(fn -> Database.close(conn) end)
    {:ok, conn: conn}
  end

  test "ensure_genesis preserves existing header tip", %{conn: conn} do
    ProjectTracker.ensure_genesis(conn, "testnet4", Genesis.testnet4(), Genesis.testnet4_hash())

    ProjectTracker.upsert_sync_state(conn, "testnet4", %{
      best_height: 739,
      best_hash: "000000004cfba4fe6174c546086df7fb52b3d65d44788c0ee8acf436dd28de32",
      header_count: 740,
      sync_status: "headers_current"
    })

    ProjectTracker.ensure_genesis(conn, "testnet4", Genesis.testnet4(), Genesis.testnet4_hash())
    state = ProjectTracker.get_sync_state(conn, "testnet4")
    assert state.best_height == 739
    assert state.sync_status == "headers_current"
  end

  test "replace_utxo_undo stores external spend rows", %{conn: conn} do
    ProjectTracker.ensure_genesis(conn, "testnet4", Genesis.testnet4(), Genesis.testnet4_hash())

    entries = [
      %{
        txid: "abc123",
        vout: 0,
        utxo_height: 50,
        value_sats: 1_000,
        script_pubkey_hex: "0014" <> String.duplicate("00", 20),
        coinbase: false
      }
    ]

    :ok = ProjectTracker.replace_utxo_undo(conn, "testnet4", 101, entries)

    assert ["abc123", 0, 1_000, 50] =
             Sql.query_one(
               conn,
               "SELECT txid, vout, value_sats, utxo_height FROM utxo_undo WHERE chain = ?1 AND height = ?2",
               ["testnet4", 101]
             )
  end

  test "take_utxo_undo returns and clears journal rows", %{conn: conn} do
    ProjectTracker.ensure_genesis(conn, "testnet4", Genesis.testnet4(), Genesis.testnet4_hash())

    entries = [
      %{
        txid: "deadbeef",
        vout: 1,
        utxo_height: 42,
        value_sats: 9_000,
        script_pubkey_hex: "76a9" <> String.duplicate("00", 20) <> "88ac",
        coinbase: false
      }
    ]

    :ok = ProjectTracker.replace_utxo_undo(conn, "testnet4", 7, entries)
    assert ProjectTracker.take_utxo_undo(conn, "testnet4", 7) == entries
    assert [] = Sql.query_all(conn, "SELECT 1 FROM utxo_undo WHERE chain = ?1 AND height = ?2", ["testnet4", 7])
  end
end
