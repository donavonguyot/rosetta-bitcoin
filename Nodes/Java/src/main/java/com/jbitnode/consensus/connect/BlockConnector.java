package com.jbitnode.consensus.connect;

import com.jbitnode.config.ScriptVerifySettings;
import com.jbitnode.consensus.ConsensusConstants;
import com.jbitnode.consensus.block.Block;
import com.jbitnode.consensus.merkle.Merkle;
import com.jbitnode.consensus.script.SighashCache;
import com.jbitnode.consensus.script.ScriptVerify;
import com.jbitnode.consensus.script.ScriptVerifyRunner;
import com.jbitnode.consensus.tx.OutPoint;
import com.jbitnode.consensus.tx.Transaction;
import com.jbitnode.consensus.tx.TxIn;
import com.jbitnode.consensus.tx.TxOut;
import com.jbitnode.db.ChainstateBlockCommit;
import com.jbitnode.db.ChainstateCommitResult;
import com.jbitnode.db.ChainstateStore;
import com.jbitnode.db.ProjectTracker;
import com.jbitnode.db.ProjectTracker.StoredUtxo;
import com.jbitnode.db.ProjectTracker.UtxoUndoEntry;
import com.jbitnode.db.UtxoStore;
import com.jbitnode.messages.BlockHeaderCodec;
import com.jbitnode.sync.BlockValidationException;
import com.jbitnode.sync.BlockValidator;
import com.jbitnode.sync.BlockValidator.ValidateOptions;
import com.jbitnode.util.Hex;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Connects blocks with independent script verification and transactional UTXO updates. */
public final class BlockConnector {

  private BlockConnector() {}

  public record ConnectResult(int height, String blockHashHex, int utxosCreated, int inputCount) {
    public ConnectResult(int height, String blockHashHex, int utxosCreated) {
      this(height, blockHashHex, utxosCreated, 0);
    }
  }

  @FunctionalInterface
  public interface TimingSink {
    void record(String stage, int height, long elapsedMillis) throws SQLException;

    static TimingSink none() {
      return (stage, height, elapsedMillis) -> {};
    }
  }

  public static ConnectResult connectInCurrentTransaction(
      ProjectTracker tracker,
      ChainstateStore chainstateStore,
      String chain,
      int height,
      byte[] payload,
      byte[] expectedPrev,
      byte[] expectedHash,
      TimingSink timingSink)
      throws ConnectBlockException, ValidationBlocker, SQLException {
    return connectInCurrentTransaction(
        tracker,
        chainstateStore.utxoStore(),
        chainstateStore,
        chain,
        height,
        payload,
        expectedPrev,
        expectedHash,
        timingSink);
  }

  public static ConnectResult connectInCurrentTransaction(
      ProjectTracker tracker,
      UtxoStore utxoStore,
      String chain,
      int height,
      byte[] payload,
      byte[] expectedPrev,
      byte[] expectedHash,
      TimingSink timingSink)
      throws ConnectBlockException, ValidationBlocker, SQLException {
    return connectInCurrentTransaction(
        tracker, utxoStore, null, chain, height, payload, expectedPrev, expectedHash, timingSink);
  }

