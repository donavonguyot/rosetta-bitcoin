package com.jbitnode.cli;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.jbitnode.chain.ChainParams;
import com.jbitnode.chain.ChainRegistry;
import com.jbitnode.config.NodePaths;
import com.jbitnode.consensus.block.BlockDeserializer;
import com.jbitnode.db.OperationalStore;
import com.jbitnode.db.RocksDbOperationalStore;
import com.jbitnode.messages.BlockHeaderCodec;
import com.jbitnode.storage.BlockStore;
import com.jbitnode.storage.BlockStorage;
import com.jbitnode.util.Hex;
import java.io.PrintStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.Map;

/** Exports a portable replay corpus from a JavaNode stored-block datadir. */
public final class ReplayCorpusExportService {

  private ReplayCorpusExportService() {}

  public static int run(PrintStream out, Map<String, String> env) {
    String chainName = env.getOrDefault("CHAIN", NodePaths.DEFAULT_CHAIN);
    ChainParams chain = ChainRegistry.get(chainName);
    Path sourceDataDir =
        Path.of(env.getOrDefault("SOURCE_DATA_DIR", env.getOrDefault("DATA_DIR", "./data-java")))
            .toAbsolutePath()
            .normalize();
    Path corpusDir =
        Path.of(env.getOrDefault("REPLAY_CORPUS_DIR", "../NodeCore/replay-corpus/testnet4"))
            .toAbsolutePath()
            .normalize();
    int blocksMax = parseInt(env.get("BLOCKS_MAX"), 100);
    String corpusId = env.getOrDefault("REPLAY_CORPUS_ID", chain.name() + "-h1-" + blocksMax);

    try {
      Path fixtureDir = configuredFixtureDir(env);
      if (fixtureDir != null && Files.exists(fixtureDir.resolve("block1_wire.hex"))) {
        return exportFixtureCorpus(out, chain, fixtureDir, corpusDir, corpusId, blocksMax);
      }
      return exportStoredBlockCorpus(out, chain, sourceDataDir, corpusDir, corpusId, blocksMax);
    } catch (Exception error) {
      out.println("replay_corpus_export status=error error=" + error.getMessage());
      return 1;
    }
  }

  private static int exportStoredBlockCorpus(
      PrintStream out,
      ChainParams chain,
      Path sourceDataDir,
      Path corpusDir,
      String corpusId,
      int blocksMax)
      throws Exception {
    try (OperationalStore operationalStore =
        new RocksDbOperationalStore(sourceDataDir.resolve("operational-rocksdb"), false)) {
      BlockStorage blockStorage =
          new BlockStorage(new BlockStore(sourceDataDir.resolve("blocks"), chain.magic()), operationalStore);
      ArrayNode blocks = JsonNodeFactory.instance.arrayNode();
      int exported = 0;
      for (int height = 1; height <= blocksMax; height++) {
        var blockRecord = operationalStore.getBlock(chain.name(), height);
        if (blockRecord.isEmpty()) {
          break;
        }
        exported = addBlock(corpusDir, blocks, height, blockRecord.get().blockHash(), blockStorage.readBlock(chain.name(), height));
      }
      if (exported == 0) {
        out.println("replay_corpus_export status=error error=no stored blocks found in " + sourceDataDir);
        return 2;
      }
      writeManifest(chain, corpusDir, corpusId, sourceDataDir.toString(), exported, blocks);
      out.println(corpusDir);
      return 0;
    }
  }

  private static int exportFixtureCorpus(
      PrintStream out,
      ChainParams chain,
      Path fixtureDir,
      Path corpusDir,
      String corpusId,
      int blocksMax)
      throws Exception {
    ArrayNode blocks = JsonNodeFactory.instance.arrayNode();
    int exported = 0;
    for (int height = 1; height <= blocksMax; height++) {
      Path fixture = fixtureDir.resolve("block" + height + "_wire.hex");
      if (!Files.exists(fixture)) {
        break;
      }
      byte[] payload = Hex.decode(Files.readString(fixture).replaceAll("\\s+", ""));
      String blockHash = BlockHeaderCodec.blockHashHex(BlockDeserializer.deserialize(payload).header());
      exported = addBlock(corpusDir, blocks, height, blockHash, payload);
    }
    if (exported == 0) {
      out.println("replay_corpus_export status=error error=no fixture blocks found in " + fixtureDir);
      return 2;
    }
    writeManifest(chain, corpusDir, corpusId, fixtureDir.toString(), exported, blocks);
    out.println(corpusDir);
    return 0;
  }

  private static int addBlock(
      Path corpusDir, ArrayNode blocks, int height, String blockHash, byte[] payload) throws Exception {
    Path blocksDir = corpusDir.resolve("blocks");
    Files.createDirectories(blocksDir);
    Path file = blocksDir.resolve("block" + height + "_wire.hex");
    Files.writeString(file, Hex.encode(payload) + System.lineSeparator());
    ObjectNode block = JsonNodeFactory.instance.objectNode();
    block.put("height", height);
    block.put("block_hash", blockHash);
    block.put("file", "blocks/" + file.getFileName());
    blocks.add(block);
    return height;
  }

  private static void writeManifest(
      ChainParams chain, Path corpusDir, String corpusId, String source, int exported, ArrayNode blocks)
      throws Exception {
    JsonNodeFactory json = JsonNodeFactory.instance;
    ObjectNode manifest = json.objectNode();
    manifest.put("corpus_id", corpusId);
    manifest.put("chain", chain.name());
    manifest.put("start_height", 1);
    manifest.put("end_height", exported);
    manifest.put("source", source);
    manifest.put("created_at", Instant.now().toString());
    manifest.set("blocks", blocks);
    new ObjectMapper()
        .writerWithDefaultPrettyPrinter()
        .writeValue(corpusDir.resolve("replay_manifest.json").toFile(), manifest);
  }

  private static Path configuredFixtureDir(Map<String, String> env) {
    String fixtureDir = env.get("FIXTURE_BLOCKS_DIR");
    if (fixtureDir == null || fixtureDir.isBlank()) {
      return null;
    }
    return Path.of(fixtureDir).toAbsolutePath().normalize();
  }

  private static int parseInt(String value, int defaultValue) {
    if (value == null || value.isBlank()) {
      return defaultValue;
    }
    return Integer.parseInt(value.trim());
  }
}
