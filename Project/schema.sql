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