  private static ConnectResult connectInCurrentTransaction(
      ProjectTracker tracker,
      UtxoStore utxoStore,
      ChainstateStore chainstateStore,
      String chain,
      int height,
      byte[] payload,
      byte[] expectedPrev,
      byte[] expectedHash,
      TimingSink timingSink)
      throws ConnectBlockException, ValidationBlocker, SQLException {
    int validated = tracker.getValidatedHeight(chain);
    if (height != validated + 1) {
      throw new ConnectBlockException(
          "cannot connect height " + height + " on top of validated tip " + validated);
    }

    Block block;
    long parseStarted = System.nanoTime();
    try {
      block = BlockValidator.validateBlock(payload, new ValidateOptions(expectedPrev, expectedHash));
    } catch (BlockValidationException error) {
      throw new ConnectBlockException(error.getMessage(), error);
    }
    ConnectTimings timings = new ConnectTimings();
    timings.recordStage("block_parse_validate", System.nanoTime() - parseStarted);

    String blockHashHex = BlockHeaderCodec.blockHashHex(block.header());
    BlockShape shape = BlockShape.from(block);
    BlockUtxoView view =
        new BlockUtxoView(utxoStore, chain, height, timings, shape.spendCount(), shape.spendableOutputUpperBound());
    ScriptVerifySettings scriptVerifySettings = ScriptVerifySettings.fromEnv();
    long totalFees = 0;
    int inputCount = 0;

    try (ScriptVerifyRunner scriptVerifyRunner = new ScriptVerifyRunner(scriptVerifySettings)) {
      List<ScriptVerifyRunner.BlockInputVerifyJob> blockVerifyJobs =
          new ArrayList<>(Math.max(16, shape.spendCount()));
      for (int transactionIndex = 0; transactionIndex < block.transactions().size(); transactionIndex++) {
        Transaction transaction = block.transactions().get(transactionIndex);
        if (transaction.isCoinbase()) {
          continue;
        }
        inputCount += transaction.inputs().size();
        long txidStarted = System.nanoTime();
        byte[] txid = Merkle.transactionTxid(transaction);
        String txidHex = Hex.encode(Hex.reverse(txid));
        timings.recordStage("txid_hashing", System.nanoTime() - txidStarted);
        totalFees +=
            prepareNonCoinbaseTransaction(
                view,
                blockHashHex,
                height,
                txidHex,
                transactionIndex,
                transaction,
                timings,
                scriptVerifyRunner,
                blockVerifyJobs);
        long outputStarted = System.nanoTime();
        for (int vout = 0; vout < transaction.outputs().size(); vout++) {
          TxOut output = transaction.outputs().get(vout);
          if (!isSpendableOutput(output.scriptPubKey())) {
            continue;
          }
          view.create(txid, vout, output.value(), output.scriptPubKey(), false);
        }
        timings.recordStage("output_create", System.nanoTime() - outputStarted);
      }
      scriptVerifyRunner.verifyBlockInputs(blockVerifyJobs, timings::recordScriptStage);
    }

    Transaction coinbase = block.transactions().getFirst();
    long coinbaseTxidStarted = System.nanoTime();
    byte[] coinbaseTxid = Merkle.transactionTxid(coinbase);
    timings.recordStage("txid_hashing", System.nanoTime() - coinbaseTxidStarted);
    long coinbaseOutputStarted = System.nanoTime();
    for (int vout = 0; vout < coinbase.outputs().size(); vout++) {
      TxOut output = coinbase.outputs().get(vout);
      if (!isSpendableOutput(output.scriptPubKey())) {
        continue;
      }
      view.create(coinbaseTxid, vout, output.value(), output.scriptPubKey(), true);
    }
    timings.recordStage("output_create", System.nanoTime() - coinbaseOutputStarted);

    long undoCaptureStarted = System.nanoTime();
    List<UtxoUndoEntry> undoEntries = view.externalSpendUndoEntries();
    timings.recordStage("undo_capture", System.nanoTime() - undoCaptureStarted);
    long applyStarted = System.nanoTime();
    ChainstateBlockCommit commit = view.toCommit(blockHashHex, undoEntries);
    if (chainstateStore == null) {
      throw new SQLException("block connect requires a native chainstate store");
    }
    ChainstateCommitResult commitResult =
        chainstateStore.commitBlock(commit, timings::recordStage);
    if (commitResult.tip().height() != height) {
      throw new ConnectBlockException("chainstate commit did not advance to height " + height);
    }
    timings.utxoApplyNanos += System.nanoTime() - applyStarted;

    timingSink.record("utxo_load", height, timings.utxoLoadMillis());
    for (Map.Entry<String, Long> entry : timings.stageMillis().entrySet()) {
      timingSink.record(entry.getKey(), height, entry.getValue());
    }
    timingSink.record("utxo_apply", height, timings.utxoApplyMillis());
    return new ConnectResult(height, blockHashHex, view.createdCount(), inputCount);
  }

