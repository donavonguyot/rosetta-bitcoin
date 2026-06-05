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

    assert_raise Exbitnode.Consensus.HeaderValidationError,
                 "header does not meet proof-of-work target",
                 fn ->
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

defmodule Exbitnode.Db.ChainstateSessionTest do
  use ExUnit.Case, async: false

  alias Exbitnode.Chain.Genesis
  alias Exbitnode.Db.ChainstateSession
  alias Exbitnode.Chainstate.Tracker, as: ChainstateTracker
  alias Exbitnode.Messages.BlockHeaderCodec

  setup do
    path = Path.join(System.tmp_dir!(), "exbitnode_test_#{:rand.uniform(1_000_000)}")
    on_exit(fn -> File.rm_rf(path) end)
    {:ok, conn} = ChainstateSession.open_native(path, "testnet4")
    on_exit(fn -> ChainstateSession.close(conn) end)
    {:ok, conn: conn, path: path}
  end

  test "native chainstate initializes and stores genesis", %{conn: conn, path: path} do
    ChainstateTracker.ensure_genesis(
      conn,
      "testnet4",
      Genesis.testnet4(),
      Genesis.testnet4_hash()
    )

    assert ChainstateTracker.header_count(conn, "testnet4") == 1
    assert ChainstateTracker.get_header_hash(conn, "testnet4", 0) == Genesis.testnet4_hash()
    state = ChainstateTracker.get_sync_state(conn, "testnet4")
    assert state.best_height == 0
    assert state.sync_status == "starting"
    refute File.exists?(Path.join(path, "exbitnode.db"))
    assert File.exists?(Path.join(path, "chainstate-rocksdb/.exbitnode_storage_native"))
    refute File.exists?(Path.join(path, "chainstate-rocksdb/chainstate.term"))
  end

  test "native chainstate persists through restart" do
    path = Path.join(System.tmp_dir!(), "exbitnode_restart_#{:rand.uniform(1_000_000)}")
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, conn} = ChainstateSession.open_native(path, "testnet4")

    ChainstateTracker.ensure_genesis(
      conn,
      "testnet4",
      Genesis.testnet4(),
      Genesis.testnet4_hash()
    )

    ChainstateSession.close(conn)

    {:ok, restarted} = ChainstateSession.open_native(path, "testnet4")
    on_exit(fn -> ChainstateSession.close(restarted) end)

    assert ChainstateTracker.header_count(restarted, "testnet4") == 1
    assert ChainstateTracker.get_header_hash(restarted, "testnet4", 0) == Genesis.testnet4_hash()
    assert ChainstateSession.metadata(restarted)["backend_name"] == "rocksdb"
  end

  test "batch header commit maintains count, hash index, and sync state through restart" do
    path = Path.join(System.tmp_dir!(), "exbitnode_header_batch_#{:rand.uniform(1_000_000)}")
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, conn} = ChainstateSession.open_native(path, "testnet4")

    ChainstateTracker.ensure_genesis(
      conn,
      "testnet4",
      Genesis.testnet4(),
      Genesis.testnet4_hash()
    )

    header = %{Genesis.testnet4() | nonce: 1}
    hash = BlockHeaderCodec.block_hash_hex(header)
    serialized = header |> BlockHeaderCodec.serialize() |> Exbitnode.Util.Hex.encode()

    result =
      ChainstateTracker.commit_headers(
        conn,
        "testnet4",
        [%{height: 1, block_hash: hash, serialized_hex: serialized}],
        %{best_height: 1, best_hash: hash, sync_status: "headers_syncing"}
      )

    assert result.stored == 1
    assert ChainstateTracker.header_count(conn, "testnet4") == 2
    assert ChainstateTracker.get_header_hash(conn, "testnet4", 1) == hash
    assert ChainstateTracker.get_sync_state(conn, "testnet4").best_height == 1

    ChainstateSession.close(conn)

    {:ok, restarted} = ChainstateSession.open_native(path, "testnet4")
    on_exit(fn -> ChainstateSession.close(restarted) end)

    assert ChainstateTracker.header_count(restarted, "testnet4") == 2
    assert ChainstateTracker.get_header_hash(restarted, "testnet4", 1) == hash
  end

  test "forbidden local DB artifacts fail closed" do
    path = Path.join(System.tmp_dir!(), "exbitnode_forbidden_db_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)

    File.write!(Path.join(path, "exbitnode.db"), "")

    assert_raise ArgumentError, ~r/refuses local DB artifacts/, fn ->
      ChainstateSession.open_native(path, "testnet4")
    end

    {status, code} = Exbitnode.CLI.NodeStatus.status_result(path, "testnet4", "127.0.0.1:48333")
    assert code == 1
    assert status.chainstate_status == "misaligned"
    assert status.sync_status == "error"
    assert status.binary_gate_status == "failed"
    assert status.last_error =~ "forbidden local DB artifacts"
  end
end

defmodule Exbitnode.RuntimeStatusTest do
  use ExUnit.Case, async: false

  alias Exbitnode.CLI.NodeStatus
  alias Exbitnode.RuntimeStatus
  alias Exbitnode.Storage.DatadirLock

  setup do
    path = Path.join(System.tmp_dir!(), "exbitnode_runtime_status_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(Path.join(path, "chainstate-rocksdb"))
    on_exit(fn -> File.rm_rf(path) end)
    {:ok, path: path}
  end

  test "status snapshot writes atomically and reads back required fields", %{path: path} do
    :ok =
      RuntimeStatus.write_snapshot(path, %{
        runtime_surface: "docker_supervisor",
        peer_source: "host.docker.internal:48333",
        validated_height: 7,
        validated_hash: "aa",
        header_height: 9,
        header_hash: "bb",
        stored_block_height: 7,
        stored_block_hash: "cc",
        block_count: 8,
        utxo_count: 11,
        sync_status: "blocks_syncing",
        current_blocker: nil,
        last_error: nil
      })

    assert {:ok, snapshot} = RuntimeStatus.read_snapshot(path)
    assert snapshot["runtime_surface"] == "docker_supervisor"
    assert snapshot["peer_source"] == "host.docker.internal:48333"
    assert snapshot["validated_height"] == 7
    assert snapshot["header_height"] == 9
    assert snapshot["sync_status"] == "blocks_syncing"
    assert is_binary(snapshot["updated_at"])
  end

  test "node status reads snapshot when datadir lock is held", %{path: path} do
    :ok =
      RuntimeStatus.write_snapshot(path, %{
        runtime_surface: "docker_supervisor",
        peer_source: "host.docker.internal:48333",
        validated_height: 100,
        validated_hash: "valid-hash",
        header_height: 120,
        header_hash: "header-hash",
        stored_block_height: 100,
        stored_block_hash: "stored-hash",
        block_count: 101,
        utxo_count: 22,
        sync_status: "blocks_syncing"
      })

    {:ok, lock} = DatadirLock.acquire(path)

    try do
      {status, code} = NodeStatus.status_result(path, "testnet4", "fallback-peer")

      assert code == 0
      assert status.runtime_status == "running"
      assert status.sync_status == "blocks_syncing"
      assert status.lock_status == "held"
      assert status.validated_height == 100
      assert status.header_height == 120
      assert status.stored_block_height == 100
      assert status.peer_source == "host.docker.internal:48333"
      assert status.recommendation == "leave_running"
    after
      DatadirLock.release(lock)
    end
  end

  test "node status returns valid JSON fields when locked before first snapshot", %{path: path} do
    {:ok, lock} = DatadirLock.acquire(path)

    try do
      {status, code} = NodeStatus.status_result(path, "testnet4", "fallback-peer")

      assert code == 0
      assert status.runtime_status == "running"
      assert status.sync_status == "running"
      assert status.lock_status == "held"
      assert status.validated_height == -1
      assert status.header_height == -1
      assert status.recommendation == "wait_for_status_snapshot"
      assert status.peer_source == "fallback-peer"
    after
      DatadirLock.release(lock)
    end
  end

  test "supervisor tick field helper includes monitoring contract fields" do
    tick =
      RuntimeStatus.required_tick_fields(
        %{
          "runtime_surface" => "docker_supervisor",
          "peer_source" => "host.docker.internal:48333",
          "validated_height" => 10,
          "header_height" => 12,
          "stored_block_height" => 10,
          "sync_status" => "blocks_syncing",
          "current_blocker" => nil
        },
        "syncing",
        true,
        7
      )

    assert tick.phase == "syncing"
    assert tick.runtime_surface == "docker_supervisor"
    assert tick.peer == "host.docker.internal:48333"
    assert tick.validated_height == 10
    assert tick.header_height == 12
    assert tick.stored_block_height == 10
    assert tick.delta_since_last == 3
    assert tick.process_running == true
    assert Map.has_key?(tick, :current_blocker)
  end
end

defmodule Exbitnode.RuntimeNoLocalDbStoreGuardTest do
  use ExUnit.Case, async: true

  test "runtime code does not reintroduce local database store dependencies" do
    forbidden =
      ~r/(legacy_sqlite_path|reject_sqlite_artifacts|sqlite_artifacts_absent|Ecto\.Adapters\.SQLite|:sqlite|SQLite3|sqlite_ecto|Sqlite|SQLite)/

    files = Path.wildcard("lib/**/*.ex")

    offenders =
      files
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, number} ->
          if line =~ forbidden, do: ["#{file}:#{number}:#{line}"], else: []
        end)
      end)

    assert offenders == []
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
  alias Exbitnode.Db.ChainstateSession
  alias Exbitnode.Chainstate.Tracker, as: ChainstateTracker
  alias Exbitnode.Messages.BlockHeaderCodec
  alias Exbitnode.Consensus.Tx.{OutPoint, Transaction, TxIn, TxOut, TransactionParser}
  alias Exbitnode.Util.Hex
  alias Exbitnode.Wire.WireSerialize

  setup do
    path = Path.join(System.tmp_dir!(), "exbitnode_connect_#{:rand.uniform(1_000_000)}")
    on_exit(fn -> File.rm_rf(path) end)
    {:ok, conn} = ChainstateSession.open_native(path, "testnet4")
    on_exit(fn -> ChainstateSession.close(conn) end)

    ChainstateTracker.ensure_genesis(
      conn,
      "testnet4",
      Genesis.testnet4(),
      Genesis.testnet4_hash()
    )

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

    payload =
      BlockHeaderCodec.serialize(header) <> WireSerialize.write_compact_size(1) <> tx_bytes

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

    payload =
      BlockHeaderCodec.serialize(header) <> WireSerialize.write_compact_size(1) <> tx_bytes

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
    assert is_integer(result.timing.utxo_load)
    assert is_integer(result.timing.block_connect_store_commit)
    assert result.timing.block_connect_store_commit >= result.timing.commit
    assert ChainstateTracker.get_validated_height(conn, "testnet4") == 0
    assert ChainstateTracker.utxo_count(conn, "testnet4") == 0
    assert ChainstateTracker.block_count(conn, "testnet4") == 1

    assert ChainstateTracker.get_header_hash(conn, "testnet4", 0) ==
             BlockHeaderCodec.block_hash_hex(header)

    assert ChainstateTracker.max_stored_block(conn, "testnet4").block_hash ==
             BlockHeaderCodec.block_hash_hex(header)
  end

  test "connect skips core unspendable outputs", %{conn: conn} do
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
      outputs: [
        %TxOut{value: 1, script_pubkey: <<>>},
        %TxOut{value: 2, script_pubkey: <<0x6A, 0x01, 0x02>>},
        %TxOut{value: 3, script_pubkey: <<0x51>>}
      ],
      lock_time: 0,
      witness: []
    }

    prev_internal = BlockHeaderCodec.block_hash(Genesis.testnet4())

    header1 = %{
      Genesis.testnet4()
      | prev_block: prev_internal,
        merkle_root: Merkle.block_merkle_root([coinbase])
    }

    hash1_internal = BlockHeaderCodec.block_hash(header1)
    tx_bytes = TransactionParser.serialize(coinbase, false)

    payload1 =
      BlockHeaderCodec.serialize(header1) <> WireSerialize.write_compact_size(1) <> tx_bytes

    result = BlockConnector.connect(conn, "testnet4", 1, payload1, prev_internal, hash1_internal)

    assert result.utxos_created == 1
    assert ChainstateTracker.utxo_count(conn, "testnet4") == 1
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
      outputs: [
        %TxOut{value: 50_000_000_000, script_pubkey: <<0x51, 0x20>> <> :binary.copy(<<0>>, 32)}
      ],
      lock_time: 0,
      witness: []
    }

    prev_internal = BlockHeaderCodec.block_hash(Genesis.testnet4())

    header1 = %{
      Genesis.testnet4()
      | prev_block: prev_internal,
        merkle_root: Merkle.block_merkle_root([coinbase])
    }

    hash1_internal = BlockHeaderCodec.block_hash(header1)
    tx_bytes = TransactionParser.serialize(coinbase, false)

    payload1 =
      BlockHeaderCodec.serialize(header1) <> WireSerialize.write_compact_size(1) <> tx_bytes

    BlockConnector.connect(conn, "testnet4", 1, payload1, prev_internal, hash1_internal)
    assert ChainstateTracker.get_validated_height(conn, "testnet4") == 1
    assert ChainstateTracker.utxo_count(conn, "testnet4") == 1

    :ok = BlockConnector.disconnect(conn, "testnet4", 1)
    assert ChainstateTracker.get_validated_height(conn, "testnet4") == 0
    assert ChainstateTracker.utxo_count(conn, "testnet4") == 0
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
      outputs: [
        %TxOut{value: 50_000_000_000, script_pubkey: <<0x51, 0x20>> <> :binary.copy(<<0>>, 32)}
      ],
      lock_time: 0,
      witness: []
    }

    prev_internal = BlockHeaderCodec.block_hash(Genesis.testnet4())

    header1 = %{
      Genesis.testnet4()
      | prev_block: prev_internal,
        merkle_root: Merkle.block_merkle_root([coinbase])
    }

    hash1_internal = BlockHeaderCodec.block_hash(header1)
    hash1_hex = hash1_internal |> Hex.reverse() |> Hex.encode()

    tx_bytes = TransactionParser.serialize(coinbase, false)

    payload1 =
      BlockHeaderCodec.serialize(header1) <> WireSerialize.write_compact_size(1) <> tx_bytes

    ChainstateTracker.insert_header(conn, "testnet4", 1, hash1_hex, Genesis.testnet4_hash(), "")
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

    header2 = %{
      header1
      | prev_block: hash1_internal,
        merkle_root: Merkle.block_merkle_root([coinbase2])
    }

    hash2_internal = BlockHeaderCodec.block_hash(header2)
    hash2_hex = hash2_internal |> Hex.reverse() |> Hex.encode()

    payload2 =
      BlockHeaderCodec.serialize(header2) <>
        WireSerialize.write_compact_size(1) <> TransactionParser.serialize(coinbase2, false)

    ChainstateTracker.insert_header(conn, "testnet4", 2, hash2_hex, hash1_hex, "")
    BlockConnector.connect(conn, "testnet4", 2, payload2, hash1_internal, hash2_internal)
    snapshot_after_two = snapshot_utxos(conn)

    assert ChainstateTracker.get_validated_height(conn, "testnet4") == 2
    :ok = BlockConnector.disconnect(conn, "testnet4", 2)

    assert ChainstateTracker.get_validated_height(conn, "testnet4") == 1
    assert snapshot_utxos(conn) == utxos_after_1
    assert ChainstateTracker.get_utxo(conn, "testnet4", coinbase_txid, 0) != nil

    BlockConnector.connect(conn, "testnet4", 2, payload2, hash1_internal, hash2_internal)
    assert ChainstateTracker.get_validated_height(conn, "testnet4") == 2
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

    payload =
      BlockHeaderCodec.serialize(header) <> WireSerialize.write_compact_size(1) <> tx_bytes

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
    ChainstateTracker.utxo_snapshot(conn, "testnet4")
  end
