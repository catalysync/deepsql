# DeepSQL for Crate: evaluation

Fork `catalysync/deepsql`, branch `crate/main`, based on upstream `27d07ea`
(2026-10). Read on 2026-10-23. Paths are relative to the repo root; backend
paths drop the `backend/src/main/java/com/dbaagent/` prefix where unambiguous.
**[V]** = verified in code or by running it; **[I]** = inferred.

## TL;DR

- **Recommendation: use it occasionally, on the owner's Mac, never on the shared
  4 GB box.** Start the stack on demand, open an SSM port-forward to a
  dedicated read-only Postgres role, run a review session, then tear it down.
  Our database is too small for it to be a standing service.
- **It sends real data to the LLM.** That includes up to 10 result rows per chat
  answer (50 in the agent composer), sampled column values, query text with
  literals, EXPLAIN plans and Postgres error text. There is no global
  "no rows to the LLM" switch. Admins are exempt from the only redaction feature.
  The only real control is what the database role can `SELECT`.
- **It can write.** Index Apply runs real `CREATE/DROP INDEX CONCURRENTLY`,
  several EXPLAIN ANALYZE paths are unguarded, and the JDBC `setReadOnly(true)`
  does nothing under autocommit [I]. A role with
  `default_transaction_read_only=on` is mandatory, not optional.
- **Telemetry:** upstream's PostHog sender was dormant (no key ships) but one env
  var away. It is deleted on `crate/main`, along with every other phone-home we
  found across the backend, web UI, desktop app, CLI, installer and the bundled
  Hermes agent. See [TELEMETRY-REMOVED.md](TELEMETRY-REMOVED.md).