  private static final class ConnectTimings {
    long utxoLoadNanos;
    long utxoApplyNanos;
    private final Map<String, Long> stageNanos = new LinkedHashMap<>();

    long utxoLoadMillis() {
      return utxoLoadNanos / 1_000_000;
    }

    long scriptVerifyMillis() {
      return stageNanos.getOrDefault("script_verify", 0L) / 1_000_000;
    }

    long utxoApplyMillis() {
      return utxoApplyNanos / 1_000_000;
    }

    void recordScriptStage(String stage, long elapsedNanos) {
      recordStage(stage, elapsedNanos);
    }

    void recordStage(String stage, long elapsedNanos) {
      stageNanos.merge(stage, elapsedNanos, Long::sum);
    }

    Map<String, Long> stageMillis() {
      Map<String, Long> millis = new LinkedHashMap<>();
      if (!stageNanos.containsKey("script_verify")) {
        millis.put("script_verify", 0L);
      }
      for (Map.Entry<String, Long> entry : stageNanos.entrySet()) {
        millis.put(entry.getKey(), entry.getValue() / 1_000_000);
      }
      return millis;
    }
  }

  private record BlockShape(int spendCount, int spendableOutputUpperBound) {
    static BlockShape from(Block block) {
      int spends = 0;
      int outputs = 0;
      for (Transaction transaction : block.transactions()) {
        if (!transaction.isCoinbase()) {
          spends += transaction.inputs().size();
        }
        outputs += transaction.outputs().size();
      }
      return new BlockShape(spends, outputs);
    }
  }

  private record PrevoutInfo(long valueSats, byte[] scriptPubKey, String scriptPubKeyHex) {}

  private static long prepareNonCoinbaseTransaction(
      BlockUtxoView view,
      String blockHashHex,
      int height,
      String txidHex,
      int transactionIndex,
      Transaction transaction,
      ConnectTimings timings,
      ScriptVerifyRunner scriptVerifyRunner,
      List<ScriptVerifyRunner.BlockInputVerifyJob> blockVerifyJobs)
      throws ConnectBlockException, ValidationBlocker, SQLException {
    int inputSize = transaction.inputs().size();
    Set<UtxoKey> seenPrevouts = new HashSet<>(Math.max(16, inputSize * 2));
    List<PrevoutInfo> prevoutInfos = new ArrayList<>(inputSize);
    long prepStarted = System.nanoTime();
    for (TxIn input : transaction.inputs()) {
      OutPoint outpoint = input.previousOutput();
      UtxoKey key = UtxoKey.fromOutPoint(outpoint);
      if (!seenPrevouts.add(key)) {
        throw new ConnectBlockException(
            "double spend of "
                + Hex.encode(Hex.reverse(outpoint.hash()))
                + ":"
                + outpoint.index());
      }
      StoredUtxo utxo = view.get(outpoint);
      if (utxo == null) {
        throw new ConnectBlockException(
            "missing UTXO "
                + Hex.encode(Hex.reverse(outpoint.hash()))
                + ":"
                + outpoint.index());
      }
      if (utxo.coinbase() && height - utxo.height() < ConsensusConstants.COINBASE_MATURITY) {
        throw new ConnectBlockException(
            "coinbase output not mature at height "
                + height
                + " (created at "
                + utxo.height()
                + ")");
      }
      prevoutInfos.add(
          new PrevoutInfo(utxo.valueSats(), Hex.decode(utxo.scriptPubKeyHex()), utxo.scriptPubKeyHex()));
    }

    List<ScriptVerify.SpentPrevout> spentPrevouts = new ArrayList<>(inputSize);
    List<ScriptVerifyRunner.InputVerifyTask> verifyTasks = new ArrayList<>(inputSize);
    long inputTotal = 0;
    for (PrevoutInfo prevout : prevoutInfos) {
      spentPrevouts.add(new ScriptVerify.SpentPrevout(prevout.valueSats(), prevout.scriptPubKey()));
    }
    for (int inputIndex = 0; inputIndex < prevoutInfos.size(); inputIndex++) {
      PrevoutInfo prevout = prevoutInfos.get(inputIndex);
      verifyTasks.add(
          new ScriptVerifyRunner.InputVerifyTask(
              inputIndex,
              prevout.scriptPubKey(),
              prevout.valueSats(),
              prevout.scriptPubKeyHex()));
      inputTotal += prevout.valueSats();
    }
    timings.recordStage("prevout_prepare", System.nanoTime() - prepStarted);
    SighashCache sighashCache =
        scriptVerifyRunner.sighashCacheForTransaction(
            transaction, spentPrevouts, timings::recordScriptStage);
    ScriptVerifyRunner.VerifyContext context =
        new ScriptVerifyRunner.VerifyContext(height, blockHashHex, txidHex);
    for (ScriptVerifyRunner.InputVerifyTask task : verifyTasks) {
      blockVerifyJobs.add(
          new ScriptVerifyRunner.BlockInputVerifyJob(
              transactionIndex, transaction, spentPrevouts, task, context, sighashCache));
    }

    long outputTotal = 0;
    for (TxOut output : transaction.outputs()) {
      outputTotal += output.value();
    }
    if (inputTotal < outputTotal) {
      throw new ConnectBlockException("transaction outputs exceed inputs");
    }

    for (TxIn input : transaction.inputs()) {
      view.spend(input.previousOutput());
    }
    return inputTotal - outputTotal;
  }

