-- RosettaBitcoin Project mission-control schema.
--
-- Project/project.db is a tracked cross-port evidence index. It is allowed and
-- preferred for mission-control reporting, but it is never operational node
-- truth. Ports must not read it for sync, validation, chainstate, UTXO, block
-- lookup, blocker enforcement, or status truth.

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS artifacts (
  artifact_id TEXT PRIMARY KEY,
  path TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL,
  node_id TEXT NOT NULL DEFAULT '',
  source_sha256 TEXT NOT NULL,
  captured_at TEXT NOT NULL DEFAULT '',
  summary_json TEXT NOT NULL DEFAULT '{}',
  raw_json TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_artifacts_kind
  ON artifacts(kind);

CREATE TABLE IF NOT EXISTS nodes (
  node_id TEXT PRIMARY KEY,
  implementation TEXT NOT NULL,
  language TEXT NOT NULL,
  role TEXT NOT NULL,
  repo_path TEXT NOT NULL,
  default_datadir TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  notes TEXT NOT NULL DEFAULT '',
  source_artifact_id TEXT REFERENCES artifacts(artifact_id),
  created_at TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS decisions (
  decision_id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  status TEXT NOT NULL,
  context TEXT NOT NULL,
  decision TEXT NOT NULL,
  consequences TEXT NOT NULL DEFAULT '',
  source_path TEXT NOT NULL DEFAULT '',
  source_artifact_id TEXT REFERENCES artifacts(artifact_id),
  decided_at TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS docker_contracts (
  port TEXT PRIMARY KEY,
  node_id TEXT NOT NULL REFERENCES nodes(node_id),
  status TEXT NOT NULL,
  root_path TEXT NOT NULL DEFAULT '',
  dockerfile_path TEXT NOT NULL DEFAULT '',
  compose_path TEXT NOT NULL DEFAULT '',
  dockerignore_path TEXT NOT NULL DEFAULT '',
  data_volume TEXT NOT NULL DEFAULT '',
  proof_volume TEXT NOT NULL DEFAULT '',
  supervisor_volume TEXT NOT NULL DEFAULT '',
  commands_json TEXT NOT NULL DEFAULT '{}',
  peer_modes_json TEXT NOT NULL DEFAULT '{}',
  proof_artifacts_json TEXT NOT NULL DEFAULT '{}',
  known_caveats_json TEXT NOT NULL DEFAULT '[]',
  source_artifact_id TEXT NOT NULL REFERENCES artifacts(artifact_id)
);

CREATE TABLE IF NOT EXISTS runs (
  run_id TEXT PRIMARY KEY,
  node_id TEXT NOT NULL REFERENCES nodes(node_id),
  command TEXT NOT NULL,
  purpose TEXT NOT NULL,
  chain TEXT NOT NULL,
  datadir TEXT NOT NULL,
  commit_ref TEXT NOT NULL DEFAULT '',
  started_at TEXT NOT NULL DEFAULT '',
  finished_at TEXT NOT NULL DEFAULT '',
  exit_code INTEGER,
  result TEXT NOT NULL DEFAULT 'running',
  notes TEXT NOT NULL DEFAULT '',
  source_artifact_id TEXT REFERENCES artifacts(artifact_id)
);

CREATE INDEX IF NOT EXISTS idx_runs_node_started
  ON runs(node_id, started_at);

CREATE TABLE IF NOT EXISTS status_snapshots (
  snapshot_id TEXT PRIMARY KEY,
  node_id TEXT NOT NULL REFERENCES nodes(node_id),
  run_id TEXT REFERENCES runs(run_id),
  captured_at TEXT NOT NULL DEFAULT '',
  chain TEXT NOT NULL DEFAULT '',
  sync_status TEXT NOT NULL DEFAULT '',
  binary_gate_status TEXT NOT NULL DEFAULT '',
  header_height INTEGER NOT NULL DEFAULT -1,
  header_hash TEXT NOT NULL DEFAULT '',
  stored_block_height INTEGER NOT NULL DEFAULT -1,
  stored_block_hash TEXT NOT NULL DEFAULT '',
  validated_height INTEGER NOT NULL DEFAULT -1,
  validated_hash TEXT NOT NULL DEFAULT '',
  chainstate_backend TEXT NOT NULL DEFAULT '',
  chainstate_status TEXT NOT NULL DEFAULT '',
  chainstate_generation_id TEXT NOT NULL DEFAULT '',
  chainstate_utxo_count INTEGER,
  block_gap_count INTEGER,
  current_blocker_id TEXT,
  last_error TEXT NOT NULL DEFAULT '',
  raw_json TEXT NOT NULL DEFAULT '',
  source_artifact_id TEXT NOT NULL REFERENCES artifacts(artifact_id)
);

CREATE INDEX IF NOT EXISTS idx_status_node_captured
  ON status_snapshots(node_id, captured_at);

CREATE TABLE IF NOT EXISTS blockers (
  blocker_id TEXT PRIMARY KEY,
  height INTEGER NOT NULL,
  block_hash TEXT NOT NULL DEFAULT '',
  txid TEXT NOT NULL DEFAULT '',
  input_index INTEGER,
  spent_script_pubkey TEXT NOT NULL DEFAULT '',
  failure TEXT NOT NULL DEFAULT '',
  missing_rule TEXT NOT NULL DEFAULT '',
  source_port TEXT NOT NULL DEFAULT '',
  source_commit TEXT NOT NULL DEFAULT '',
  fixture TEXT NOT NULL DEFAULT '',
  test_name TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT '',
  first_seen_at TEXT NOT NULL DEFAULT '',
  cleared_at TEXT NOT NULL DEFAULT '',
  follower_notes TEXT NOT NULL DEFAULT '',
  source_path TEXT NOT NULL DEFAULT '',
  source_artifact_id TEXT REFERENCES artifacts(artifact_id)
);

CREATE INDEX IF NOT EXISTS idx_blockers_height
  ON blockers(height);

CREATE TABLE IF NOT EXISTS conformance_results (
  result_id TEXT PRIMARY KEY,
  node_id TEXT NOT NULL REFERENCES nodes(node_id),
  run_id TEXT REFERENCES runs(run_id),
  fixture_id TEXT NOT NULL,
  category TEXT NOT NULL,
  result TEXT NOT NULL,
  validated_height INTEGER,
  validated_hash TEXT NOT NULL DEFAULT '',
  chainstate_backend TEXT NOT NULL DEFAULT '',
  duration_ms INTEGER,
  failure TEXT NOT NULL DEFAULT '',
  raw_json TEXT NOT NULL DEFAULT '',
  captured_at TEXT NOT NULL DEFAULT '',
  source_artifact_id TEXT NOT NULL REFERENCES artifacts(artifact_id)
);

CREATE INDEX IF NOT EXISTS idx_conformance_node_fixture
  ON conformance_results(node_id, fixture_id);

CREATE TABLE IF NOT EXISTS benchmarks (
  benchmark_id TEXT PRIMARY KEY,
  node_id TEXT NOT NULL REFERENCES nodes(node_id),
  run_id TEXT REFERENCES runs(run_id),
  benchmark_name TEXT NOT NULL,
  chain TEXT NOT NULL DEFAULT '',
  height INTEGER,
  block_hash TEXT NOT NULL DEFAULT '',
  backend TEXT NOT NULL DEFAULT '',
  settings_json TEXT NOT NULL DEFAULT '{}',
  timings_json TEXT NOT NULL DEFAULT '{}',
  result_json TEXT NOT NULL DEFAULT '{}',
  captured_at TEXT NOT NULL DEFAULT '',
  source_artifact_id TEXT NOT NULL REFERENCES artifacts(artifact_id)
);

CREATE TABLE IF NOT EXISTS timing_samples (
  sample_id TEXT PRIMARY KEY,
  node_id TEXT NOT NULL REFERENCES nodes(node_id),
  run_id TEXT REFERENCES runs(run_id),
  chain TEXT NOT NULL DEFAULT '',
  height INTEGER,
  block_hash TEXT NOT NULL DEFAULT '',
  stage TEXT NOT NULL,
  elapsed_ms INTEGER NOT NULL,
  captured_at TEXT NOT NULL DEFAULT '',
  source_artifact_id TEXT NOT NULL REFERENCES artifacts(artifact_id)
);

CREATE INDEX IF NOT EXISTS idx_timing_stage_height
  ON timing_samples(stage, height);
