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

CREATE TABLE IF NOT EXISTS port_commands (
  command_id TEXT PRIMARY KEY,
  port TEXT NOT NULL REFERENCES docker_contracts(port),
  node_id TEXT NOT NULL REFERENCES nodes(node_id),
  command_key TEXT NOT NULL,
  purpose TEXT NOT NULL DEFAULT '',
  command TEXT NOT NULL DEFAULT '',
  supported INTEGER NOT NULL DEFAULT 0,
  source_artifact_id TEXT NOT NULL REFERENCES artifacts(artifact_id),
  UNIQUE(port, command_key)
);

CREATE INDEX IF NOT EXISTS idx_port_commands_key
  ON port_commands(command_key, port);

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

CREATE TABLE IF NOT EXISTS benchmark_gates (
  gate_id TEXT PRIMARY KEY,
  target_height INTEGER NOT NULL,
  target_label TEXT NOT NULL,
  benchmark_kind TEXT NOT NULL UNIQUE,
  role TEXT NOT NULL,
  preferred_runtime_surface TEXT NOT NULL,
  preferred_command_key TEXT NOT NULL,
  official_lane TEXT NOT NULL DEFAULT '',
  official_byte_source TEXT NOT NULL DEFAULT '',
  official_peer_mode TEXT NOT NULL DEFAULT '',
  official_proof_mode TEXT NOT NULL DEFAULT '',
  official_header_target_height INTEGER NOT NULL DEFAULT -1,
  official_prefetch_depth INTEGER NOT NULL DEFAULT -1,
  official_script_runner_mode TEXT NOT NULL DEFAULT '',
  fresh_state_required INTEGER NOT NULL DEFAULT 1,
  local_reference_required INTEGER NOT NULL DEFAULT 1,
  durable_required INTEGER NOT NULL DEFAULT 1,
  wal_disabled_required INTEGER NOT NULL DEFAULT 0,
  resume_supported_required INTEGER NOT NULL DEFAULT 1,
  binary_gate_status TEXT NOT NULL DEFAULT 'not_attempted',
  result_name_pattern TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT ''
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

CREATE VIEW IF NOT EXISTS project_node_ports AS
SELECT
  node_id,
  CASE
    WHEN lower(node_id) = 'reference' OR lower(implementation) LIKE '%reference%' THEN 'reference'
    WHEN lower(node_id) LIKE '%csharp%' OR lower(node_id) LIKE '%csbitnode%' OR lower(implementation) LIKE 'csharp%' THEN 'csharp'
    WHEN lower(node_id) LIKE '%cpp%' OR lower(node_id) LIKE '%cpbitnode%' OR lower(implementation) LIKE 'cpp%' THEN 'cpp'
    WHEN lower(node_id) LIKE '%elixir%' OR lower(node_id) LIKE '%exbitnode%' OR lower(implementation) LIKE 'elixir%' THEN 'elixir'
    WHEN lower(node_id) LIKE '%go%' OR lower(node_id) LIKE '%gobitnode%' OR lower(implementation) LIKE 'go%' THEN 'go'
    WHEN lower(node_id) LIKE '%java%' OR lower(node_id) LIKE '%jbitnode%' OR lower(implementation) LIKE 'java%' THEN 'java'
    WHEN lower(node_id) LIKE '%python%' OR lower(node_id) LIKE '%pybitnode%' OR lower(implementation) LIKE 'python%' THEN 'python'
    WHEN lower(node_id) LIKE '%rust%' OR lower(node_id) LIKE '%rsbitnode%' OR lower(implementation) LIKE 'rust%' THEN 'rust'
    WHEN lower(node_id) LIKE '%typescript%' OR lower(node_id) LIKE '%tsbitnode%' OR lower(implementation) LIKE 'typescript%' THEN 'typescript'
    ELSE node_id
  END AS port,
  implementation,
  language,
  role,
  repo_path,
  default_datadir,
  status AS node_status,
  notes
FROM nodes;

CREATE VIEW IF NOT EXISTS latest_node_status AS
WITH ranked AS (
  SELECT
    np.port,
    np.implementation,
    np.language,
    np.role,
    s.*,
    row_number() OVER (
      PARTITION BY s.node_id
      ORDER BY s.validated_height DESC, (s.captured_at <> '') DESC, s.captured_at DESC
    ) AS rn
  FROM status_snapshots s
  JOIN project_node_ports np ON np.node_id = s.node_id
)
SELECT
  port,
  node_id,
  implementation,
  language,
  role,
  captured_at,
  chain,
  sync_status,
  binary_gate_status,
  header_height,
  stored_block_height,
  validated_height,
  chainstate_backend,
  chainstate_status,
  chainstate_utxo_count,
  block_gap_count,
  current_blocker_id,
  last_error,
  source_artifact_id
FROM ranked
WHERE rn = 1;

CREATE VIEW IF NOT EXISTS latest_port_status AS
WITH ranked AS (
  SELECT
    *,
    row_number() OVER (
      PARTITION BY port
      ORDER BY validated_height DESC, (captured_at <> '') DESC, captured_at DESC, node_id
    ) AS rn
  FROM latest_node_status
  WHERE port <> 'reference'
)
SELECT
  port,
  node_id,
  implementation,
  language,
  role,
  captured_at,
  chain,
  sync_status,
  binary_gate_status,
  header_height,
  stored_block_height,
  validated_height,
  chainstate_backend,
  chainstate_status,
  chainstate_utxo_count,
  block_gap_count,
  current_blocker_id,
  last_error,
  source_artifact_id
FROM ranked
WHERE rn = 1;

CREATE VIEW IF NOT EXISTS docker_coverage AS
SELECT
  dc.port,
  dc.node_id,
  dc.status AS docker_status,
  CASE WHEN dc.dockerfile_path <> '' THEN 1 ELSE 0 END AS has_dockerfile,
  CASE WHEN dc.compose_path <> '' THEN 1 ELSE 0 END AS has_compose,
  CASE WHEN dc.dockerignore_path <> '' THEN 1 ELSE 0 END AS has_dockerignore,
  dc.data_volume,
  dc.proof_volume,
  dc.supervisor_volume,
  dc.root_path,
  dc.source_artifact_id
FROM docker_contracts dc;

CREATE VIEW IF NOT EXISTS port_command_surface AS
SELECT
  pc.port,
  pc.node_id,
  dc.status AS docker_status,
  pc.command_key,
  pc.purpose,
  pc.supported,
  pc.command,
  dc.root_path,
  pc.source_artifact_id
FROM port_commands pc
JOIN docker_contracts dc ON dc.port = pc.port;

CREATE VIEW IF NOT EXISTS port_command_coverage AS
SELECT
  command_key,
  purpose,
  count(*) AS declared_ports,
  sum(CASE WHEN supported = 1 THEN 1 ELSE 0 END) AS supported_ports,
  group_concat(CASE WHEN supported = 1 THEN port END) AS supporting_ports,
  group_concat(CASE WHEN supported = 0 THEN port END) AS unsupported_ports
FROM port_command_surface
GROUP BY command_key, purpose;

CREATE VIEW IF NOT EXISTS conformance_summary AS
SELECT
  np.port,
  cr.node_id,
  cr.category,
  cr.result,
  count(*) AS result_count,
  max(coalesce(cr.validated_height, -1)) AS max_validated_height,
  max(cr.captured_at) AS latest_captured_at
FROM conformance_results cr
JOIN project_node_ports np ON np.node_id = cr.node_id
GROUP BY np.port, cr.node_id, cr.category, cr.result;

CREATE VIEW IF NOT EXISTS normalized_blocker_rows AS
SELECT
  b.*,
  CASE
    WHEN lower(b.source_port) = 'catalog' OR b.source_path = 'Docs/consensus-blockers-testnet4.md' THEN 'catalog'
    WHEN lower(b.source_port) IN ('csharp', 'c#') OR b.source_path LIKE 'Nodes/CSharp/%' THEN 'csharp'
    WHEN lower(b.source_port) IN ('cpp', 'c++') OR b.source_path LIKE 'Nodes/Cpp/%' THEN 'cpp'
    WHEN lower(b.source_port) = 'elixir' OR b.source_path LIKE 'Nodes/Elixir/%' THEN 'elixir'
    WHEN lower(b.source_port) = 'go' OR b.source_path LIKE 'Nodes/Go/%' THEN 'go'
    WHEN lower(b.source_port) = 'java' OR b.source_path LIKE 'Nodes/Java/%' THEN 'java'
    WHEN lower(b.source_port) = 'python' OR b.source_path LIKE 'Nodes/Python/%' THEN 'python'
    WHEN lower(b.source_port) = 'rust' OR b.source_path LIKE 'Nodes/Rust/%' THEN 'rust'
    WHEN lower(b.source_port) = 'typescript' OR b.source_path LIKE 'Nodes/TypeScript/%' THEN 'typescript'
    ELSE lower(b.source_port)
  END AS source_port_normalized,
  CASE
    WHEN lower(b.status) LIKE '%cleared%' OR lower(b.missing_rule) LIKE '%resolved%' THEN 'cleared'
    WHEN lower(b.status) LIKE '%block%' THEN 'blocked'
    WHEN lower(b.status) = 'open' THEN 'open'
    WHEN b.status = '' THEN 'unknown'
    ELSE lower(b.status)
  END AS normalized_status
FROM blockers b;

CREATE VIEW IF NOT EXISTS current_blocker_state AS
SELECT
  n.height,
  COALESCE(
    (
      SELECT c.missing_rule
      FROM normalized_blocker_rows c
      WHERE c.height = n.height AND c.source_port_normalized = 'catalog'
      ORDER BY length(c.missing_rule) DESC
      LIMIT 1
    ),
    (
      SELECT c.missing_rule
      FROM normalized_blocker_rows c
      WHERE c.height = n.height
      ORDER BY length(c.missing_rule) DESC
      LIMIT 1
    )
  ) AS missing_rule,
  CASE
    WHEN sum(CASE WHEN n.normalized_status = 'cleared' THEN 1 ELSE 0 END) > 0 THEN 'cleared'
    WHEN sum(CASE WHEN n.normalized_status = 'blocked' THEN 1 ELSE 0 END) > 0 THEN 'blocked'
    WHEN sum(CASE WHEN n.normalized_status = 'open' THEN 1 ELSE 0 END) > 0 THEN 'open'
    ELSE 'unknown'
  END AS status,
  group_concat(DISTINCT n.source_port_normalized) AS sources,
  group_concat(DISTINCT n.source_path) AS source_paths
FROM normalized_blocker_rows n
GROUP BY n.height;

CREATE VIEW IF NOT EXISTS follower_blocker_matrix AS
WITH ports AS (
  SELECT port
  FROM docker_contracts
  WHERE port <> 'reference'
),
fixture_heights AS (
  SELECT
    np.port,
    cr.validated_height AS height,
    max(CASE WHEN cr.result = 'passed' THEN 1 ELSE 0 END) AS has_passed_fixture
  FROM conformance_results cr
  JOIN project_node_ports np ON np.node_id = cr.node_id
  WHERE cr.validated_height IS NOT NULL AND cr.validated_height >= 0
  GROUP BY np.port, cr.validated_height
),
port_blockers AS (
  SELECT
    source_port_normalized AS port,
    height,
    max(CASE WHEN normalized_status IN ('blocked', 'open') THEN 1 ELSE 0 END) AS has_open_blocker
  FROM normalized_blocker_rows
  WHERE source_port_normalized <> '' AND source_port_normalized <> 'catalog'
  GROUP BY source_port_normalized, height
)
SELECT
  b.height,
  b.missing_rule,
  p.port,
  CASE
    WHEN coalesce(fh.has_passed_fixture, 0) = 1 THEN 'fixture_passed'
    WHEN coalesce(lps.validated_height, -1) >= b.height THEN 'cleared'
    WHEN coalesce(pb.has_open_blocker, 0) = 1 THEN 'blocked'
    WHEN coalesce(lps.validated_height, -1) >= 0 AND coalesce(lps.validated_height, -1) < b.height THEN 'not_reached'
    ELSE 'unknown'
  END AS blocker_status,
  lps.validated_height AS latest_validated_height,
  coalesce(fh.has_passed_fixture, 0) AS has_passed_fixture
FROM current_blocker_state b
CROSS JOIN ports p
LEFT JOIN latest_port_status lps ON lps.port = p.port
LEFT JOIN fixture_heights fh ON fh.port = p.port AND fh.height = b.height
LEFT JOIN port_blockers pb ON pb.port = p.port AND pb.height = b.height;

CREATE VIEW IF NOT EXISTS benchmark_summary AS
SELECT
  np.port,
  b.node_id,
  b.benchmark_name,
  max(coalesce(b.height, -1)) AS max_height,
  max(b.captured_at) AS latest_captured_at,
  count(*) AS sample_count,
  b.backend
FROM benchmarks b
JOIN project_node_ports np ON np.node_id = b.node_id
GROUP BY np.port, b.node_id, b.benchmark_name, b.backend;

CREATE VIEW IF NOT EXISTS benchmark_comparability AS
WITH benchmark_rows AS (
  SELECT
    bg.gate_id,
    bg.target_label,
    bg.target_height,
    bg.benchmark_kind AS gate_benchmark_kind,
    bg.preferred_runtime_surface,
    bg.preferred_command_key,
    bg.official_lane,
    bg.official_byte_source,
    bg.official_peer_mode,
    bg.official_proof_mode,
    bg.official_header_target_height,
    bg.official_prefetch_depth,
    bg.official_script_runner_mode,
    bg.fresh_state_required,
    bg.wal_disabled_required,
    bg.resume_supported_required,
    bg.binary_gate_status AS required_binary_gate_status,
    np.port,
    b.node_id,
    b.benchmark_name,
    coalesce(json_extract(b.result_json, '$.validated_height'), b.height, -1) AS validated_height,
    coalesce(json_extract(b.result_json, '$.header_height'), json_extract(b.settings_json, '$.header_target_height'), -1) AS header_target_height,
    coalesce(json_extract(b.result_json, '$.result'), '') AS result,
    coalesce(json_extract(b.result_json, '$.binary_gate_status'), json_extract(b.settings_json, '$.binary_gate_status'), '') AS binary_gate_status,
    coalesce(json_extract(b.settings_json, '$.benchmark_lane'), '') AS reported_lane,
    coalesce(json_extract(b.settings_json, '$.byte_source'), '') AS byte_source,
    coalesce(json_extract(b.settings_json, '$.proof_mode'), '') AS proof_mode,
    coalesce(json_extract(b.settings_json, '$.runtime_surface'), '') AS runtime_surface,
    coalesce(json_extract(b.settings_json, '$.peer_mode'), '') AS peer_mode,
    coalesce(json_extract(b.settings_json, '$.peer'), '') AS peer,
    coalesce(json_extract(b.settings_json, '$.prefetch_depth'), -1) AS prefetch_depth,
    lower(coalesce(json_extract(b.settings_json, '$.script_runner_mode'), '')) AS script_runner_mode,
    lower(coalesce(cast(json_extract(b.settings_json, '$.rocksdb_wal_disabled') AS TEXT), '')) AS rocksdb_wal_disabled_text,
    lower(coalesce(cast(json_extract(b.settings_json, '$.resume_supported') AS TEXT), '')) AS resume_supported_text,
    lower(coalesce(cast(json_extract(b.settings_json, '$.fresh_state') AS TEXT), '')) AS fresh_state_text,
    coalesce(json_extract(b.result_json, '$.current_blocker'), '') AS current_blocker,
    b.captured_at,
    b.source_artifact_id
  FROM benchmark_gates bg
  JOIN benchmarks b ON b.height = bg.target_height
  JOIN project_node_ports np ON np.node_id = b.node_id
),
classified AS (
  SELECT
    *,
    CASE
      WHEN peer_mode = 'local_reference_rpc' OR byte_source = 'local_reference_rpc' OR proof_mode IN ('rpc_replay', 'pipeline') THEN 'supporting_5k_rpc_replay'
      WHEN peer_mode = 'local_reference' OR byte_source = 'local_reference_p2p' THEN 'supporting_5k_p2p'
      ELSE coalesce(nullif(reported_lane, ''), 'diagnostic')
    END AS evidence_lane,
    CASE
      WHEN rocksdb_wal_disabled_text IN ('1', 'true', 'yes', 'on') THEN 1
      ELSE 0
    END AS rocksdb_wal_disabled,
    CASE
      WHEN resume_supported_text IN ('1', 'true', 'yes', 'on') THEN 1
      ELSE 0
    END AS resume_supported,
    CASE
      WHEN fresh_state_text IN ('1', 'true', 'yes', 'on') THEN 1
      ELSE 0
    END AS fresh_state
  FROM benchmark_rows
),
scored AS (
  SELECT
    *,
    trim(
      CASE WHEN runtime_surface <> preferred_runtime_surface THEN 'runtime_surface;' ELSE '' END ||
      CASE WHEN evidence_lane <> official_lane THEN 'lane;' ELSE '' END ||
      CASE WHEN byte_source <> official_byte_source THEN 'byte_source;' ELSE '' END ||
      CASE WHEN peer_mode <> official_peer_mode THEN 'peer_mode;' ELSE '' END ||
      CASE WHEN proof_mode <> official_proof_mode THEN 'proof_mode;' ELSE '' END ||
      CASE WHEN peer NOT IN ('host.docker.internal:48333', 'reference:48333', 'rosetta-bitcoin-core-testnet4:48333') THEN 'peer;' ELSE '' END ||
      CASE WHEN header_target_height <> official_header_target_height THEN 'header_target_height;' ELSE '' END ||
      CASE WHEN prefetch_depth <> official_prefetch_depth THEN 'prefetch_depth;' ELSE '' END ||
      CASE WHEN script_runner_mode <> official_script_runner_mode THEN 'script_runner_mode;' ELSE '' END ||
      CASE WHEN rocksdb_wal_disabled <> wal_disabled_required THEN 'rocksdb_wal;' ELSE '' END ||
      CASE WHEN resume_supported <> resume_supported_required THEN 'resume_supported;' ELSE '' END ||
      CASE WHEN fresh_state_required = 1 AND fresh_state <> 1 THEN 'fresh_state;' ELSE '' END ||
      CASE WHEN binary_gate_status <> required_binary_gate_status THEN 'binary_gate_status;' ELSE '' END
    ) AS comparability_notes
  FROM classified
)
SELECT
  gate_id,
  target_label,
  target_height,
  gate_benchmark_kind AS benchmark_kind,
  preferred_runtime_surface,
  preferred_command_key,
  official_lane,
  port,
  node_id,
  benchmark_name,
  CASE
    WHEN validated_height >= target_height AND result IN ('passed', 'target_reached', 'ok', 'success') THEN 'passed'
    WHEN validated_height >= target_height AND result = '' THEN 'recorded'
    ELSE coalesce(nullif(result, ''), 'recorded')
  END AS gate_status,
  CASE
    WHEN validated_height < target_height OR result IN ('failed', 'blocked', 'error') THEN 'failed'
    WHEN evidence_lane = 'supporting_5k_rpc_replay' THEN 'evidence_only'
    WHEN comparability_notes = '' THEN 'comparable'
    WHEN rocksdb_wal_disabled <> wal_disabled_required OR runtime_surface <> preferred_runtime_surface THEN 'diagnostic'
    ELSE 'evidence_only'
  END AS comparability_status,
  evidence_lane,
  validated_height,
  header_target_height,
  runtime_surface,
  peer_mode,
  byte_source,
  proof_mode,
  peer,
  prefetch_depth,
  script_runner_mode,
  rocksdb_wal_disabled,
  resume_supported,
  fresh_state,
  binary_gate_status,
  comparability_notes,
  captured_at,
  source_artifact_id
FROM scored;

CREATE VIEW IF NOT EXISTS benchmark_gate_matrix AS
WITH ports AS (
  SELECT port
  FROM docker_contracts
  WHERE port <> 'reference'
),
ranked_results AS (
  SELECT
    bc.*,
    row_number() OVER (
      PARTITION BY bc.gate_id, bc.port
      ORDER BY bc.validated_height DESC,
               bc.captured_at DESC,
               bc.source_artifact_id
    ) AS rn
  FROM benchmark_comparability bc
)
SELECT
  bg.gate_id,
  bg.target_label,
  bg.target_height,
  bg.benchmark_kind,
  bg.role,
  bg.preferred_runtime_surface,
  bg.preferred_command_key,
  p.port,
  CASE
    WHEN rr.node_id IS NULL THEN 'missing'
    ELSE rr.gate_status
  END AS gate_status,
  coalesce(rr.comparability_status, 'missing') AS comparability_status,
  coalesce(rr.evidence_lane, '') AS evidence_lane,
  coalesce(rr.validated_height, -1) AS validated_height,
  coalesce(rr.header_target_height, -1) AS header_target_height,
  coalesce(rr.runtime_surface, '') AS runtime_surface,
  coalesce(rr.peer_mode, '') AS peer_mode,
  coalesce(rr.byte_source, '') AS byte_source,
  coalesce(rr.proof_mode, '') AS proof_mode,
  coalesce(rr.prefetch_depth, -1) AS prefetch_depth,
  coalesce(rr.script_runner_mode, '') AS script_runner_mode,
  coalesce(rr.rocksdb_wal_disabled, '') AS rocksdb_wal_disabled,
  coalesce(rr.fresh_state, 0) AS fresh_state,
  coalesce(rr.comparability_notes, '') AS comparability_notes,
  coalesce(rr.captured_at, '') AS captured_at,
  rr.source_artifact_id
FROM benchmark_gates bg
CROSS JOIN ports p
LEFT JOIN ranked_results rr ON rr.gate_id = bg.gate_id AND rr.port = p.port AND rr.rn = 1;