  static boolean isSpendableOutput(byte[] scriptPubKey) {
    return scriptPubKey.length > 0;
  }

  static long elapsedMillis(long startedNanos) {
    return Math.max(0, (System.nanoTime() - startedNanos) / 1_000_000);
  }

  private static final class BlockUtxoView {
    private final UtxoStore utxoStore;
    private final String chain;
    private final int height;
    private final ConnectTimings timings;
    private final Map<UtxoKey, StoredUtxo> loaded;
    private final Map<UtxoKey, StoredUtxo> created;
    private final Set<UtxoKey> spent;

    BlockUtxoView(
        UtxoStore utxoStore,
        String chain,
        int height,
        ConnectTimings timings,
        int expectedSpends,
        int expectedCreates) {
      this.utxoStore = utxoStore;
      this.chain = chain;
      this.height = height;
      this.timings = timings;
      this.loaded = new HashMap<>(Math.max(16, expectedSpends * 2));
      this.created = new HashMap<>(Math.max(16, expectedCreates * 2));
      this.spent = new HashSet<>(Math.max(16, expectedSpends * 2));
    }

    StoredUtxo get(OutPoint outpoint) throws SQLException {
      UtxoKey key = UtxoKey.fromOutPoint(outpoint);
      if (spent.contains(key)) {
        return null;
      }
      StoredUtxo local = created.get(key);
      if (local != null) {
        return local;
      }
      StoredUtxo cached = loaded.get(key);
      if (cached != null) {
        return cached;
      }
      long started = System.nanoTime();
      try {
        StoredUtxo utxo =
            utxoStore.get(chain, key.displayTxidHex(), (int) key.vout());
        if (utxo != null) {
          loaded.put(key, utxo);
        }
        return utxo;
      } finally {
        timings.utxoLoadNanos += System.nanoTime() - started;
      }
    }