- **Footprint:** we measured the backend at **~950 MB RSS idle with `-Xmx1g`**,
  0.3% CPU. Upstream hard-codes `-Xmx3g` and documents "~4 GB for Docker". The
  full-stack `docker stats` run could not be done: the Mac's disk was full
  (about 1 GB free). See [Footprint](#footprint).
- **Anthropic works on the backend side through the OpenAI-compatible endpoint**
  as long as the Responses API is forced off. The agent container needed a
  one-line fix, now on the branch, or it silently switches to native Messages.
  There are no embeddings at Anthropic, so we use local Ollama
  (`nomic-embed-text`).

## 1. Architecture

`docker-compose.yml` defines five services. They are built from this checkout;
upstream publishes no images.

| Service | What it is | What it does |
|---|---|---|
| `postgres` (`pgvector/pgvector:pg18`) | The **vault** DB, `dba_agent` | App state: users, encrypted target credentials, chat history, "brain" knowledge, `rag_documents` (pgvector), LLM usage ledger, scheduled tasks. The init scripts also create two demo DBs (`demo_shop`, `acme_erp`) inside it (`docker/postgres/init/10_*.sql`, `11_*.sql`). |
| `valkey` | Redis-compatible cache | RAG and connection-access caching. Despite the docs calling it optional, **it is required**: without it, connection access checks, EXPLAIN and brain init fail with "Unable to connect to Redis" [V, observed]. |
| `backend` | Spring Boot 4 / Java 25, about 911 main classes | Everything: auth/RBAC, connection vault, JDBC to targets (optional SSH tunnel), slow-query analysis from `pg_stat_statements`, EXPLAIN analysis, index advisor (+HypoPG), migration-risk analyzer, "brain" (schema scan, profiling, RAG ingestion), chat/NL→SQL, dashboards broker, scheduled jobs (db-scheduler), Slack/email, LLM proxy at `/api/llm/v1`. |
| `deepsql-agent` | Python container. NousResearch **hermes-agent** (runtime) and **hermes-webui** (HTTP API on :8787) are cloned at build time, plus a provisioner (:8788) and the Node MCP server | Powers the Agent tab and AI dashboards. Hermes calls the LLM directly and calls DeepSQL through the MCP server (`mcp/deepsql-phase1-server.js`, stdio, bearer token). It never sees database credentials. |
| `frontend` | React 19 + Vite, served by nginx | SPA. Proxies `/api` to the backend and `/agent-api` to the agent; the agent route is gated by nginx `auth_request` against `/api/auth/me`. |

Outside Compose:
- **`mcp/`**: the `deepsql` CLI and stdio MCP server, for Claude Desktop, Cursor and others. It wraps the backend API.
- **`desktop/`**: an Electron thin client. It points a webview at a DeepSQL server directly or over an SSH tunnel, and does not bundle the UI.

## 2. Data flow

### 2.1 What goes to the LLM

All of the following are [V] unless marked otherwise.

| Data | Sent? | Where |
|---|---|---|
| Schema: tables, columns, DDL, relationships | Yes | `service/ChatContextAssembler.java:464,731` |
| **Query result rows** | **Yes**, up to 10 rows, every column, as text, in answer, repair and "sparse result" prompts | `service/SqlExecutionPipeline.java:528-546` (used at `:262,420,517`), `service/ChatService.java:1388`, `service/agent/ResultSynthesisTool.java:193,217`, `service/agent/UniversalChatTool.java:1709` |
| | Up to 50 rows | `service/agent/AgentAnswerComposer.java:375-398` |
| **Sampled column values (background)** | **Yes**, for up to 50 tables of ≤1M rows: one sample value per column, MIN/MAX, and the top-10 values of columns with ≤200 distinct values. They are put in the schema-description prompt as `range: … top: … e.g. <value>` | `service/brain/analysis/ColumnProfilingService.java:194,216,237,290`; `service/SchemaDescriptionService.java:374,709-721` |
| DISTINCT column values at query time | Fetched (`SELECT DISTINCT col … LIMIT n`). That they go into the generation prompt is [I] | `service/pipeline/ColumnValueFetcher.java:92`; nightly `service/brain/keycolumn/ColumnValueCollectionService.java:442` |
| Query text from `pg_stat_statements`, including literal-bearing sample queries | Yes, in the optimizer prompt | `service/QueryOptimizationService.java:1369,1391,1410` |
| EXPLAIN plans | Yes, in the plan-summary prompt | `service/ExplainPlanService.java:256-274` |
| Postgres error messages | Yes, in repair prompts. These can quote values, e.g. `Key (email)=(…)` [I] | `service/SqlExecutionPipeline.java:158,462` |
| Agent / MCP path | Full result rows go back to Hermes, so they reach the LLM [I]. The dashboard agent is told to "READ the rows" | `controller/McpController.java:76-84`, `service/DashboardAgentService.java:265` |
| `pg_stats` (`most_common_vals`, histograms) | No; never queried | — |
| Target DB credentials | No | MCP has no DB driver (`mcp/src/commands/query.js:85`); the provisioner hands Hermes only a DeepSQL API token (`scripts/local-agent-provisioner.py:116-189`) |

Embeddings (text sent to the embedding endpoint) cover schema DDL, query
examples, docs and knowledge. They also include **`COLUMN_VALUES` documents that
contain real top values** (`service/TrainingService.java:403-420`), plus
column-value caches and plan patterns. With our overlay those go to a local
Ollama and never leave the machine.

### 2.2 Can rows be kept out of prompts?

**No global switch.** What exists:

- **Per-user/per-connection chat access policy.** Settings are `redact_mode`, denied tables and columns, and blocked categories (`model/ConnectionChatAccessPolicy.java:32-54`). Values become `[redacted:N]` (`service/UserDataAccessPolicyService.java:330-388`, applied at `service/QueryExecutorService.java:802`). It has three gaps:
  - **Admins are exempt** (`service/ConnectionChatAccessPolicyService.java:86-93`). The owner is the admin.
  - **Background profiling runs as `QueryExecutionContext.internal()` and is never redacted.**
  - PII categories are guessed from column names only (`service/brain/classification/DataSensitivityClassificationService.java:129-133`).
- **Partial knobs, set to the privacy side in `docker-compose.crate.yml`:**
  - `spring.ai.column-values.background-sampling.enabled` (`application.properties:243`)
  - `app.pipeline.enabled` (`:232`)
  - `brain.profile.max-tables` (`:330`). Setting it to 0 disabling profiling is [I].
  - Expect weaker NL→SQL quality with these off.
- **The real control is the role.** Grant `SELECT` only on the tables you are
  willing to send to Anthropic. Use column-level grants to drop `email`, `phone`,
  addresses, tokens and the like. Chat answers can only contain what the role
  can read.

### 2.3 Does it write to the target DB?

**Yes. These paths exist [V]:**
- **Index Apply** runs real DDL: `CREATE/DROP INDEX CONCURRENTLY` (`service/IndexRecommendationApplyService.java:197`), triggered by `controller/IndexRecommendationController.java:173` with `mode=APPLY&confirm=true`.
- **HypoPG dry-run.** `hypopg_create_index` is session-only (`IndexRecommendationApplyService.java:275`). It needs the extension, which we won't install.
- **Kill session:** `pg_terminate_backend` (`service/ActiveQueryService.java:213`, `service/LockContentionService.java:304`).
- **EXPLAIN ANALYZE executes the statement**, in several places:
  - Unguarded, with no mutation check, in `controller/SlowQueryController.java:1512` and `controller/QueryPlanController.java:49` → `service/QueryPlanCacheService.java:162`.
  - In `service/IndexRecommendationApplyService.java:368` (APPLY_AND_MEASURE).
  - Guarded in `controller/ExplainController.java:91-104`. `service/QueryOptimizationService.java:267` runs it for SELECT only.
- **LLM-written query rewrites are executed** with `LIMIT 5` and no guard (`service/QueryOptimizationService.java:1744`).
- **Editor/MCP:** admins can run DML and non-destructive DDL after a confirmation step.

**Not executed:** `ALTER SYSTEM` suggestions are display-only, `pg_stat_statements_reset` is never called, and migration review only parses DDL and reads `pg_class`.

**`setup_permissions.sql`** is a manual vendor script, not run by the app. It is
also wrong for us: it grants `SELECT` and `pg_read_all_stats` to `postgres` and
runs `CREATE EXTENSION`. Use the role in §5 instead.

**How read-only is enforced:**
1. **A JSqlParser classifier plus a regex guard** (`service/QueryExecutionPolicyService.java:110-140`, `service/McpSqlGuardService.java:66-140`). It blocks writable CTEs, multi-statement SQL, `dblink`, `pg_read_file` and `lo_*`. It does not block `setval`, advisory locks, or user functions that write [I].
2. **`connection.setReadOnly(true)`** (`service/QueryExecutorService.java:635-645`). With pgjdbc's default `readOnlyMode=transaction` and autocommit on, this is a no-op [I]. Internal paths skip it entirely.

**Can it run strictly read-only?** Yes, with a role that has `SELECT` (on
chosen tables), `pg_read_all_stats` and `default_transaction_read_only=on`.
Every write path above is then refused by Postgres itself. Loss of function:
- Index Apply
- Killing sessions (needs `pg_signal_backend`)
- Editor DML
- EXPLAIN ANALYZE of writes, which fails, as it should

In our run (§8), the connection test reported all required privileges present
for exactly that role.

### 2.4 Credential storage

- **Encryption:** AES-256-GCM, 12-byte random IV, AAD = connection id + field name. The envelope is `DBA1` + key id + IV + ciphertext (`security/EncryptionService.java:21-28,57-84`).
- **What is encrypted:** host, port, database, user, password and SSL/SSH material are each encrypted separately (`service/CredentialService.java:47-72`). They are stored in the vault's `encrypted_credentials` table.
- **Keys** come from `ENCRYPTION_KEYS=id:base64,…` + `ENCRYPTION_KEY_ID`, or `ENCRYPTION_KEY`. Startup fails without one.
- **Rotation:** old key ids still decrypt. There is no bulk re-encrypt; a value is re-encrypted only when its connection is edited (`CredentialService.java:389`).
- **Where the key lives:** in `.env` beside the data. Anyone with the box or the Mac and that file can decrypt. For an on-demand Mac setup that is acceptable; keep `.env` mode 600.

## 3. Every outbound network call

We grepped every hard-coded URL in non-test source and audited the HTTP clients
in the backend. Hermes was cloned at the pinned tags and audited separately.
The table describes upstream behaviour; "Status" is the state on `crate/main`.

### Phone-home / vendor

| # | Call | Where (upstream) | When | Status on `crate/main` |
|---|---|---|---|---|
| 1 | PostHog `POST https://us.i.posthog.com/batch/`: install id, version, company name (inferred from the admin email domain), counters, `$groupidentify` | `service/telemetry/PostHogDirectSink.java:45-118`; host default `TelemetryProperties.java:20`; wiring `config/TelemetryConfig.java:30-44` | Every 10 s flush, `install.bootstrapped`, 30-min heartbeat. Only if `deepsql.telemetry.posthog-project-key` / `DEEPSQL_TELEMETRY_POSTHOG_PROJECT_KEY` is set (no key ships) | **Deleted**; sink is always NoOp |
| 2 | Install identity + heartbeat producers | `service/telemetry/InstallTelemetryBootstrap.java`, `InstallHeartbeatJob.java` | Startup / every 30 min | **Not beans any more** |
| 3 | Monaco editor from `cdn.jsdelivr.net` | default of `@monaco-editor/loader` (no `loader.config` in `src/`) | Opening Editor / Explain / Dashboard source | **Bundled** (`src/lib/monacoEditor.js`) |
| 4 | Google Fonts (Maven Pro) | `src/index.css:1` | Every page load | **Bundled** via `@fontsource` |
| 5 | GitHub Releases API from the browser | `src/pages/Download.jsx:116` | Visiting `/download` | **Off** |
| 6 | Desktop auto-update (electron-updater) | `desktop/src/main/updater.js:17-57` | App launch, if a feed is configured | **Hard off** |
| 7 | Desktop Google Fonts | `desktop/src/renderer/shared/theme.css:10`, CSP in `desktop/src/renderer/*/index.html:7` | Launcher/chrome windows | **Removed** |
| 8 | npm registry version check | `mcp/src/commands/_agent_intro.js:196` | Interactive CLI agent start | **Off** |
| 9 | `npm i -g @deepsql/mcp`, `npm view` | `scripts/self-host/install.sh:507-543` | Installer | **Off** |
| 10 | Hermes webui update check (`git fetch` to github.com / `api.github.com`) | `hermes-webui api/updates.py:1235`, `:813-822` | UI load, every 30 min | **Disabled + `.git` removed** (`agent/webui/crate-no-egress.sh`) |
| 11 | Hermes webui CDN: prism (+autoloader grammars), xterm, pdf.js, mermaid from jsDelivr | `hermes-webui static/index.html:73,91-96`, `boot.js:2663`, `ui.js:18276,18338` | Agent webui page load / render | **Vendored at build** |
| 12 | Hermes webui CSP `img-src https:`: model output can embed any image URL (exfiltration path) | `hermes-webui api/helpers.py:79` | Per message | **Tightened** |
| 13 | Hermes webui extension registry (`hermes-webui.github.io`) | `hermes-webui api/extensions.py:1894` | Extensions panel | **Disabled** |
| 14 | Hermes lazy `pip install` from PyPI (e.g. `anthropic` SDK) | `hermes-agent tools/lazy_deps.py:501-536` | First use of an optional feature | **Off** |
| 15 | Hermes model catalog / models.dev | `hermes-agent config_defaults.py:2690`, `agent/models_dev.py:56` | `/model` command; models.dev was inactive for the custom provider | **Off** (belt and braces) |

### User-configured, kept (inactive in our setup)

| Call | Where | Active only when |
|---|---|---|
| **LLM chat** (`/chat/completions`) | `llm/openai/OpenAiCompatibleChatProvider.java`, `llm/openai/ResponsesApiChatModel.java:166-194`; agent: `docker-entrypoint.sh` | Always: this is the product |
| LLM embeddings (`/embeddings`) | `llm/openai/OpenAiCompatibleEmbeddingProvider.java:20-21,59` (default `api.openai.com`) | Embedding provider set (ours: local Ollama) |
| `/api/llm/v1` relay (server-side, to the chat endpoint) | `controller/LlmProxyController.java:31-102` | A logged-in user or MCP token calls it |
| Google OAuth (`accounts.google.com`, `oauth2.googleapis.com`, `openidconnect.googleapis.com`) | `service/PasswordlessAuthService.java` | `SECURITY_GOOGLE_ENABLED=true` |
| Slack (Bolt socket mode) | `service/SlackBotService.java` | `SLACK_ENABLED=true` |
| SMTP | `application.properties:277-284` | `EMAIL_*` set |
| Webhooks | `service/WebhookService.java` | A webhook is configured |
| Datadog logs API | `service/DatadogLogFetchService.java` | A Datadog slow-log source is added |
| S3 / CloudWatch Logs / Azure Blob / GCP Logging / Elasticsearch | `service/S3LogFetchService.java`, `ElasticsearchLogFetchService.java`, AWS / GCP / Azure SDKs in `pom.xml:260-293` | A slow-log source of that type is added |
| Azure AI Search | `azure.search.*` | `AZURE_SEARCH_ENABLED=true` (we set false) |
| OTLP traces to `http://localhost:4318` | `application.properties:265-267` | Default profile only; `prod` disables export (`application-prod.properties:142`) |
| optd sidecar `http://localhost:8088` | `service/optd/OptdClient.java:23-24` | Local only |

### Install path downloads

- **`curl -fsSL https://deepsql.ai/install.sh | bash`** (`scripts/self-host/remote-install.sh`):
  - `api.github.com/repos/.../tags` to pick the latest tag
  - `git clone github.com/DeepSQLAI/deepsql`
  - `raw.githubusercontent.com/.../bootstrap-server.sh` and `get.docker.com`, when Docker is missing
  - It then runs `install.sh`, which ran `npm i -g` (now off on `crate/main`).
- **`bootstrap-server.sh`:** `get.docker.com | sh`, GitHub Compose and buildx releases (`:99,121,153,170`).
- **Image builds:**
  - Docker Hub base images, Maven Central, npm
  - nodesource `setup_20.x | bash` and astral.sh `uv` install script (`agent/Dockerfile:28,34`)
  - GitHub clones of hermes-agent and hermes-webui, PyPI, and, with our change, npm tarballs for the vendored webui assets

We do not use the remote installer; see §6.

## 4. Footprint

**What was measured** (2026-10-23, on the owner's Mac): the patched backend ran
natively with JDK 26, `-Xmx1g -XX:+UseZGC`, the `prod` profile, a throwaway
Postgres 16 and one connection to a fake commerce DB.
- **RSS was 1.19 GB at 4 minutes after start and 0.95 GB after 16 minutes idle. CPU at idle was 0.3%.**
- This is the dominant container. It ran with C1-only JIT (`spring-boot:run` default) and JFR on, so treat it as approximate.

**What could not be measured:** the full five- or six-container `docker stats`.
The Mac's data volume was at 100% (about 1 GB free, shared with other sessions).
The podman VM's virtual disk hit write errors (`I/O error, dev vda`) and every
image build failed. I stopped the VM and freed what this task had written rather
than fight for space. Estimates for the rest, all [I]:

| Container | Idle RAM (estimate) |
|---|---|
| postgres + pgvector (vault) | 50-150 MB |
| valkey | ~10 MB |
| frontend nginx | ~10 MB |
| deepsql-agent (Python webui + provisioner + Node MCP) | 250-500 MB |
| ollama, idle / with `nomic-embed-text` loaded | ~50 MB / +300-600 MB, unloaded after `OLLAMA_KEEP_ALIVE` |
| **Total with backend at -Xmx1g** | **~1.5-2.3 GB** (upstream default `-Xmx3g`: up to ~4 GB) |

On-disk, also [I]: images about 4-6 GB (JDK runtime, Python + Node + build tools,
Ollama), plus about 300 MB for the embedding model.

To measure once disk is free:

```bash
export DOCKER_HOST=unix://$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}')
docker compose -p deepsql-crate -f docker-compose.yml -f docker-compose.crate.yml up -d --build
docker compose -p deepsql-crate -f docker-compose.yml -f docker-compose.crate.yml exec ollama ollama pull nomic-embed-text
# wait ~10 min idle, then:
docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}'
```

**The 4 GB box verdict holds either way.** Even at `-Xmx1g` the stack would
compete with the Rails app, Postgres, Redis and Sidekiq for RAM. Upstream's own
comment on the backend Dockerfile reports OOM-restart loops at 1 GB heap on a
~600-table schema during brain init. We have about 480 tables.

## 5. What it needs on Postgres

What the code actually queries:

| Need | Why | If missing |
|---|---|---|
| `pg_stat_statements` (in `shared_preload_libraries` + `CREATE EXTENSION` in `crate_production`) | Slow queries, workload, optimizer (`provider/postgres/PostgresSlowQueryProvider.java:131`, `service/StatsCollectorService.java:232`, `service/brain/workload/WorkloadMetricsCollectorService.java:224`; probed at `provider/postgres/PostgresPrivilegeCheckProvider.java:31`) | Those features come back empty with an "install it" hint |
| `pg_read_all_stats` | To see other roles' `pg_stat_statements` / `pg_stat_activity` text [I] | You only see the DeepSQL role's own queries |
| `track_io_timing = on` | Not read by DeepSQL code. Worth having so `pg_stat_statements` and `EXPLAIN (BUFFERS)` carry I/O time | Nothing breaks |
| `hypopg` | Optional, for index dry-runs | Falls back to a heuristic score. Don't install it on prod for this |
| `auto_explain` | Only parsed from CloudWatch/Azure log ingestion | Not needed |

Setup for `crate-postgres`:
- **Enable `pg_stat_statements`.** This needs a container restart for `shared_preload_libraries`, a few seconds of downtime:
  `-c shared_preload_libraries=pg_stat_statements -c pg_stat_statements.track=top -c track_io_timing=on`, then
  `CREATE EXTENSION pg_stat_statements;` in `crate_production`. This is useful whether or not we adopt DeepSQL.
- **Create the role:**

```sql
CREATE ROLE deepsql_ro LOGIN PASSWORD '<generated>' CONNECTION LIMIT 3;
ALTER ROLE deepsql_ro SET default_transaction_read_only = on;
ALTER ROLE deepsql_ro SET statement_timeout = '15s';
ALTER ROLE deepsql_ro SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE deepsql_ro SET lock_timeout = '1s';
GRANT CONNECT ON DATABASE crate_production TO deepsql_ro;
GRANT USAGE ON SCHEMA public TO deepsql_ro;
-- Prefer an explicit list over ALL TABLES; leave PII tables/columns out
-- (column-level: GRANT SELECT (id, shop_id, status, total_cents, created_at) ON orders TO deepsql_ro;)
GRANT SELECT ON <chosen tables> TO deepsql_ro;
GRANT pg_read_all_stats TO deepsql_ro;
```

`statement_timeout` matters because some EXPLAIN ANALYZE paths execute the query.

## 6. Feature reality check

**Real and backed by working code:**
- Agent chat (Hermes)
- Digest
- Brain / company knowledge
- Agent-generated HTML dashboards: a sandboxed iframe, read-only query bridge, sharing, versions, alerts
- Slow queries / workload / customer explorer from `pg_stat_statements`
- SQL Editor with guards
- Deterministic EXPLAIN analysis
- Index advisor
- Pre-flight migration risk: deterministic, verified against a real `postgres:18`
- Users, roles, audit logs
- LLM usage and cost ledger

We exercised slow-query analysis end to end (§8). It returned real
`pg_stat_statements` rows from the fake DB.

**Shells and stubs:**
- MongoDB, Redis and Oracle are greyed out in the connection picker.
- Azure, GCP and Datadog slow-log sources say "coming soon" in onboarding, although backend services exist for some.
- MySQL migration risk always returns UNKNOWN.

**Dead code:** a dozen legacy tabs have no importer:
- `AnalyticsTab` (hardcoded demo cards), `SentinelAnalyticsTab`, `GrowthMonitoringTab`, `PlaybooksTab`
- `ConfigurationTunerTab`, `DatabaseAdvisorTab`, `IndexRecommendationsTab`, `LockContentionTab`
- `ActiveQueryTab`, `PerformanceInsightsTab`, `MonitorSection`, `Workspace.js`

Their controllers still exist, including `SentinelDemoDataController`.

**Paid / enterprise gating:** none found. No licence keys or plan checks; access
is permission/role based only. `agent/distribution.yaml` says
`license: "proprietary"` for the persona and skills bundle, but the repo is
Apache-2.0.

**Code quality and tests:**
- **Size:** about 911 main and 217 test Java files; 3 frontend tests; about 17 MCP test files (294 tests, all passing locally).
- **CI:**
  - The frontend is built but not linted or tested.
  - The backend is compiled, and `mvn test` runs against a Postgres service.
  - MCP is only `node --check`ed.
- **Giant files:** `ChatService.java` 5.2k lines, `UniversalChatTool.java` 4.5k, `client.js` 4.1k, `QueryOptimizationService.java` 3.9k.
- **Schema management:** `ddl-auto=update` with a hand-kept, never-executed `db/migration/` folder.
- **Logging:** prod has `show-sql=true`.
- **Security history:** `CLAUDE.md` is a long log of authorization holes found and fixed in 2026-09/10. At one point 116 endpoints had no connection check, plus an unauthenticated public-share SQL path and an admin-only setup wizard that wasn't. The team fixes and adds safety tests, but this is fast-moving, AI-assisted code with a large attack surface.

## 7. LLM options

**It is BYO-model:**
- There is one provider id, `openai`, covering OpenAI, Azure and any OpenAI-compatible server (`llm/openai/OpenAiCompatibleChatProvider.java:24-40`).
- Configuration comes from env `DEEPSQL_CHAT_*` / `DEEPSQL_EMBEDDING_*`, or from DB settings, which win.

**Anthropic directly (`https://api.anthropic.com/v1/`):**
- **Backend:**
  - **URLs:** a base containing `/v1` gets `/chat/completions` appended, so there is no `/v1/v1` (`llm/openai/ResponsesApiChatModel.java:166-194`). Auth is `Authorization: Bearer` (`OpenAiEndpoints.java:37-47`).
  - **Responses API:** `DEEPSQL_CHAT_USE_RESPONSES_API=auto` would already pick chat completions for a `claude-*` model name (`OpenAiCompatibleChatProvider.java:75-86`). We pin it to `false` in the overlay anyway, because Anthropic has no Responses API.
  - **What it sends:** only `model`, `messages`, `temperature` (default 1.0), `stream` and `stream_options.include_usage`. It sends **no tools**; the backend's agentic loop is prompt-driven.
  - **Cheap model:** there is no separate cheap-model setting in the backend.
- **Agent container:**
  - **Bug:** `api_mode` on `model` was ignored for the `custom` provider. A host of `api.anthropic.com` would auto-switch to native Messages and try to pip-install the `anthropic` SDK. **Fixed on the branch** by pinning `providers.custom.api_mode: chat_completions`.
  - **What it sends:** tools and streaming tool-call deltas, standard OpenAI format.
  - **Cheap model:** auxiliary tasks (compression, titles, session search, approvals, background review, curator) now use `DEEPSQL_AGENT_AUX_MODEL`, default `claude-haiku-5-5` in the overlay.
  - **Context length:** comes from `DEEPSQL_AGENT_CONTEXT_LENGTH` (overlay: 200000; upstream hard-coded 272000).
- **Unverified, needs one smoke test with a real key:**
  - Whether Anthropic's compat layer accepts the backend's `temperature` with `claude-sonnet-5-5`, and Hermes' aux-call `temperature` (Hermes retries without it on a matching error).
  - `stream_options`.
  - Prompt caching does not apply over the compat layer.

**Embeddings:** Anthropic has none.
- **What they are used for:** RAG over schema, docs, query examples and column-value docs. Fail-open falls back to tsvector keyword search (`service/PgVectorSearchService.java:273-295`).
- **Keyword-only is not cleanly supported.** An unset provider throws `LlmNotConfiguredException` on every embed (`service/EmbeddingService.java:435-440`). A deliberately broken endpoint retries before failing open.
- **So the overlay runs Ollama + `nomic-embed-text`** (768 dims, `VECTOR_STORE_EMBEDDING_DIMENSIONS=768`). It stays local. The model is ~274 MB on disk and a few hundred MB of RAM while loaded.
- **Trap:** do **not** use the setup wizard's LLM step. `POST /setup/llm-config` copies the chat endpoint and key into the embedding settings, and the DB tier beats env. Embeddings would then silently go to `api.anthropic.com/v1/embeddings` and fail open (`controller/SetupController.java:~187-198`). Configure via env only.

**Via LiteLLM:** also works; any OpenAI-compatible gateway does. It is not needed now that Anthropic's own endpoint works.

**Privacy implications:**
- Everything in §2.1 goes to Anthropic: rows, sampled values, query text, plans.
- Anthropic's commercial API terms say inputs aren't used for training by default. Check the current retention window before pointing it at customer data.
- The `/api/llm/v1` relay lets **any** authenticated user or MCP token spend the key with arbitrary bodies; there is no role check. Keep the user list to the owner.

## 8. Verification run (2026-10-23)

| Check | Result |
|---|---|
| Backend telemetry tests (`TelemetryConfigTest`, `Telemetry*Test`, `Install*Test`, …) | 52 run, 51 pass. The 1 error is `InstallTelemetryIdentityRepositoryTest`, a full-context test that needs a live test DB, so it is environmental |
| Frontend `npm run build` | Passes; bundle has no Google Fonts, PostHog or npm-registry strings |
| MCP `npm test` | 294/294 |
| `crate-no-egress.sh` against a fresh `hermes-webui@v0.52.76` clone | 12 CDN URLs rewritten, CSP and functions patched, Python/JS still parse, idempotent |
| **Backend egress capture.** Patched backend, `prod` profile, about 16 min. Covered: start-up, admin bootstrap, login, creating a connection to a throwaway Postgres (fake data) as a `default_transaction_read_only` role, a slow-query analysis that called the LLM, a chat turn, then idle. Captured with JFR `jdk.SocketRead/Write` at 0 ms threshold, which catches every Java socket including Netty NIO, plus `lsof` polled every 1 s | **Only two peers:** `127.0.0.1` (vault DB, target DB, our curl) and **`api.anthropic.com` (160.79.104.10:443), 15 socket events**. The LLM calls used a placeholder key, so they returned 401. No PostHog, GitHub, npm or any other host |
| Target-DB statement log (`log_statement=all`) for the DeepSQL role | Only `SET application_name`, `SHOW …` and `SELECT`. No writes attempted |

**Limits of this run:**
- No Valkey binary was available outside containers, so chat and brain init stopped at "Unable to connect to Redis". The chat → SQL → rows → LLM path was therefore not exercised.
- The agent container, frontend and Ollama were not run, because of the disk-full host (§4).
- No real Anthropic key was in the Keychain yet.

The full-stack run (`docker stats`, plus a capture from inside the podman VM:
`podman machine ssh sudo tcpdump -i any -nn 'tcp[tcpflags] & tcp-syn != 0 and not dst net 10.0.0.0/8 and not dst net 172.16.0.0/12 and not dst net 192.168.0.0/16 and not dst net 127.0.0.0/8'`)
is the remaining step.

## 9. Security review of the install path

- **`curl | bash`:** it fetches a script from `deepsql.ai` (a copy of `remote-install.sh` on `main`), clones the latest tag, and may run `get.docker.com | sh` as root via `bootstrap-server.sh`. It is a standard supply-chain risk and unnecessary for us. **Don't use it.** Clone our fork and run Compose with our overlay.
- **Default passwords:**
  - Compose refuses to start without `DB_PASSWORD` / `DEEPSQL_VALKEY_PASSWORD` (`:?`).
  - `.env.example` only has `change-me-*` placeholders, and `install.sh` generates real secrets.
  - Seed scripts fall back to `postgres` (`scripts/self-host/seed-demo-data.sh:33`, `scripts/seed-acme-erp.sh:26`).
  - The vault DB user is the `postgres` superuser.
  - The JWT secret must be ≥32 bytes or startup fails (`security/JwtUtil.java:56-63`).
- **Exposed ports:**
  - **The frontend publishes on all interfaces** (`"${DEEPSQL_FRONTEND_PORT:-3000}:80"`).
  - Postgres, Valkey, backend, agent and provisioner bind `127.0.0.1` only.
  - On the Mac, set `DEEPSQL_FRONTEND_PORT=127.0.0.1:13000` (our `.env` does) so the UI is not on the LAN.
- **Web UI auth:**
  - Login is required in `prod` (`security.auth.enabled=true`), and sign-up is off.
  - The first admin comes from a localhost-only bootstrap endpoint gated by `SECURITY_ADMIN_BOOTSTRAP_ENABLED` + a secret header (`controller/UserController.java:52-80`). Turn the flag back off after bootstrap.
  - Cookies are `Secure`, so non-localhost use needs TLS in front.
- **MCP:** stdio only, with no network listener. It uses a bearer token (`DEEPSQL_AUTH_TOKEN` / token file), checked by `security/McpTokenAuthenticationFilter.java:46-70`, including an identity-mismatch refusal.
- **Agent API (:8787):**
  - It has no password and trusts `X-Remote-User` from any RFC1918 peer (`docker-compose.yml:155-160`). Any container on the Compose network can act as any user.
  - **Provisioner (:8788):** shared secret, compared with a non-constant-time `!=` (`scripts/local-agent-provisioner.py:236,268`).
  - Acceptable only on a single-user, loopback-only machine.
- **Other:** `/api/llm/v1` has no role check (§7), and the unguarded EXPLAIN ANALYZE / rewrite-execution paths (§2.3) are mitigated only by the read-only role.

## 10. Fit for Crate

**Where to run it:**

| Option | Verdict |
|---|---|
| **Owner's Mac, on demand, via an SSM port-forward to the box's loopback Postgres, as `deepsql_ro`** | **Recommended.** Free, nothing new on the 4 GB box, credentials and vault stay on the Mac, and nothing runs when unused. `aws ssm start-session --target <instance> --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters host=127.0.0.1,portNumber=5432,localPortNumber=15433`. Then add a connection with host `host.containers.internal` (or `host.docker.internal`), port 15433. This needs `crate-postgres` reachable on the instance's loopback. If it isn't published there, publish `127.0.0.1:5432` only, never `0.0.0.0`. SSH `-L` works the same way, and DeepSQL's built-in SSH tunnel is an alternative. |
| Cloudflare Container | **No.** Five long-running stateful services (JVM, Postgres + pgvector, Valkey, a Python agent, Ollama) with persistent volumes, plus a private tunnel back to AWS. It is not a fit for an ephemeral container product, and the always-on JVM would not stay free. |
| A box (the existing 4 GB one, or a new one) | **No on the existing box:** RAM contention with production (§4). **A new box costs money**, breaking the "free" rule. A free-tier micro instance is too small for the JVM. |

**Enable on our Postgres first, regardless:** `pg_stat_statements` +
`track_io_timing`, and the `deepsql_ro` role in §5. `pg_stat_statements` alone
answers "what is slow" for free.

**Honest value at our scale:**
- **The database is small:** about 480 tables, but a **6 MB dump**. Nearly every table fits in shared buffers. Index advice and EXPLAIN tuning will rarely find big wins, and Rails latency problems are more likely N+1s and app-side.
- **What DeepSQL adds over `pg_stat_statements`:** natural-language querying, LLM-written explanations, and the deterministic migration-risk analyzer. The analyzer is the most useful piece for a Rails shop: paste a migration's SQL before deploying.
- **Lighter, free, Rails-native alternatives:**
  - **PgHero** (a mountable gem: slow queries, missing and unused indexes, from `pg_stat_statements`)
  - **`strong_migrations`** (migration safety at write time)
  - **Dexter** (index suggestions with HypoPG)
  - All three run inside the existing app with no LLM and no new infrastructure.
- **Expected value:** low to moderate. Worth an occasional review session. Not worth a standing service or a new box.

**Risks:**
1. **Customer data to the LLM:** result rows, sampled values, literals in queries. Mitigate with role grants that exclude PII, our overlay's sampling-off defaults, and owner-only use. Residual risk remains: chat answers still carry rows.
2. **Writes to production:** mitigated only by `default_transaction_read_only` + `SELECT`-only grants + `statement_timeout` on the role. Never connect as `postgres` or the app user.
3. **Load on prod:** EXPLAIN ANALYZE runs real queries, and brain init scans and profiles tables. Use `CONNECTION LIMIT 3` and the timeouts. Run off-peak.
4. **Fast-moving upstream:** a history of authorization holes, a large surface, and two third-party agent repos pulled at build time. Pin to our branch; rebase deliberately; re-run `crate-no-egress.sh` (it fails the build if an upstream bump moves a patch target).
5. **Vault secrets live beside the data** in `.env` on the Mac. Keep the disk encrypted (FileVault) and `.env` mode 600.
6. **Not yet verified end to end:** the full stack with a real Anthropic key. That needs the Keychain key and free disk space.

## 11. What we'd need to set up

1. **Free disk on the Mac.** The data volume was at 100% during this evaluation, and the full stack needs ~5-7 GB.
2. **Store the Anthropic key** in the Keychain (`security add-generic-password -s anthropic-api-key -a deepsql -w`). Then write it into the gitignored `.env`:
   ```bash
   KEY=$(security find-generic-password -s anthropic-api-key -a deepsql -w)
   sed -i '' "s|^DEEPSQL_CHAT_API_KEY=.*|DEEPSQL_CHAT_API_KEY=${KEY}|" .env
   ```
3. **Start and finish setup:**
   - Run `docker compose -p deepsql-crate -f docker-compose.yml -f docker-compose.crate.yml up -d --build`.
   - Pull `nomic-embed-text` into the `ollama` service.
   - Bootstrap the admin, set `SECURITY_ADMIN_BOOTSTRAP_ENABLED=false`, and restart the backend.
4. **Smoke-test:** one chat turn and one Agent-tab turn. Confirm Anthropic accepts the requests (temperature / `stream_options`), then run `docker stats` and the tcpdump capture from §8.
5. **On `crate-postgres`:**
   - Enable `pg_stat_statements` + `track_io_timing` (restart).
   - Create `deepsql_ro` with an explicit table and column grant list.
   - Make sure Postgres is reachable on the instance's loopback for SSM port forwarding.
6. **Use, then stop:**
   - `aws ssm start-session …` port-forward, add the connection in DeepSQL, run the review.
   - Afterwards: `docker compose -p deepsql-crate … down`. Add `-v` to also drop the vault, which holds cached schema, profiles and chat history.