end

defmodule Exbitnode.Consensus.ScriptVerifyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Exbitnode.CLI.ScriptCorpus
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
             ScriptVerify.verify_transaction_input(
               tx,
               0,
               prev_spk,
               64_300_000_000,
               spent_prevouts
             )
  end

  test "script corpus fixture filter uses prev_spk fallback when prevouts are absent" do
    result_path =
      Path.join(
        System.tmp_dir!(),
        "elixir_script_corpus_fixture_#{:rand.uniform(1_000_000)}.json"
      )

    on_exit(fn -> File.rm(result_path) end)

    manifest =
      Path.expand("../Shared/conformance/fixtures/scripts/manifest.json", File.cwd!())

    code =
      capture_io(fn ->
        ScriptCorpus.run([
          "--manifest",
          manifest,
          "--fixture",
          "scripts.p2sh_116040",
          "--stop-on-failure",
          "--result-path",
          result_path
        ])
      end)

    assert code =~ "\"passed\": 1"

    result = result_path |> File.read!() |> Jason.decode!()
    assert result["fixture_count"] == 1
    assert result["passed"] == 1
    assert result["failed"] == 0
    assert hd(result["results"])["fixture_id"] == "scripts.p2sh_116040"
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

defmodule Exbitnode.Consensus.ScriptVerifyRunnerTest do
  use ExUnit.Case, async: false

  alias Exbitnode.Consensus.Script.ScriptVerifyRunner

  setup do
    old_parallel = System.get_env("PAR_SCRIPT_VERIFY")
    old_min = System.get_env("PAR_SCRIPT_MIN_INPUTS")
    old_threads = System.get_env("PAR_SCRIPT_THREADS")
    old_timeout = System.get_env("SCRIPT_VERIFY_TIMEOUT_MS")

    System.put_env("PAR_SCRIPT_VERIFY", "1")
    System.put_env("PAR_SCRIPT_MIN_INPUTS", "1")
    System.put_env("PAR_SCRIPT_THREADS", "2")
    System.put_env("SCRIPT_VERIFY_TIMEOUT_MS", "300000")

    on_exit(fn ->
      restore_env("PAR_SCRIPT_VERIFY", old_parallel)
      restore_env("PAR_SCRIPT_MIN_INPUTS", old_min)
      restore_env("PAR_SCRIPT_THREADS", old_threads)
      restore_env("SCRIPT_VERIFY_TIMEOUT_MS", old_timeout)
    end)

    :ok
  end

  test "parallel verification reports deterministic lowest input failure" do
    jobs = [%{input_index: 2}, %{input_index: 1}, %{input_index: 0}]

    assert_raise RuntimeError, "input zero failed", fn ->
      ScriptVerifyRunner.run(jobs, fn
        %{input_index: 0} -> raise "input zero failed"
        %{input_index: 1} -> raise "input one failed"
        _job -> :ok
      end)
    end
  end

  test "parallel verification timeout reports task exit instead of spinning forever" do
    System.put_env("SCRIPT_VERIFY_TIMEOUT_MS", "1")

    assert_raise RuntimeError, ~r/script verification task exited/, fn ->
      ScriptVerifyRunner.run([%{input_index: 0}], fn _job ->
        Process.sleep(50)
        :ok
      end)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end

