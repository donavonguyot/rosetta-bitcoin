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

CREATE TABLE IF NOT EXISTS evidence_index_entries (
  entry_id TEXT PRIMARY KEY,
  port TEXT NOT NULL,
  claim TEXT NOT NULL,
  gate_id TEXT NOT NULL DEFAULT '',
  path TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'current',
  notes TEXT NOT NULL DEFAULT '',
  source_artifact_id TEXT NOT NULL REFERENCES artifacts(artifact_id),
  UNIQUE(port, claim, gate_id, path)
);

CREATE INDEX IF NOT EXISTS idx_evidence_index_path
  ON evidence_index_entries(path);

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

CREATE TABLE IF NOT EXISTS port_lifecycle (
  port TEXT PRIMARY KEY,
  lifecycle_status TEXT NOT NULL,
  benchmark_scope TEXT NOT NULL DEFAULT '',
  retired_at_gate TEXT NOT NULL DEFAULT '',
  retired_reason TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT '',
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

CREATE TABLE IF NOT EXISTS test_commands (
  command_id TEXT PRIMARY KEY,
  port TEXT NOT NULL REFERENCES docker_contracts(port),
  node_id TEXT NOT NULL REFERENCES nodes(node_id),
  command_key TEXT NOT NULL,
  category TEXT NOT NULL DEFAULT '',
  purpose TEXT NOT NULL DEFAULT '',
  command TEXT NOT NULL DEFAULT '',
  supported INTEGER NOT NULL DEFAULT 0,
  discovery_method TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT '',
  source_artifact_id TEXT NOT NULL REFERENCES artifacts(artifact_id),
  UNIQUE(port, command_key)
);

CREATE INDEX IF NOT EXISTS idx_test_commands_key
  ON test_commands(command_key, port);

CREATE TABLE IF NOT EXISTS test_runs (
  test_run_id TEXT PRIMARY KEY,
  port TEXT NOT NULL,
  node_id TEXT NOT NULL REFERENCES nodes(node_id),
  command_key TEXT NOT NULL,
  result TEXT NOT NULL,
  exit_code INTEGER,
  captured_at TEXT NOT NULL DEFAULT '',
  duration_ms INTEGER,
  summary_json TEXT NOT NULL DEFAULT '{}',
  source_artifact_id TEXT NOT NULL REFERENCES artifacts(artifact_id)
);

CREATE INDEX IF NOT EXISTS idx_test_runs_port_command
  ON test_runs(port, command_key, captured_at);

CREATE TABLE IF NOT EXISTS coverage_summaries (
  coverage_id TEXT PRIMARY KEY,
  port TEXT NOT NULL,
  node_id TEXT NOT NULL REFERENCES nodes(node_id),
  tool TEXT NOT NULL DEFAULT '',
  line_percent REAL,
  branch_percent REAL,
  function_percent REAL,
  statement_percent REAL,
  covered_lines INTEGER,
  total_lines INTEGER,
  captured_at TEXT NOT NULL DEFAULT '',
  source_artifact_id TEXT NOT NULL REFERENCES artifacts(artifact_id)
);

CREATE INDEX IF NOT EXISTS idx_coverage_summaries_port
  ON coverage_summaries(port, captured_at);

CREATE TABLE IF NOT EXISTS test_domain_claims (
  claim_id TEXT PRIMARY KEY,
  port TEXT NOT NULL,
  node_id TEXT NOT NULL REFERENCES nodes(node_id),
  domain TEXT NOT NULL,
  status TEXT NOT NULL,
  evidence TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT '',
  source_artifact_id TEXT REFERENCES artifacts(artifact_id),
  UNIQUE(port, domain, source_artifact_id)
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
  utxo_accounting_policy TEXT NOT NULL DEFAULT '',
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

CREATE TABLE IF NOT EXISTS consensus_rules (
  rule_id TEXT PRIMARY KEY,
  category TEXT NOT NULL,
  title TEXT NOT NULL,
  chain TEXT NOT NULL,
  status TEXT NOT NULL,
  first_height INTEGER NOT NULL DEFAULT -1,
  blocker_height INTEGER NOT NULL DEFAULT -1,
  missing_rule TEXT NOT NULL DEFAULT '',
  fixture_ids_json TEXT NOT NULL DEFAULT '[]',
  required_rules_json TEXT NOT NULL DEFAULT '[]',
  tags_json TEXT NOT NULL DEFAULT '[]',
  raw_json TEXT NOT NULL DEFAULT '{}',
  source_artifact_id TEXT NOT NULL REFERENCES artifacts(artifact_id)
);

CREATE INDEX IF NOT EXISTS idx_consensus_rules_height
  ON consensus_rules(blocker_height, first_height);

CREATE TABLE IF NOT EXISTS consensus_rule_evidence (
  evidence_id TEXT PRIMARY KEY,
  rule_id TEXT NOT NULL REFERENCES consensus_rules(rule_id),
  port TEXT NOT NULL,
  artifact_path TEXT NOT NULL DEFAULT '',
  result TEXT NOT NULL DEFAULT '',
  corpus_result TEXT NOT NULL DEFAULT '',
  runtime_surface TEXT NOT NULL DEFAULT '',
  verifier_json TEXT NOT NULL DEFAULT '{}',
  source_artifact_id TEXT NOT NULL REFERENCES artifacts(artifact_id)
);

CREATE INDEX IF NOT EXISTS idx_consensus_rule_evidence_port
  ON consensus_rule_evidence(port, rule_id);

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
  official_utxo_accounting_policy TEXT NOT NULL DEFAULT '',
  official_chainstate_utxo_count INTEGER NOT NULL DEFAULT -1,
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

DROP VIEW IF EXISTS consensus_runway;
DROP VIEW IF EXISTS consensus_stage_targets;
DROP VIEW IF EXISTS consensus_rule_summary;
DROP VIEW IF EXISTS port_baseline_5k;
DROP VIEW IF EXISTS script_corpus_baseline;
DROP VIEW IF EXISTS script_corpus_proof_artifacts;
DROP VIEW IF EXISTS benchmark_leaderboard;
DROP VIEW IF EXISTS current_benchmark_results;
DROP VIEW IF EXISTS benchmark_gate_matrix;
DROP VIEW IF EXISTS benchmark_comparability;
DROP VIEW IF EXISTS current_evidence_status;
DROP VIEW IF EXISTS critical_test_domain_coverage;
DROP VIEW IF EXISTS test_coverage_matrix;
DROP VIEW IF EXISTS latest_coverage_summaries;
DROP VIEW IF EXISTS latest_test_runs;
DROP VIEW IF EXISTS test_command_surface;
DROP VIEW IF EXISTS benchmark_timing_summary;
DROP VIEW IF EXISTS benchmark_summary;
DROP VIEW IF EXISTS follower_blocker_matrix;
DROP VIEW IF EXISTS current_blocker_state;
DROP VIEW IF EXISTS normalized_blocker_rows;
DROP VIEW IF EXISTS conformance_summary;
DROP VIEW IF EXISTS port_command_coverage;
DROP VIEW IF EXISTS port_command_surface;
DROP VIEW IF EXISTS docker_coverage;
DROP VIEW IF EXISTS latest_port_status;
DROP VIEW IF EXISTS latest_node_status;
DROP VIEW IF EXISTS project_node_ports;

CREATE VIEW IF NOT EXISTS project_node_ports AS
WITH mapped AS (
  SELECT
    node_id,
    CASE
      WHEN lower(node_id) = 'reference' OR lower(implementation) LIKE '%reference%' THEN 'reference'
      WHEN lower(node_id) LIKE '%csharp%' OR lower(node_id) LIKE '%csbitnode%' OR lower(implementation) LIKE 'csharp%' THEN 'csharp'
      WHEN lower(node_id) LIKE '%cpp%' OR lower(node_id) LIKE '%cpbitnode%' OR lower(implementation) LIKE 'cpp%' THEN 'cpp'
      WHEN lower(node_id) LIKE '%elixir%' OR lower(node_id) LIKE '%exbitnode%' OR lower(implementation) LIKE 'elixir%' THEN 'elixir'
      WHEN lower(node_id) LIKE '%go%' OR lower(node_id) LIKE '%gobitnode%' OR lower(implementation) LIKE 'go%' THEN 'go'
      WHEN lower(node_id) LIKE '%java%' OR lower(node_id) LIKE '%jbitnode%' OR lower(implementation) LIKE 'java%' THEN 'java'
      WHEN lower(node_id) LIKE '%ocaml%' OR lower(node_id) LIKE '%ocbitnode%' OR lower(implementation) LIKE 'ocaml%' OR lower(implementation) LIKE 'ocbitnode%' THEN 'ocaml'
      WHEN lower(node_id) LIKE '%python%' OR lower(node_id) LIKE '%pybitnode%' OR lower(implementation) LIKE 'python%' THEN 'python'
      WHEN lower(node_id) LIKE '%rust%' OR lower(node_id) LIKE '%rsbitnode%' OR lower(implementation) LIKE 'rust%' THEN 'rust'
      WHEN lower(node_id) LIKE '%swift%' OR lower(node_id) LIKE '%swbitnode%' OR lower(implementation) LIKE 'swift%' THEN 'swift'
      WHEN lower(node_id) LIKE '%typescript%' OR lower(node_id) LIKE '%tsbitnode%' OR lower(implementation) LIKE 'typescript%' THEN 'typescript'
      WHEN lower(node_id) LIKE '%zig%' OR lower(node_id) LIKE '%zigbitnode%' OR lower(implementation) LIKE 'zig%' THEN 'zig'
      ELSE node_id
    END AS port,
    implementation,
    language,
    role,
    repo_path,
    default_datadir,
    status AS node_status,
    notes
  FROM nodes
)
SELECT
  mapped.node_id,
  mapped.port,
  mapped.implementation,
  mapped.language,
  mapped.role,
  mapped.repo_path,
  mapped.default_datadir,
  mapped.node_status,
  mapped.notes,
  coalesce(pl.lifecycle_status, CASE WHEN mapped.port = 'reference' THEN 'reference' ELSE 'active_contender' END) AS lifecycle_status,
  coalesce(pl.benchmark_scope, CASE WHEN mapped.port = 'reference' THEN 'reference_only' ELSE 'full_suite' END) AS benchmark_scope,
  coalesce(pl.retired_at_gate, '') AS retired_at_gate,
  coalesce(pl.retired_reason, '') AS retired_reason,
  coalesce(pl.notes, '') AS lifecycle_notes
FROM mapped
LEFT JOIN port_lifecycle pl ON pl.port = mapped.port;

CREATE VIEW IF NOT EXISTS latest_node_status AS
WITH ranked AS (
  SELECT
    np.port,
    np.implementation,
    np.language,
    np.role,
    np.lifecycle_status,
    np.benchmark_scope,
    np.retired_at_gate,
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
  lifecycle_status,
  benchmark_scope,
  retired_at_gate,
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
  utxo_accounting_policy,
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
  lifecycle_status,
  benchmark_scope,
  retired_at_gate,
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
  utxo_accounting_policy,
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
  coalesce(pl.lifecycle_status, CASE WHEN dc.port = 'reference' THEN 'reference' ELSE 'active_contender' END) AS lifecycle_status,
  coalesce(pl.benchmark_scope, CASE WHEN dc.port = 'reference' THEN 'reference_only' ELSE 'full_suite' END) AS benchmark_scope,
  coalesce(pl.retired_at_gate, '') AS retired_at_gate,
  dc.status AS docker_status,
  CASE WHEN dc.dockerfile_path <> '' THEN 1 ELSE 0 END AS has_dockerfile,
  CASE WHEN dc.compose_path <> '' THEN 1 ELSE 0 END AS has_compose,
  CASE WHEN dc.dockerignore_path <> '' THEN 1 ELSE 0 END AS has_dockerignore,
  dc.data_volume,
  dc.proof_volume,
  dc.supervisor_volume,
  dc.root_path,
  dc.source_artifact_id
FROM docker_contracts dc
LEFT JOIN port_lifecycle pl ON pl.port = dc.port;

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

CREATE VIEW IF NOT EXISTS test_command_surface AS
SELECT
  tc.port,
  tc.node_id,
  coalesce(pl.lifecycle_status, CASE WHEN tc.port = 'reference' THEN 'reference' ELSE 'active_contender' END) AS lifecycle_status,
  coalesce(pl.benchmark_scope, CASE WHEN tc.port = 'reference' THEN 'reference_only' ELSE 'full_suite' END) AS benchmark_scope,
  tc.command_key,
  tc.category,
  tc.purpose,
  tc.supported,
  tc.command,
  tc.discovery_method,
  tc.notes,
  dc.root_path,
  tc.source_artifact_id
FROM test_commands tc
JOIN docker_contracts dc ON dc.port = tc.port
LEFT JOIN port_lifecycle pl ON pl.port = tc.port;

CREATE VIEW IF NOT EXISTS latest_test_runs AS
WITH ranked AS (
  SELECT
    tr.*,
    row_number() OVER (
      PARTITION BY tr.port, tr.command_key
      ORDER BY (tr.captured_at <> '') DESC, tr.captured_at DESC, tr.source_artifact_id
    ) AS rn
  FROM test_runs tr
)
SELECT
  port,
  node_id,
  command_key,
  result,
  exit_code,
  captured_at,
  duration_ms,
  summary_json,
  source_artifact_id
FROM ranked
WHERE rn = 1;

CREATE VIEW IF NOT EXISTS latest_coverage_summaries AS
WITH ranked AS (
  SELECT
    cs.*,
    row_number() OVER (
      PARTITION BY cs.port
      ORDER BY (cs.captured_at <> '') DESC, cs.captured_at DESC, cs.source_artifact_id
    ) AS rn
  FROM coverage_summaries cs
)
SELECT
  port,
  node_id,
  tool,
  line_percent,
  branch_percent,
  function_percent,
  statement_percent,
  covered_lines,
  total_lines,
  captured_at,
  source_artifact_id
FROM ranked
WHERE rn = 1;

CREATE VIEW IF NOT EXISTS current_evidence_status AS
SELECT
  eie.port,
  eie.claim,
  eie.gate_id,
  eie.status,
  eie.path,
  CASE WHEN a.artifact_id IS NULL THEN 0 ELSE 1 END AS imported,
  coalesce(a.kind, '') AS artifact_kind,
  coalesce(a.node_id, '') AS node_id,
  coalesce(a.captured_at, '') AS captured_at,
  eie.notes,
  eie.source_artifact_id AS index_artifact_id,
  a.artifact_id AS imported_artifact_id
FROM evidence_index_entries eie
LEFT JOIN artifacts a ON a.path = eie.path;

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
WITH heights AS (
  SELECT height
  FROM normalized_blocker_rows
  UNION
  SELECT blocker_height AS height
  FROM consensus_rules
  WHERE blocker_height >= 0
),
blocker_counts AS (
  SELECT
    height,
    sum(CASE WHEN normalized_status = 'cleared' THEN 1 ELSE 0 END) AS cleared_count,
    sum(CASE WHEN normalized_status = 'blocked' THEN 1 ELSE 0 END) AS blocked_count,
    sum(CASE WHEN normalized_status = 'open' THEN 1 ELSE 0 END) AS open_count
  FROM normalized_blocker_rows
  GROUP BY height
),
rule_counts AS (
  SELECT
    blocker_height AS height,
    sum(CASE WHEN status = 'proved' THEN 1 ELSE 0 END) AS proved_count,
    sum(CASE WHEN status IN ('candidate', 'fixture_backed', 'blocker_backed') THEN 1 ELSE 0 END) AS pending_count
  FROM consensus_rules
  WHERE blocker_height >= 0
  GROUP BY blocker_height
)
SELECT
  h.height,
  COALESCE(
    (
      SELECT cr.missing_rule
      FROM consensus_rules cr
      WHERE cr.blocker_height = h.height AND cr.missing_rule <> ''
      ORDER BY length(cr.missing_rule) DESC
      LIMIT 1
    ),
    (
      SELECT c.missing_rule
      FROM normalized_blocker_rows c
      WHERE c.height = h.height AND c.source_port_normalized = 'catalog'
      ORDER BY length(c.missing_rule) DESC
      LIMIT 1
    ),
    (
      SELECT c.missing_rule
      FROM normalized_blocker_rows c
      WHERE c.height = h.height
      ORDER BY length(c.missing_rule) DESC
      LIMIT 1
    )
  ) AS missing_rule,
  CASE
    WHEN coalesce(rc.proved_count, 0) > 0 THEN 'cleared'
    WHEN coalesce(bc.cleared_count, 0) > 0 THEN 'cleared'
    WHEN coalesce(bc.blocked_count, 0) > 0 THEN 'blocked'
    WHEN coalesce(bc.open_count, 0) > 0 THEN 'open'
    WHEN coalesce(rc.pending_count, 0) > 0 THEN 'unknown'
    ELSE 'unknown'
  END AS status,
  trim(
    coalesce(
      (
        SELECT group_concat(DISTINCT n.source_port_normalized)
        FROM normalized_blocker_rows n
        WHERE n.height = h.height
      ),
      ''
    ) ||
    CASE WHEN coalesce(rc.proved_count, 0) > 0 OR coalesce(rc.pending_count, 0) > 0 THEN ',rule_ledger' ELSE '' END,
    ','
  ) AS sources,
  trim(
    coalesce(
      (
        SELECT group_concat(DISTINCT n.source_path)
        FROM normalized_blocker_rows n
        WHERE n.height = h.height
      ),
      ''
    ) ||
    CASE WHEN coalesce(rc.proved_count, 0) > 0 OR coalesce(rc.pending_count, 0) > 0 THEN ',Nodes/Shared/consensus/rules/testnet4_script_rules_v1.json' ELSE '' END,
    ','
  ) AS source_paths
FROM heights h
LEFT JOIN blocker_counts bc ON bc.height = h.height
LEFT JOIN rule_counts rc ON rc.height = h.height;

CREATE VIEW IF NOT EXISTS follower_blocker_matrix AS
WITH ports AS (
  SELECT
    dc.port,
    coalesce(pl.lifecycle_status, 'active_contender') AS lifecycle_status,
    coalesce(pl.benchmark_scope, 'full_suite') AS benchmark_scope,
    coalesce(pl.retired_at_gate, '') AS retired_at_gate,
    coalesce(pl.retired_reason, '') AS retired_reason
  FROM docker_contracts dc
  LEFT JOIN port_lifecycle pl ON pl.port = dc.port
  WHERE dc.port <> 'reference'
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
  b.backend,
  min(CASE
    WHEN coalesce(json_extract(b.timings_json, '$.canonical_timing_summary.total_ms'), json_extract(b.result_json, '$.elapsed_ms'), -1) > 0
    THEN coalesce(json_extract(b.timings_json, '$.canonical_timing_summary.total_ms'), json_extract(b.result_json, '$.elapsed_ms'))
    ELSE NULL
  END) AS best_total_ms
FROM benchmarks b
JOIN project_node_ports np ON np.node_id = b.node_id
GROUP BY np.port, b.node_id, b.benchmark_name, b.backend;

CREATE VIEW IF NOT EXISTS benchmark_timing_summary AS
SELECT
  np.port,
  b.node_id,
  b.benchmark_name,
  b.height,
  b.backend,
  coalesce(json_extract(b.timings_json, '$.canonical_timing_summary.total_ms'), json_extract(b.result_json, '$.elapsed_ms'), -1) AS total_ms,
  coalesce(json_extract(b.timings_json, '$.canonical_timing_summary.stage_totals_ms.utxo_load'), -1) AS utxo_load_ms,
  coalesce(json_extract(b.timings_json, '$.canonical_timing_summary.stage_totals_ms.script_verify'), -1) AS script_verify_ms,
  coalesce(json_extract(b.timings_json, '$.canonical_timing_summary.stage_totals_ms.utxo_apply'), -1) AS utxo_apply_ms,
  coalesce(json_extract(b.timings_json, '$.canonical_timing_summary.stage_totals_ms.commit'), -1) AS commit_ms,
  coalesce(json_extract(b.timings_json, '$.canonical_timing_summary.stage_totals_ms.block_connect_store_commit'), -1) AS block_connect_store_commit_ms,
  b.captured_at,
  b.source_artifact_id
FROM benchmarks b
JOIN project_node_ports np ON np.node_id = b.node_id;

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
    bg.official_utxo_accounting_policy,
    bg.official_chainstate_utxo_count,
    bg.fresh_state_required,
    bg.wal_disabled_required,
    bg.resume_supported_required,
    bg.binary_gate_status AS required_binary_gate_status,
    np.port,
    b.node_id,
    b.benchmark_name,
    lower(coalesce(b.backend, '')) AS chainstate_backend,
    coalesce(
      json_extract(b.settings_json, '$.native_crypto_backend'),
      json_extract(b.result_json, '$.native_crypto_backend'),
      json_extract(a.raw_json, '$.native_crypto_backend'),
      ''
    ) AS native_crypto_backend,
    coalesce(
      json_extract(b.settings_json, '$.native_crypto_available'),
      json_extract(b.result_json, '$.native_crypto_available'),
      json_extract(a.raw_json, '$.native_crypto_available'),
      ''
    ) AS native_crypto_available,
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
    coalesce(json_extract(b.timings_json, '$.canonical_timing_summary.total_ms'), json_extract(b.result_json, '$.elapsed_ms'), -1) AS total_ms,
    coalesce(
      json_extract(b.result_json, '$.telemetry_schema'),
      json_extract(a.raw_json, '$.telemetry_schema'),
      ''
    ) AS telemetry_schema,
    coalesce(
      json_extract(b.result_json, '$.artifact_quality'),
      json_extract(b.settings_json, '$.artifact_quality'),
      'incomplete'
    ) AS artifact_quality,
    coalesce(
      json_extract(b.result_json, '$.telemetry_quality'),
      json_extract(b.settings_json, '$.telemetry_quality'),
      CASE WHEN bg.target_height IN (50000, 100000) THEN 'missing' ELSE 'clean' END
    ) AS telemetry_quality,
    CASE WHEN coalesce(a.raw_json, '') LIKE '%"slow_blocks"%' THEN 1 ELSE 0 END AS has_slow_blocks,
    (
      CASE WHEN coalesce(a.raw_json, '') LIKE '%"p2p_fetch"%' THEN 1 ELSE 0 END +
      CASE WHEN coalesce(a.raw_json, '') LIKE '%"block_parse_validate"%' THEN 1 ELSE 0 END +
      CASE WHEN coalesce(a.raw_json, '') LIKE '%"utxo_load"%' THEN 1 ELSE 0 END +
      CASE WHEN coalesce(a.raw_json, '') LIKE '%"script_verify"%' THEN 1 ELSE 0 END +
      CASE WHEN coalesce(a.raw_json, '') LIKE '%"utxo_apply"%' THEN 1 ELSE 0 END +
      CASE WHEN coalesce(a.raw_json, '') LIKE '%"commit"%' THEN 1 ELSE 0 END +
      CASE WHEN coalesce(a.raw_json, '') LIKE '%"block_connect_store_commit"%' THEN 1 ELSE 0 END
    ) AS long_run_timing_bucket_count,
    coalesce(
      json_extract(b.settings_json, '$.utxo_accounting_policy'),
      CASE
        WHEN coalesce(json_extract(b.result_json, '$.chainstate_utxo_count'), -1) = bg.official_chainstate_utxo_count
        THEN bg.official_utxo_accounting_policy
        ELSE ''
      END
    ) AS utxo_accounting_policy,
    coalesce(json_extract(b.result_json, '$.chainstate_utxo_count'), -1) AS chainstate_utxo_count,
    b.captured_at,
    b.source_artifact_id
  FROM benchmark_gates bg
  JOIN benchmarks b ON b.height = bg.target_height
  JOIN project_node_ports np ON np.node_id = b.node_id
  JOIN artifacts a ON a.artifact_id = b.source_artifact_id
  JOIN evidence_index_entries eie
    ON eie.path = a.path
   AND eie.status = 'current'
   AND eie.gate_id = bg.gate_id
),
classified AS (
  SELECT
    *,
    CASE
      WHEN reported_lane IN ('supporting_5k_p2p', 'baseline_5k_p2p') THEN 'baseline_5k_p2p'
      WHEN reported_lane IN ('supporting_50k_p2p', 'shakedown_50k_p2p') THEN 'shakedown_50k_p2p'
      WHEN reported_lane IN ('primary_100k_p2p', 'performance_100k_p2p') THEN 'performance_100k_p2p'
      WHEN reported_lane <> '' THEN reported_lane
      WHEN peer_mode = 'local_reference_rpc' OR byte_source = 'local_reference_rpc' OR proof_mode IN ('rpc_replay', 'pipeline') THEN replace(official_lane, '_p2p', '_rpc_replay')
      WHEN peer_mode = 'local_reference' OR byte_source = 'local_reference_p2p' THEN official_lane
      ELSE 'diagnostic'
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
      CASE WHEN header_target_height <> official_header_target_height THEN 'header_target_height;' ELSE '' END ||
      CASE WHEN prefetch_depth <> official_prefetch_depth THEN 'prefetch_depth;' ELSE '' END ||
      CASE WHEN script_runner_mode <> official_script_runner_mode THEN 'script_runner_mode;' ELSE '' END ||
      CASE WHEN official_utxo_accounting_policy <> '' AND utxo_accounting_policy <> official_utxo_accounting_policy THEN 'utxo_accounting_policy;' ELSE '' END ||
      CASE WHEN official_chainstate_utxo_count >= 0 AND chainstate_utxo_count <> official_chainstate_utxo_count THEN 'chainstate_utxo_count;' ELSE '' END ||
      CASE WHEN rocksdb_wal_disabled <> wal_disabled_required THEN 'rocksdb_wal;' ELSE '' END ||
      CASE WHEN resume_supported <> resume_supported_required THEN 'resume_supported;' ELSE '' END ||
      CASE WHEN fresh_state_required = 1 AND fresh_state <> 1 THEN 'fresh_state;' ELSE '' END ||
      CASE WHEN target_height IN (50000, 100000) AND telemetry_schema <> 'benchmark.telemetry_tick.v1' THEN 'telemetry_schema;' ELSE '' END ||
      CASE WHEN target_height IN (50000, 100000) AND telemetry_quality <> 'clean' THEN 'telemetry_quality;' ELSE '' END ||
      CASE WHEN target_height IN (50000, 100000) AND has_slow_blocks <> 1 THEN 'slow_blocks;' ELSE '' END ||
      CASE WHEN target_height IN (50000, 100000) AND long_run_timing_bucket_count < 7 THEN 'long_run_timing_buckets;' ELSE '' END ||
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
  chainstate_backend,
  native_crypto_backend,
  native_crypto_available,
  CASE
    WHEN validated_height >= target_height AND result IN ('passed', 'target_reached', 'ok', 'success') THEN 'passed'
    WHEN validated_height >= target_height AND result = '' THEN 'recorded'
    ELSE coalesce(nullif(result, ''), 'recorded')
  END AS gate_status,
  CASE
    WHEN validated_height < target_height OR result IN ('failed', 'blocked', 'error') THEN 'failed'
    WHEN evidence_lane LIKE '%_rpc_replay' THEN 'evidence_only'
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
  utxo_accounting_policy,
  chainstate_utxo_count,
  rocksdb_wal_disabled,
  resume_supported,
  fresh_state,
  binary_gate_status,
  artifact_quality,
  telemetry_quality,
  comparability_notes,
  total_ms,
  captured_at,
  source_artifact_id
FROM scored;

CREATE VIEW IF NOT EXISTS benchmark_gate_matrix AS
WITH ports AS (
  SELECT
    dc.port,
    coalesce(pl.lifecycle_status, CASE WHEN dc.port = 'reference' THEN 'reference' ELSE 'active_contender' END) AS lifecycle_status,
    coalesce(pl.benchmark_scope, 'full_suite') AS benchmark_scope,
    coalesce(pl.retired_at_gate, '') AS retired_at_gate,
    coalesce(pl.retired_reason, '') AS retired_reason
  FROM docker_contracts dc
  LEFT JOIN port_lifecycle pl ON pl.port = dc.port
  WHERE dc.port <> 'reference'
),
ranked_results AS (
  SELECT
    bc.*,
    row_number() OVER (
      PARTITION BY bc.gate_id, bc.port
      ORDER BY CASE bc.comparability_status
                 WHEN 'comparable' THEN 0
                 WHEN 'evidence_only' THEN 1
                 WHEN 'diagnostic' THEN 2
               WHEN 'failed' THEN 3
               ELSE 4
             END,
              CASE WHEN bc.evidence_lane = bc.official_lane THEN 0 ELSE 1 END,
              bc.fresh_state DESC,
               bc.validated_height DESC,
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
  p.lifecycle_status,
  p.benchmark_scope,
  p.retired_at_gate,
  CASE
    WHEN p.lifecycle_status = 'baseline_retired' AND bg.gate_id <> 'baseline_5k' THEN 'retired'
    WHEN p.lifecycle_status = 'active_development' AND bg.gate_id <> 'baseline_5k' AND rr.node_id IS NULL THEN 'active_development'
    WHEN rr.node_id IS NULL THEN 'missing'
    ELSE rr.gate_status
  END AS gate_status,
  CASE
    WHEN p.lifecycle_status = 'baseline_retired' AND bg.gate_id <> 'baseline_5k' THEN 'retired'
    WHEN p.lifecycle_status = 'active_development' AND bg.gate_id <> 'baseline_5k' AND rr.node_id IS NULL THEN 'active_development'
    ELSE coalesce(rr.comparability_status, 'missing')
  END AS comparability_status,
  coalesce(rr.evidence_lane, '') AS evidence_lane,
  coalesce(rr.validated_height, -1) AS validated_height,
  coalesce(rr.header_target_height, -1) AS header_target_height,
  coalesce(rr.runtime_surface, '') AS runtime_surface,
  coalesce(rr.peer_mode, '') AS peer_mode,
  coalesce(rr.byte_source, '') AS byte_source,
  coalesce(rr.proof_mode, '') AS proof_mode,
  coalesce(rr.chainstate_backend, '') AS chainstate_backend,
  coalesce(rr.native_crypto_backend, '') AS native_crypto_backend,
  coalesce(rr.native_crypto_available, '') AS native_crypto_available,
  coalesce(rr.prefetch_depth, -1) AS prefetch_depth,
  coalesce(rr.script_runner_mode, '') AS script_runner_mode,
  coalesce(rr.utxo_accounting_policy, '') AS utxo_accounting_policy,
  coalesce(rr.chainstate_utxo_count, -1) AS chainstate_utxo_count,
  coalesce(rr.rocksdb_wal_disabled, '') AS rocksdb_wal_disabled,
  coalesce(rr.fresh_state, 0) AS fresh_state,
  coalesce(rr.artifact_quality, 'incomplete') AS artifact_quality,
  coalesce(rr.telemetry_quality, CASE WHEN bg.target_height IN (50000, 100000) THEN 'missing' ELSE 'clean' END) AS telemetry_quality,
  CASE
    WHEN p.lifecycle_status = 'baseline_retired' AND bg.gate_id <> 'baseline_5k'
      THEN 'baseline_retired;' || p.retired_reason
    WHEN p.lifecycle_status = 'active_development' AND bg.gate_id <> 'baseline_5k' AND rr.node_id IS NULL
      THEN 'active_development;' || coalesce(p.retired_reason, '')
    ELSE coalesce(rr.comparability_notes, '')
  END AS comparability_notes,
  coalesce(rr.captured_at, '') AS captured_at,
  rr.source_artifact_id
FROM benchmark_gates bg
CROSS JOIN ports p
LEFT JOIN ranked_results rr ON rr.gate_id = bg.gate_id AND rr.port = p.port AND rr.rn = 1;

CREATE VIEW IF NOT EXISTS current_benchmark_results AS
SELECT
  bgm.gate_id,
  bgm.target_label,
  bgm.target_height,
  bgm.benchmark_kind,
  bgm.role,
  bgm.preferred_command_key,
  bgm.port,
  bgm.lifecycle_status,
  bgm.benchmark_scope,
  bgm.gate_status,
  bgm.comparability_status,
  bgm.evidence_lane,
  bgm.validated_height,
  bgm.header_target_height,
  coalesce(json_extract(a.raw_json, '$.validated_hash'), '') AS validated_hash,
  bgm.runtime_surface,
  bgm.peer_mode,
  bgm.byte_source,
  bgm.proof_mode,
  coalesce(bc.peer, '') AS peer,
  bgm.chainstate_backend,
  bgm.native_crypto_backend,
  bgm.native_crypto_available,
  bgm.prefetch_depth,
  bgm.script_runner_mode,
  bgm.rocksdb_wal_disabled,
  coalesce(bc.resume_supported, '') AS resume_supported,
  bgm.fresh_state,
  coalesce(bc.binary_gate_status, '') AS binary_gate_status,
  coalesce(bc.artifact_quality, 'incomplete') AS artifact_quality,
  coalesce(bc.telemetry_quality, CASE WHEN bgm.target_height IN (50000, 100000) THEN 'missing' ELSE 'clean' END) AS telemetry_quality,
  bgm.utxo_accounting_policy,
  bgm.chainstate_utxo_count,
  coalesce(bc.total_ms, -1) AS total_ms,
  coalesce(
    json_extract(a.raw_json, '$.timing_summary.stage_totals_ms.p2p_fetch'),
    json_extract(a.raw_json, '$.pipeline_timing_summary.stage_totals_ms.p2p_fetch'),
    json_extract(a.raw_json, '$.stage_totals_ms.p2p_fetch'),
    -1
  ) AS p2p_fetch_ms,
  coalesce(
    json_extract(a.raw_json, '$.timing_summary.stage_totals_ms.block_parse_validate'),
    json_extract(a.raw_json, '$.pipeline_timing_summary.stage_totals_ms.block_parse_validate'),
    json_extract(a.raw_json, '$.stage_totals_ms.block_parse_validate'),
    -1
  ) AS block_parse_validate_ms,
  coalesce(
    json_extract(a.raw_json, '$.timing_summary.stage_totals_ms.utxo_load'),
    json_extract(a.raw_json, '$.pipeline_timing_summary.stage_totals_ms.utxo_load'),
    json_extract(a.raw_json, '$.stage_totals_ms.utxo_load'),
    -1
  ) AS utxo_load_ms,
  coalesce(
    json_extract(a.raw_json, '$.timing_summary.stage_totals_ms.script_verify'),
    json_extract(a.raw_json, '$.pipeline_timing_summary.stage_totals_ms.script_verify'),
    json_extract(a.raw_json, '$.stage_totals_ms.script_verify'),
    -1
  ) AS script_verify_ms,
  coalesce(
    json_extract(a.raw_json, '$.timing_summary.stage_totals_ms.utxo_apply'),
    json_extract(a.raw_json, '$.pipeline_timing_summary.stage_totals_ms.utxo_apply'),
    json_extract(a.raw_json, '$.stage_totals_ms.utxo_apply'),
    -1
  ) AS utxo_apply_ms,
  coalesce(
    json_extract(a.raw_json, '$.timing_summary.stage_totals_ms.commit'),
    json_extract(a.raw_json, '$.pipeline_timing_summary.stage_totals_ms.commit'),
    json_extract(a.raw_json, '$.stage_totals_ms.commit'),
    -1
  ) AS commit_ms,
  coalesce(
    json_extract(a.raw_json, '$.timing_summary.stage_totals_ms.block_connect_store_commit'),
    json_extract(a.raw_json, '$.pipeline_timing_summary.stage_totals_ms.block_connect_store_commit'),
    json_extract(a.raw_json, '$.stage_totals_ms.block_connect_store_commit'),
    -1
  ) AS block_connect_store_commit_ms,
  bgm.comparability_notes,
  bgm.captured_at,
  bgm.source_artifact_id,
  coalesce(a.path, '') AS artifact_path
FROM benchmark_gate_matrix bgm
LEFT JOIN benchmark_comparability bc
  ON bc.gate_id = bgm.gate_id
 AND bc.port = bgm.port
 AND bc.source_artifact_id = bgm.source_artifact_id
LEFT JOIN artifacts a ON a.artifact_id = bgm.source_artifact_id;

CREATE VIEW IF NOT EXISTS benchmark_leaderboard AS
SELECT
  gate_id,
  rank() OVER (
    PARTITION BY gate_id
    ORDER BY total_ms ASC, port ASC
  ) AS rank,
  port,
  total_ms,
  target_label,
  target_height,
  validated_height,
  validated_hash,
  evidence_lane,
  peer,
  chainstate_backend,
  native_crypto_backend,
  artifact_quality,
  telemetry_quality,
  chainstate_utxo_count,
  p2p_fetch_ms,
  block_parse_validate_ms,
  utxo_load_ms,
  script_verify_ms,
  utxo_apply_ms,
  commit_ms,
  block_connect_store_commit_ms,
  captured_at,
  artifact_path
FROM current_benchmark_results
WHERE gate_status = 'passed'
  AND comparability_status = 'comparable'
  AND artifact_quality = 'canonical'
  AND telemetry_quality = 'clean'
  AND lifecycle_status <> 'baseline_retired'
  AND total_ms > 0;

CREATE VIEW IF NOT EXISTS script_corpus_proof_artifacts AS
WITH proof_rows AS (
  SELECT
    np.port,
    cr.node_id,
    cr.source_artifact_id,
    count(*) AS result_rows,
    sum(CASE WHEN cr.result = 'passed' THEN 1 ELSE 0 END) AS passed_rows,
    sum(CASE WHEN cr.result = 'failed' THEN 1 ELSE 0 END) AS failed_rows,
    max(cr.captured_at) AS captured_at,
    a.path,
    a.raw_json
  FROM conformance_results cr
  JOIN project_node_ports np ON np.node_id = cr.node_id
  JOIN artifacts a ON a.artifact_id = cr.source_artifact_id
  JOIN evidence_index_entries eie
    ON eie.path = a.path
   AND eie.status = 'current'
   AND eie.claim = 'script_corpus'
  WHERE cr.category = 'script_corpus'
  GROUP BY np.port, cr.node_id, cr.source_artifact_id
)
SELECT
  port,
  node_id,
  source_artifact_id,
  path,
  coalesce(json_extract(raw_json, '$.schema'), '') AS schema,
  coalesce(json_extract(raw_json, '$.category'), '') AS category,
  coalesce(json_extract(raw_json, '$.result'), '') AS result,
  coalesce(json_extract(raw_json, '$.runtime_surface'), '') AS runtime_surface,
  coalesce(json_extract(raw_json, '$.verifier.engine'), json_extract(raw_json, '$.verifier'), '') AS verifier,
  coalesce(
    json_extract(raw_json, '$.native_crypto_backend'),
    json_extract(raw_json, '$.verifier.crypto_backend'),
    ''
  ) AS native_crypto_backend,
  coalesce(json_extract(raw_json, '$.fixture_count'), result_rows) AS fixture_count,
  coalesce(json_extract(raw_json, '$.passed'), passed_rows) AS passed,
  coalesce(json_extract(raw_json, '$.failed'), failed_rows) AS failed,
  CASE
    WHEN coalesce(json_extract(raw_json, '$.schema'), '') <> 'port.script_corpus_result.v1' THEN 0
    WHEN coalesce(json_extract(raw_json, '$.port'), '') <> port THEN 0
    WHEN coalesce(json_extract(raw_json, '$.category'), '') <> 'script_corpus' THEN 0
    WHEN coalesce(json_extract(raw_json, '$.result'), '') <> 'passed' THEN 0
    WHEN coalesce(json_extract(raw_json, '$.runtime_surface'), '') = '' THEN 0
    WHEN coalesce(json_extract(raw_json, '$.verifier.engine'), json_extract(raw_json, '$.verifier'), '') = '' THEN 0
    WHEN lower(coalesce(json_extract(raw_json, '$.native_crypto_backend'), json_extract(raw_json, '$.verifier.crypto_backend'), '')) IN ('', 'managed', 'pure', 'pure_ts', 'pure_java', 'pure_csharp', 'not_enabled', 'unavailable', 'none') THEN 0
    WHEN coalesce(json_extract(raw_json, '$.fixture_count'), result_rows) < 45 THEN 0
    WHEN coalesce(json_extract(raw_json, '$.passed'), passed_rows) < 45 THEN 0
    WHEN coalesce(json_extract(raw_json, '$.failed'), failed_rows) <> 0 THEN 0
    ELSE 1
  END AS clean_port_corpus,
  captured_at
FROM proof_rows;

CREATE VIEW IF NOT EXISTS script_corpus_baseline AS
WITH ports AS (
  SELECT port
  FROM docker_contracts
  WHERE port <> 'reference'
),
corpus AS (
  SELECT
    spa.port,
    cr.fixture_id,
    max(CASE WHEN cr.result = 'passed' THEN 1 ELSE 0 END) AS has_pass,
    max(CASE WHEN cr.result = 'failed' THEN 1 ELSE 0 END) AS has_fail,
    max(cr.captured_at) AS latest_captured_at
  FROM conformance_results cr
  JOIN script_corpus_proof_artifacts spa ON spa.source_artifact_id = cr.source_artifact_id
  WHERE cr.category = 'script_corpus'
    AND spa.clean_port_corpus = 1
  GROUP BY spa.port, cr.fixture_id
),
latest_attempt AS (
  SELECT
    port,
    result,
    passed,
    failed,
    captured_at,
    row_number() OVER (
      PARTITION BY port
      ORDER BY captured_at DESC, source_artifact_id DESC
    ) AS rn
  FROM script_corpus_proof_artifacts
  WHERE schema = 'port.script_corpus_result.v1'
    AND category = 'script_corpus'
)
SELECT
  p.port,
  CASE
    WHEN coalesce(sum(c.has_pass), 0) > 0 THEN coalesce(sum(c.has_pass), 0)
    ELSE coalesce(max(la.passed), 0)
  END AS script_passed,
  CASE
    WHEN coalesce(sum(c.has_pass), 0) > 0 THEN coalesce(sum(c.has_fail), 0)
    ELSE coalesce(max(la.failed), 0)
  END AS script_failed,
  CASE
    WHEN coalesce(sum(c.has_pass), 0) >= 45 AND coalesce(sum(c.has_fail), 0) = 0 THEN 'passed'
    WHEN coalesce(sum(c.has_pass), 0) >= 45 THEN 'mixed'
    WHEN coalesce(sum(c.has_pass), 0) > 0 THEN 'partial'
    WHEN coalesce(max(la.result), '') = 'failed' THEN 'failed'
    ELSE 'missing'
  END AS script_corpus_status,
  coalesce(max(c.latest_captured_at), max(la.captured_at), '') AS latest_captured_at
FROM ports p
LEFT JOIN corpus c ON c.port = p.port
LEFT JOIN latest_attempt la ON la.port = p.port AND la.rn = 1
GROUP BY p.port;

CREATE VIEW IF NOT EXISTS port_baseline_5k AS
WITH required_timing AS (
  SELECT 'utxo_load' AS stage
  UNION ALL SELECT 'script_verify'
  UNION ALL SELECT 'utxo_apply'
  UNION ALL SELECT 'commit'
  UNION ALL SELECT 'block_connect_store_commit'
),
timing AS (
  SELECT
    bgm.port,
    count(DISTINCT rt.stage) AS required_timing_buckets
  FROM benchmark_gate_matrix bgm
  JOIN project_node_ports np ON np.port = bgm.port
  JOIN timing_samples ts ON ts.node_id = np.node_id
  JOIN required_timing rt ON rt.stage = ts.stage
  WHERE bgm.gate_id = 'baseline_5k'
    AND ts.source_artifact_id = bgm.source_artifact_id
  GROUP BY bgm.port
),
raw_timing AS (
  SELECT
    bgm.port,
    (CASE WHEN a.raw_json LIKE '%"utxo_load"%' THEN 1 ELSE 0 END) +
    (CASE WHEN a.raw_json LIKE '%"script_verify"%' THEN 1 ELSE 0 END) +
    (CASE WHEN a.raw_json LIKE '%"utxo_apply"%' THEN 1 ELSE 0 END) +
    (CASE WHEN a.raw_json LIKE '%"commit"%' THEN 1 ELSE 0 END) +
    (CASE WHEN a.raw_json LIKE '%"block_connect_store_commit"%' THEN 1 ELSE 0 END) AS required_timing_buckets
  FROM benchmark_gate_matrix bgm
  LEFT JOIN artifacts a ON a.artifact_id = bgm.source_artifact_id
  WHERE bgm.gate_id = 'baseline_5k'
)
SELECT
  bgm.port,
  bgm.gate_id,
  CASE
    WHEN bgm.comparability_status <> 'comparable' THEN 'missing_5k_comparable'
    WHEN lower(bgm.chainstate_backend) <> 'rocksdb' THEN 'missing_rocksdb'
    WHEN lower(coalesce(bgm.native_crypto_backend, '')) IN ('', 'managed', 'pure', 'not_enabled', 'unavailable', 'none') THEN 'missing_native_crypto'
    WHEN scb.script_corpus_status <> 'passed' THEN 'missing_clean_script_corpus'
    WHEN max(coalesce(t.required_timing_buckets, 0), coalesce(rt.required_timing_buckets, 0)) < 5 THEN 'missing_timing_buckets'
    ELSE 'passed'
  END AS baseline_status,
  bgm.gate_status,
  bgm.comparability_status,
  bgm.evidence_lane,
  bgm.validated_height,
  bgm.header_target_height,
  bgm.runtime_surface,
  bgm.peer_mode,
  bgm.byte_source,
  bgm.proof_mode,
  bgm.chainstate_backend,
  bgm.native_crypto_backend,
  bgm.native_crypto_available,
  coalesce(scb.script_corpus_status, 'missing') AS script_corpus_status,
  coalesce(scb.script_passed, 0) AS script_passed,
  coalesce(scb.script_failed, 0) AS script_failed,
  bgm.prefetch_depth,
  bgm.script_runner_mode,
  bgm.rocksdb_wal_disabled,
  bgm.fresh_state,
  bgm.utxo_accounting_policy,
  bgm.chainstate_utxo_count,
  max(coalesce(t.required_timing_buckets, 0), coalesce(rt.required_timing_buckets, 0)) AS required_timing_buckets,
  bgm.comparability_notes,
  bgm.captured_at,
  bgm.source_artifact_id
FROM benchmark_gate_matrix bgm
LEFT JOIN script_corpus_baseline scb ON scb.port = bgm.port
LEFT JOIN timing t ON t.port = bgm.port
LEFT JOIN raw_timing rt ON rt.port = bgm.port
WHERE bgm.gate_id = 'baseline_5k';

CREATE VIEW IF NOT EXISTS critical_test_domain_coverage AS
WITH ports AS (
  SELECT
    dc.port,
    dc.node_id,
    coalesce(pl.lifecycle_status, CASE WHEN dc.port = 'reference' THEN 'reference' ELSE 'active_contender' END) AS lifecycle_status,
    coalesce(pl.benchmark_scope, CASE WHEN dc.port = 'reference' THEN 'reference_only' ELSE 'full_suite' END) AS benchmark_scope
  FROM docker_contracts dc
  LEFT JOIN port_lifecycle pl ON pl.port = dc.port
  WHERE dc.port <> 'reference'
),
domains(domain, purpose) AS (
  VALUES
    ('script_verification', 'Shared script corpus and spend-path interpreter coverage'),
    ('sighash_taproot_witness', 'Sighash, witness, and Taproot regression posture'),
    ('utxo_apply_undo_accounting', 'UTXO apply, undo, and core_spendable_v1 accounting posture'),
    ('block_connect', 'Validated block-connect proof posture'),
    ('rocksdb_persistence_restart', 'RocksDB runtime truth and persistence posture'),
    ('p2p_fetch_handshake', 'P2P fetch and handshake product posture'),
    ('node_status_reporting', 'Node status and reporting smoke posture')
),
storage AS (
  SELECT
    np.port,
    max(CASE WHEN cr.fixture_id = 'storage.rocksdb_runtime_truth' AND cr.result = 'passed' THEN 1 ELSE 0 END) AS has_storage_proof
  FROM conformance_results cr
  JOIN project_node_ports np ON np.node_id = cr.node_id
  GROUP BY np.port
),
current_claims AS (
  SELECT port, count(*) AS current_evidence_count
  FROM evidence_index_entries
  WHERE status = 'current'
  GROUP BY port
),
manual_claims AS (
  SELECT
    port,
    domain,
    status,
    evidence,
    notes,
    row_number() OVER (
      PARTITION BY port, domain
      ORDER BY (source_artifact_id IS NOT NULL) DESC, source_artifact_id DESC
    ) AS rn
  FROM test_domain_claims
)
SELECT
  p.port,
  p.node_id,
  p.lifecycle_status,
  p.benchmark_scope,
  d.domain,
  d.purpose,
  coalesce(mc.status,
    CASE d.domain
      WHEN 'script_verification' THEN
        CASE WHEN coalesce(scb.script_corpus_status, '') = 'passed' THEN 'covered' ELSE 'missing' END
      WHEN 'sighash_taproot_witness' THEN
        CASE WHEN coalesce(scb.script_corpus_status, '') = 'passed' THEN 'covered_by_script_corpus' ELSE 'missing' END
      WHEN 'utxo_apply_undo_accounting' THEN
        CASE
          WHEN coalesce(pb.utxo_accounting_policy, '') = 'core_spendable_v1'
           AND coalesce(pb.chainstate_utxo_count, -1) = 4574 THEN 'covered'
          ELSE 'missing'
        END
      WHEN 'block_connect' THEN
        CASE WHEN coalesce(pb.comparability_status, '') = 'comparable' THEN 'covered' ELSE 'missing' END
      WHEN 'rocksdb_persistence_restart' THEN
        CASE
          WHEN coalesce(st.has_storage_proof, 0) = 1 THEN 'covered'
          WHEN lower(coalesce(pb.chainstate_backend, '')) = 'rocksdb' THEN 'covered_by_baseline'
          ELSE 'missing'
        END
      WHEN 'p2p_fetch_handshake' THEN
        CASE
          WHEN coalesce(pb.peer_mode, '') = 'local_reference'
           AND coalesce(pb.proof_mode, '') = 'p2p_sync'
           AND coalesce(pb.comparability_status, '') = 'comparable' THEN 'covered'
          ELSE 'missing'
        END
      WHEN 'node_status_reporting' THEN
        CASE WHEN coalesce(cc.current_evidence_count, 0) > 0 THEN 'covered' ELSE 'missing' END
      ELSE 'missing'
    END
  ) AS domain_status,
  coalesce(mc.evidence,
    CASE d.domain
      WHEN 'script_verification' THEN coalesce(scb.script_corpus_status, 'missing')
      WHEN 'sighash_taproot_witness' THEN coalesce(scb.script_corpus_status, 'missing')
      WHEN 'utxo_apply_undo_accounting' THEN coalesce(pb.utxo_accounting_policy, '')
      WHEN 'block_connect' THEN coalesce(pb.evidence_lane, '')
      WHEN 'rocksdb_persistence_restart' THEN CASE WHEN coalesce(st.has_storage_proof, 0) = 1 THEN 'storage.rocksdb_runtime_truth' ELSE coalesce(pb.chainstate_backend, '') END
      WHEN 'p2p_fetch_handshake' THEN trim(coalesce(pb.peer_mode, '') || ':' || coalesce(pb.proof_mode, ''), ':')
      WHEN 'node_status_reporting' THEN 'current_evidence=' || coalesce(cc.current_evidence_count, 0)
      ELSE ''
    END
  ) AS evidence,
  coalesce(
    CASE WHEN mc.domain IS NOT NULL THEN 'manual_claim' END,
    CASE d.domain
      WHEN 'script_verification' THEN 'script_corpus'
      WHEN 'sighash_taproot_witness' THEN 'script_corpus'
      WHEN 'utxo_apply_undo_accounting' THEN 'baseline_5k'
      WHEN 'block_connect' THEN 'baseline_5k'
      WHEN 'rocksdb_persistence_restart' THEN
        CASE WHEN coalesce(st.has_storage_proof, 0) = 1 THEN 'storage_proof' ELSE 'baseline_5k' END
      WHEN 'p2p_fetch_handshake' THEN 'baseline_5k'
      WHEN 'node_status_reporting' THEN 'current_evidence'
      ELSE ''
    END
  ) AS evidence_source_type,
  coalesce(mc.notes, '') AS notes
FROM ports p
CROSS JOIN domains d
LEFT JOIN script_corpus_baseline scb ON scb.port = p.port
LEFT JOIN port_baseline_5k pb ON pb.port = p.port
LEFT JOIN storage st ON st.port = p.port
LEFT JOIN current_claims cc ON cc.port = p.port
LEFT JOIN manual_claims mc ON mc.port = p.port AND mc.domain = d.domain AND mc.rn = 1;

CREATE VIEW IF NOT EXISTS test_coverage_matrix AS
WITH ports AS (
  SELECT
    dc.port,
    dc.node_id,
    coalesce(pl.lifecycle_status, CASE WHEN dc.port = 'reference' THEN 'reference' ELSE 'active_contender' END) AS lifecycle_status,
    coalesce(pl.benchmark_scope, CASE WHEN dc.port = 'reference' THEN 'reference_only' ELSE 'full_suite' END) AS benchmark_scope
  FROM docker_contracts dc
  LEFT JOIN port_lifecycle pl ON pl.port = dc.port
  WHERE dc.port <> 'reference'
),
commands AS (
  SELECT
    port,
    max(CASE WHEN command_key = 'test_unit' THEN supported ELSE 0 END) AS unit_supported,
    max(CASE WHEN command_key = 'test_unit' THEN command ELSE '' END) AS unit_command,
    max(CASE WHEN command_key = 'test_coverage' THEN supported ELSE 0 END) AS coverage_supported,
    max(CASE WHEN command_key = 'test_coverage' THEN command ELSE '' END) AS coverage_command
  FROM test_commands
  GROUP BY port
),
coverage_runs AS (
  SELECT port, command_key, result, captured_at
  FROM (
    SELECT
      tr.*,
      row_number() OVER (
        PARTITION BY tr.port
        ORDER BY tr.captured_at DESC, tr.command_key
      ) AS rn
    FROM latest_test_runs tr
    WHERE tr.command_key IN ('test_coverage', 'test_coverage_core')
  )
  WHERE rn = 1
),
domains AS (
  SELECT
    port,
    sum(CASE WHEN domain_status = 'missing' THEN 1 ELSE 0 END) AS missing_domain_count,
    count(*) AS domain_count
  FROM critical_test_domain_coverage
  GROUP BY port
)
SELECT
  p.port,
  p.node_id,
  p.lifecycle_status,
  p.benchmark_scope,
  coalesce(c.unit_supported, 0) AS unit_supported,
  coalesce(c.unit_command, '') AS unit_command,
  coalesce(utr.result, '') AS latest_unit_result,
  coalesce(utr.captured_at, '') AS latest_unit_captured_at,
  coalesce(c.coverage_supported, 0) AS coverage_supported,
  coalesce(c.coverage_command, '') AS coverage_command,
  coalesce(ctr.result, '') AS latest_coverage_result,
  coalesce(ctr.captured_at, '') AS latest_coverage_captured_at,
  coalesce(lcs.tool, '') AS coverage_tool,
  coalesce(lcs.line_percent, -1) AS line_percent,
  coalesce(lcs.branch_percent, -1) AS branch_percent,
  coalesce(lcs.function_percent, -1) AS function_percent,
  coalesce(lcs.statement_percent, -1) AS statement_percent,
  coalesce(d.domain_count, 0) AS domain_count,
  coalesce(d.missing_domain_count, 0) AS missing_domain_count,
  CASE
    WHEN p.lifecycle_status = 'baseline_retired' THEN 'baseline_retired'
    WHEN p.lifecycle_status = 'active_development' THEN
      CASE
        WHEN coalesce(utr.result, '') = 'failed' THEN 'unit_result_failed'
        WHEN coalesce(c.unit_supported, 0) = 1 THEN 'inventory_ready'
        ELSE 'inventory_gap'
      END
    WHEN coalesce(c.unit_supported, 0) = 0 THEN 'missing_unit_test_command'
    WHEN coalesce(utr.result, '') = 'failed' THEN 'unit_result_failed'
    ELSE 'baseline_par'
  END AS baseline_par_status,
  CASE
    WHEN lcs.port IS NULL THEN 'optional_coverage_not_captured'
    ELSE 'optional_coverage_metrics_available'
  END AS coverage_control_status
FROM ports p
LEFT JOIN commands c ON c.port = p.port
LEFT JOIN latest_test_runs utr ON utr.port = p.port AND utr.command_key = 'test_unit'
LEFT JOIN coverage_runs ctr ON ctr.port = p.port
LEFT JOIN latest_coverage_summaries lcs ON lcs.port = p.port
LEFT JOIN domains d ON d.port = p.port;

CREATE VIEW IF NOT EXISTS consensus_rule_summary AS
SELECT
  chain,
  category,
  status,
  count(*) AS rule_count,
  min(CASE WHEN blocker_height >= 0 THEN blocker_height ELSE first_height END) AS min_height,
  max(CASE WHEN blocker_height >= 0 THEN blocker_height ELSE first_height END) AS max_height
FROM consensus_rules
GROUP BY chain, category, status;

CREATE VIEW IF NOT EXISTS consensus_stage_targets AS
SELECT 'corpus' AS stage, 0 AS target_height, 0 AS requires_5k_baseline
UNION ALL SELECT '5k', 5000, 1
UNION ALL SELECT '50k', 50000, 1
UNION ALL SELECT '100k', 100000, 1
UNION ALL SELECT 'tip_once', -1, 1
UNION ALL SELECT 'tip_maintenance', -1, 1;

CREATE VIEW IF NOT EXISTS consensus_runway AS
WITH ports AS (
  SELECT
    dc.port,
    coalesce(pl.lifecycle_status, 'active_contender') AS lifecycle_status,
    coalesce(pl.benchmark_scope, 'full_suite') AS benchmark_scope,
    coalesce(pl.retired_at_gate, '') AS retired_at_gate,
    coalesce(pl.retired_reason, '') AS retired_reason
  FROM docker_contracts dc
  LEFT JOIN port_lifecycle pl ON pl.port = dc.port
  WHERE dc.port <> 'reference'
),
sync_evidence AS (
  SELECT
    p.port,
    max(
      coalesce(lps.validated_height, -1),
      coalesce((SELECT max(max_height) FROM benchmark_summary bs WHERE bs.port = p.port), -1)
    ) AS max_validated_height,
    coalesce(lps.header_height, -1) AS header_height,
    coalesce(lps.sync_status, '') AS sync_status,
    coalesce(lps.source_artifact_id, '') AS status_source_artifact_id
  FROM ports p
  LEFT JOIN latest_port_status lps ON lps.port = p.port
),
latest_corpus_attempt AS (
  SELECT
    port,
    runtime_surface,
    native_crypto_backend,
    source_artifact_id,
    row_number() OVER (
      PARTITION BY port
      ORDER BY captured_at DESC, source_artifact_id DESC
    ) AS rn
  FROM script_corpus_proof_artifacts
  WHERE schema = 'port.script_corpus_result.v1'
    AND category = 'script_corpus'
),
clean_corpus AS (
  SELECT
    scb.port,
    CASE WHEN scb.script_corpus_status = 'passed' THEN 1 ELSE 0 END AS has_clean_corpus,
    scb.script_passed AS passed,
    scb.script_failed AS failed,
    coalesce(lca.runtime_surface, '') AS runtime_surface,
    coalesce(lca.native_crypto_backend, '') AS native_crypto_backend,
    coalesce(lca.source_artifact_id, '') AS source_artifact_id
  FROM script_corpus_baseline scb
  LEFT JOIN latest_corpus_attempt lca ON lca.port = scb.port AND lca.rn = 1
  ),
  stage_gate_evidence AS (
    SELECT
      port,
      CASE gate_id
        WHEN 'shakedown_50k' THEN '50k'
        WHEN 'performance_100k' THEN '100k'
        ELSE ''
      END AS stage,
      gate_status,
      comparability_status,
      validated_height,
      source_artifact_id
    FROM benchmark_gate_matrix
    WHERE gate_id IN ('shakedown_50k', 'performance_100k')
  ),
  open_blockers AS (
  SELECT
    cst.stage,
    count(cbs.height) AS open_blocker_count,
    group_concat(cbs.height) AS open_blocker_heights
  FROM consensus_stage_targets cst
  LEFT JOIN current_blocker_state cbs
   ON cbs.status IN ('open', 'blocked')
   AND cst.target_height >= 0
   AND cbs.height > 0
   AND cbs.height <= cst.target_height
  GROUP BY cst.stage
)
SELECT
  p.port,
  p.lifecycle_status,
  p.benchmark_scope,
  p.retired_at_gate,
  cst.stage,
  cst.target_height,
  CASE
    WHEN coalesce(cc.has_clean_corpus, 0) <> 1 THEN 'missing_clean_script_corpus'
    WHEN coalesce(ob.open_blocker_count, 0) > 0 THEN 'open_blockers'
    WHEN p.lifecycle_status = 'baseline_retired' AND cst.stage NOT IN ('corpus', '5k') THEN 'retired_at_baseline'
    WHEN p.lifecycle_status = 'active_development' AND cst.stage NOT IN ('corpus', '5k') THEN 'active_development'
    WHEN cst.stage = 'corpus' THEN 'passed'
    WHEN cst.stage = '5k' AND coalesce(pb.baseline_status, '') <> 'passed' THEN 'missing_5k_baseline'
    WHEN cst.stage IN ('50k', '100k') AND NOT (coalesce(sge.gate_status, '') = 'passed' AND coalesce(sge.comparability_status, '') = 'comparable') THEN 'missing_stage_proof'
    WHEN cst.stage = 'tip_once' AND NOT (se.sync_status = 'blocks_current' AND se.max_validated_height >= se.header_height AND se.header_height > 0) THEN 'missing_tip_once_proof'
    WHEN cst.stage = 'tip_maintenance' AND NOT (se.sync_status = 'blocks_current' AND se.max_validated_height >= se.header_height AND se.header_height > 0) THEN 'missing_tip_maintenance_proof'
    ELSE 'passed'
  END AS runway_status,
  coalesce(cc.has_clean_corpus, 0) AS has_clean_script_corpus,
  coalesce(cc.passed, 0) AS script_passed,
  coalesce(cc.failed, 0) AS script_failed,
  coalesce(cc.runtime_surface, '') AS script_runtime_surface,
  coalesce(cc.native_crypto_backend, '') AS script_native_crypto_backend,
  coalesce(pb.baseline_status, '') AS baseline_5k_status,
  coalesce(pb.comparability_status, '') AS baseline_5k_comparability,
  coalesce(sge.gate_status, '') AS stage_gate_status,
  coalesce(sge.comparability_status, '') AS stage_gate_comparability,
  coalesce(se.max_validated_height, -1) AS max_validated_height,
  coalesce(se.header_height, -1) AS header_height,
  coalesce(se.sync_status, '') AS sync_status,
  coalesce(ob.open_blocker_count, 0) AS open_blocker_count,
  coalesce(ob.open_blocker_heights, '') AS open_blocker_heights,
  coalesce(cc.source_artifact_id, '') AS script_source_artifact_id,
  coalesce(pb.source_artifact_id, '') AS baseline_source_artifact_id,
  coalesce(sge.source_artifact_id, '') AS stage_source_artifact_id,
  coalesce(se.status_source_artifact_id, '') AS status_source_artifact_id
FROM ports p
CROSS JOIN consensus_stage_targets cst
LEFT JOIN clean_corpus cc ON cc.port = p.port
LEFT JOIN port_baseline_5k pb ON pb.port = p.port
LEFT JOIN stage_gate_evidence sge ON sge.port = p.port AND sge.stage = cst.stage
LEFT JOIN sync_evidence se ON se.port = p.port
LEFT JOIN open_blockers ob ON ob.stage = cst.stage;