    void spend(OutPoint outpoint) throws ConnectBlockException {
      UtxoKey key = UtxoKey.fromOutPoint(outpoint);
      if (spent.contains(key)) {
        throw new ConnectBlockException(
            "double spend of "
                + Hex.encode(Hex.reverse(outpoint.hash()))
                + ":"
                + outpoint.index());
      }
      spent.add(key);
    }

    void create(
        byte[] txidInternal, int vout, long valueSats, byte[] scriptPubKey, boolean coinbase)
        throws ConnectBlockException {
      String txidHex = Hex.encode(Hex.reverse(txidInternal));
      UtxoKey key = UtxoKey.fromInternalTxid(txidInternal, vout);
      if (created.containsKey(key)) {
        throw new ConnectBlockException("duplicate UTXO " + txidHex + ":" + vout);
      }
      created.put(
          key,
          new StoredUtxo(txidHex, vout, height, valueSats, Hex.encode(scriptPubKey), coinbase));
    }

    int createdCount() {
      return created.size();
    }

    List<UtxoUndoEntry> externalSpendUndoEntries() throws SQLException, ConnectBlockException {
      List<UtxoUndoEntry> entries = new ArrayList<>(spent.size());
      for (UtxoKey key : spent) {
        if (created.containsKey(key)) {
          continue;
        }
        StoredUtxo utxo = loaded.get(key);
        if (utxo == null) {
          throw new ConnectBlockException(
              "internal error: could not capture undo for " + key.displayTxidHex() + ":" + key.vout());
        }
        entries.add(
            new UtxoUndoEntry(
                utxo.txid(),
                utxo.vout(),
                utxo.height(),
                utxo.valueSats(),
                utxo.scriptPubKeyHex(),
                utxo.coinbase()));
      }
      return entries;
    }

    void apply() throws SQLException {
      ChainstateBlockCommit commit = toCommit("", List.of());
      long spendBatchStarted = System.nanoTime();
      utxoStore.spendBatch(chain, commit.spentOutpoints());
      timings.recordStage("utxo_spend_batch", System.nanoTime() - spendBatchStarted);

      long addBatchStarted = System.nanoTime();
      utxoStore.addBatch(chain, commit.createdUtxos());
      timings.recordStage("utxo_add_batch", System.nanoTime() - addBatchStarted);
    }

    ChainstateBlockCommit toCommit(String blockHashHex, List<UtxoUndoEntry> undoEntries) {
      long externalSpendBuildStarted = System.nanoTime();
      List<ProjectTracker.UtxoOutpoint> externalSpends = new ArrayList<>(spent.size());
      for (UtxoKey key : spent) {
        if (created.containsKey(key)) {
          continue;
        }
        externalSpends.add(new ProjectTracker.UtxoOutpoint(key.displayTxidHex(), (int) key.vout()));
      }
      timings.recordStage("utxo_spend_list_build", System.nanoTime() - externalSpendBuildStarted);

      long newUtxoBuildStarted = System.nanoTime();
      List<StoredUtxo> newUtxos = new ArrayList<>(created.size());
      for (Map.Entry<UtxoKey, StoredUtxo> entry : created.entrySet()) {
        if (spent.contains(entry.getKey())) {
          continue;
        }
        newUtxos.add(entry.getValue());
      }
      timings.recordStage("utxo_add_list_build", System.nanoTime() - newUtxoBuildStarted);
      return new ChainstateBlockCommit(chain, height, blockHashHex, externalSpends, newUtxos, undoEntries);
    }
  }

  private record UtxoKey(String internalTxidHex, String displayTxidHex, long vout) {
    static UtxoKey fromOutPoint(OutPoint outpoint) {
      byte[] hash = outpoint.hash();
      return new UtxoKey(Hex.encode(hash), Hex.encode(Hex.reverse(hash)), outpoint.index());
    }

    static UtxoKey fromInternalTxid(byte[] txidInternal, int vout) {
      return new UtxoKey(Hex.encode(txidInternal), Hex.encode(Hex.reverse(txidInternal)), vout);
    }
  }
}