defmodule Exbitnode.Chainstate.TrackerTest do
  use ExUnit.Case, async: false

  alias Exbitnode.Chain.Genesis
  alias Exbitnode.Db.ChainstateSession
  alias Exbitnode.Chainstate.Tracker, as: ChainstateTracker

  setup do
    path = Path.join(System.tmp_dir!(), "exbitnode_tracker_#{:rand.uniform(1_000_000)}")
    on_exit(fn -> File.rm_rf(path) end)
    {:ok, conn} = ChainstateSession.open_native(path, "testnet4")
    on_exit(fn -> ChainstateSession.close(conn) end)
    {:ok, conn: conn}
  end

  test "ensure_genesis preserves existing header tip", %{conn: conn} do
    ChainstateTracker.ensure_genesis(
      conn,
      "testnet4",
      Genesis.testnet4(),
      Genesis.testnet4_hash()
    )

    ChainstateTracker.upsert_sync_state(conn, "testnet4", %{
      best_height: 739,
      best_hash: "000000004cfba4fe6174c546086df7fb52b3d65d44788c0ee8acf436dd28de32",
      header_count: 740,
      sync_status: "headers_current"
    })

    ChainstateTracker.ensure_genesis(
      conn,
      "testnet4",
      Genesis.testnet4(),
      Genesis.testnet4_hash()
    )

    state = ChainstateTracker.get_sync_state(conn, "testnet4")
    assert state.best_height == 739
    assert state.sync_status == "headers_current"
  end

  test "replace_utxo_undo stores external spend rows", %{conn: conn} do
    ChainstateTracker.ensure_genesis(
      conn,
      "testnet4",
      Genesis.testnet4(),
      Genesis.testnet4_hash()
    )

    entries = [
      %{
        txid: "abc123" <> String.duplicate("00", 29),
        vout: 0,
        utxo_height: 50,
        value_sats: 1_000,
        script_pubkey_hex: "0014" <> String.duplicate("00", 20),
        coinbase: false
      }
    ]

    :ok = ChainstateTracker.replace_utxo_undo(conn, "testnet4", 101, entries)

    assert ChainstateTracker.take_utxo_undo(conn, "testnet4", 101) == entries
  end

  test "take_utxo_undo returns and clears journal rows", %{conn: conn} do
    ChainstateTracker.ensure_genesis(
      conn,
      "testnet4",
      Genesis.testnet4(),
      Genesis.testnet4_hash()
    )

    entries = [
      %{
        txid: "deadbeef" <> String.duplicate("00", 28),
        vout: 1,
        utxo_height: 42,
        value_sats: 9_000,
        script_pubkey_hex: "76a9" <> String.duplicate("00", 20) <> "88ac",
        coinbase: false
      }
    ]

    :ok = ChainstateTracker.replace_utxo_undo(conn, "testnet4", 7, entries)
    assert ChainstateTracker.take_utxo_undo(conn, "testnet4", 7) == entries
    assert [] = ChainstateTracker.take_utxo_undo(conn, "testnet4", 7)
  end

  test "commit_block batches block index, utxos, undo, and tip", %{conn: conn} do
    spent_txid = "11" <> String.duplicate("00", 31)
    created_txid = "22" <> String.duplicate("00", 31)
    block_hash = "33" <> String.duplicate("00", 31)

    :ok =
      ChainstateTracker.insert_utxo(conn, "testnet4", %{
        txid: spent_txid,
        vout: 0,
        height: 10,
        value_sats: 1_000,
        script_pubkey_hex: "51",
        coinbase: false
      })

    assert ChainstateTracker.utxo_count(conn, "testnet4") == 1

    missing_txid = "44" <> String.duplicate("00", 31)

    assert [%{txid: ^spent_txid}, nil] =
             ChainstateTracker.get_utxos(conn, "testnet4", [
               {spent_txid, 0},
               {missing_txid, 0}
             ])

    undo = [
      %{
        txid: spent_txid,
        vout: 0,
        utxo_height: 10,
        value_sats: 1_000,
        script_pubkey_hex: "51",
        coinbase: false
      }
    ]

    :ok =
      ChainstateTracker.commit_block(conn, "testnet4", %{
        height: 11,
        block_hash: block_hash,
        stored: %{file_number: 0, file_offset: 80, block_size: 120},
        spent: [{spent_txid, 0}],
        created: [
          %{
            txid: created_txid,
            vout: 1,
            height: 11,
            value_sats: 900,
            script_pubkey_hex: "51",
            coinbase: false
          }
        ],
        undo: undo
      })

    assert ChainstateTracker.get_validated_height(conn, "testnet4") == 11
    assert ChainstateTracker.get_validated_hash(conn, "testnet4") == block_hash
    assert ChainstateTracker.block_count(conn, "testnet4") == 12
    assert ChainstateTracker.utxo_count(conn, "testnet4") == 1
    assert ChainstateTracker.max_stored_block(conn, "testnet4").height == 11
    assert ChainstateTracker.get_utxo(conn, "testnet4", spent_txid, 0) == nil
    assert ChainstateTracker.get_utxo(conn, "testnet4", created_txid, 1).value_sats == 900
    assert ChainstateTracker.take_utxo_undo(conn, "testnet4", 11) == undo
  end
end
