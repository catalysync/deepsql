# Telemetry and phone-home removed (branch `crate/main`)

Every change is small and self-contained so the branch rebases onto upstream
`main` cleanly. Each patched spot carries a `Crate fork:` comment; `git grep -n
"Crate fork"` lists them all. Line numbers are as of the commits listed at the end.

What is deliberately **kept**: the user-configured LLM endpoint
(`DEEPSQL_CHAT_*`, `DEEPSQL_EMBEDDING_*`), target-database connections (JDBC,
optional SSH tunnel), and integrations that only run when an operator configures
them (Slack, SMTP, Google SSO, webhooks, Datadog / S3 / CloudWatch /
Elasticsearch slow-log ingestion, Azure AI Search). None of those are enabled in
our setup.

## Backend (Spring)

| What upstream did | Change | Where |
|---|---|---|
| `PostHogDirectSink` POSTed install/usage events and `$groupidentify` traits (install id, version, company name inferred from the admin email domain, counters) to `https://us.i.posthog.com/batch/` when `deepsql.telemetry.posthog-project-key` was set. No key ships upstream, so it was dormant, but one env var (`DEEPSQL_TELEMETRY_POSTHOG_PROJECT_KEY`) turned it on. | **Deleted** the class and its tests (`PostHogDirectSinkTest`, `TelemetryFlowIntegrationTest`, `Phase25TelemetryIntegrationTest`, `TelemetryPropertiesEnvBindingTest`, which existed to prove events reach PostHog). | `backend/src/main/java/com/dbaagent/service/telemetry/PostHogDirectSink.java` (removed) |
| `TelemetryConfig` picked PostHog or NoOp from env/properties. | Always returns `NoOpTelemetrySink`; takes no inputs. | `backend/src/main/java/com/dbaagent/config/TelemetryConfig.java:19-23` |
| `deepsql.telemetry.enabled` defaulted to `true`; PostHog host defaulted to `us.i.posthog.com`. | Default `false`; host `""`. `TelemetryClient.capture()` therefore returns before buffering anything. | `backend/src/main/java/com/dbaagent/service/telemetry/TelemetryProperties.java:18-21` |
| `InstallTelemetryBootstrap` (`@PostConstruct`) created the `install_telemetry_identity` row (install UUID, secret, `dt_live_` token, company name) and emitted `install.bootstrapped`. | No longer a `@Component`: never instantiated, no row written. | `backend/src/main/java/com/dbaagent/service/telemetry/InstallTelemetryBootstrap.java:18-19` |
| `InstallHeartbeatJob` ran every 30 min (probing postgres/valkey/frontend) and emitted `install.heartbeat`. | No longer a `@Component`: never scheduled. | `backend/src/main/java/com/dbaagent/service/telemetry/InstallHeartbeatJob.java:34-35` |
| V99 migration / `InstallTelemetryIdentity` entity. | Left in place on purpose. There is no Flyway runtime here (schema is `ddl-auto=update`), so V99 never ran anyway; Hibernate still creates the empty table from the entity. Removing the entity would only create rebase conflicts in tests and repositories. Nothing writes to it. | `backend/src/main/resources/db/migration/V99__create_install_telemetry.sql`, `backend/src/main/java/com/dbaagent/model/InstallTelemetryIdentity.java` |
| — | New test: the sink is always NoOp. `TelemetryPropertiesTest` now asserts disabled-by-default. | `backend/src/test/java/com/dbaagent/config/TelemetryConfigTest.java`, `backend/src/test/java/com/dbaagent/service/telemetry/TelemetryPropertiesTest.java:10-14` |

Still present but local-only (not removed): in-process counters
(`TelemetryCounters`, `HeartbeatRollupTracker`) and the 10 s `TelemetryFlushJob`,
which drains an always-empty buffer into the NoOp sink. OpenTelemetry tracing
export points at `http://localhost:4318` and is disabled in the `prod` profile
(`application-prod.properties:142,147-148`), which Compose uses.

## Web UI (React/Vite)

| What upstream did | Change | Where |
|---|---|---|
| `@monaco-editor/react` loads Monaco at runtime from `https://cdn.jsdelivr.net/npm/monaco-editor@0.55.1/min/vs` (the loader's default; no `loader.config` anywhere). Every SQL Editor / Explain / Dashboard source view fetched from jsDelivr. | New module bundles `monaco-editor@0.55.1` (exact pin) with local workers and calls `loader.config({ monaco })`; the five editor call sites import it instead. | `src/lib/monacoEditor.js:1-23`; `src/components/tabs/Core/SqlRunnerTab.js:156`, `src/components/tabs/Performance/ExplainPlanTab.js:10`, `src/components/DashboardBuilder.js:11`, `src/components/SavedDashboardsPanel.js:12`, `src/components/sections/DashboardWorkspace.jsx:11`; `vite.config.js:38` |
| Maven Pro font from `fonts.googleapis.com` / `fonts.gstatic.com`. | `@fontsource/maven-pro@5.3.0` (latin, 400-900) bundled. | `src/index.css:1`, `src/main.jsx:8-14`, `package.json` |
| `/download` page fetched `https://api.github.com/repos/DeepSQLAI/deepsql/releases` from the browser. | Lookup off; page shows the existing "no build" notice with a link. | `src/pages/Download.jsx:31,111-117` |

Verified: `npm run build` passes; the bundle contains no `fonts.googleapis.com`,
`gstatic`, `posthog` or `registry.npmjs` strings. The only jsDelivr string left is
the loader's unused default config inside the editor chunk, which
`loader.config({ monaco })` bypasses.

## Desktop (Electron)

| What upstream did | Change | Where |
|---|---|---|
| `electron-updater` checked a feed when `DEEPSQL_UPDATE_FEED` or a bundled `app-update.yml` existed. | `UPDATES_DISABLED = true`; `init()` returns before anything else. | `desktop/src/main/updater.js:18,21-26` |
| Google Fonts `@import`; CSP allowed `fonts.googleapis.com` / `fonts.gstatic.com`. | Import removed (system font stack fallback was already spelled out); CSP is `style-src 'self' 'unsafe-inline'; font-src 'self'`. | `desktop/src/renderer/shared/theme.css:10-11`, `desktop/src/renderer/launcher/index.html:7`, `desktop/src/renderer/chrome/index.html:7` |

The "View on GitHub" menu item (`desktop/src/main/menu.js`) only opens a browser
when clicked; left as is.

## CLI / MCP (`mcp/`) and installer

| What upstream did | Change | Where |
|---|---|---|
| The interactive agent intro called `https://registry.npmjs.org/@deepsql/mcp/latest` on start to show "update available". | `fetchLatest()` resolves `null`; the registry function is kept, unused, to minimise the diff. | `mcp/src/commands/_agent_intro.js:185-190` |
| `install.sh` ran `npm i -g @deepsql/mcp` and `npm view @deepsql/mcp version`. | `setup_deepsql_cli` returns immediately. | `scripts/self-host/install.sh:518-523` |

Not changed, and **not to be used**: `scripts/self-host/remote-install.sh` (the
`curl https://deepsql.ai/install.sh | bash` path; it calls deepsql.ai,
api.github.com, raw.githubusercontent.com and get.docker.com) and
`bootstrap-server.sh` (get.docker.com, GitHub releases). We run Compose from this
checkout instead.

## Agent container (Hermes runtime + webui, built in `agent/Dockerfile`)

Upstream DeepSQL clones two third-party projects at image build time
(`NousResearch/hermes-agent@v2026.8.18`, `nesquena/hermes-webui@v0.52.76`).
Their runtime egress, and what we did:

| Egress | Change | Where |
|---|---|---|
| Webui update check: `git fetch origin --tags` against github.com (or `api.github.com/.../tags`) on UI load, every 30 min, plus a manual "force" button. | `check_for_updates()` patched to return `{"disabled": true}`; `.git` removed from both clones so nothing can fetch. | `agent/webui/crate-no-egress.sh` steps 3-4, run from `agent/Dockerfile:116-119` |
| Webui extension registry at `hermes-webui.github.io`. | `get_extension_registry()` returns an empty list. | same script, step 3 |
| Webui loads prism (plus per-language grammars via the autoloader), xterm, pdf.js and mermaid from `cdn.jsdelivr.net`. | Vendored at build time from the npm tarballs of the same versions into `static/vendor/crate/`; all URLs rewritten. The script fails the build if any `https://cdn.jsdelivr.net` URL remains. | same script, step 1 |
| Webui CSP allowed jsDelivr, Cloudflare Insights, Google Fonts and `img-src https:` (any image URL in model output would be fetched: a prompt-injection exfiltration path). | Those sources removed; `img-src 'self' data: blob:`. | same script, step 2 |
| Lazy `pip install` from PyPI at run time (e.g. the `anthropic` SDK). | `HERMES_DISABLE_LAZY_INSTALLS=1` and `security.allow_lazy_installs: false`. | `agent/docker-entrypoint.sh:76-77,137` |
| Model catalog (`hermes-agent.nousresearch.com`), models.dev lookups, opt-in shared metrics. | `model_catalog.enabled: false`, `models_dev.url` pointed at a dead loopback address, `telemetry.shared_metrics.enabled: false` (already the default). | `agent/docker-entrypoint.sh:136-140` |
| Tools that can reach the internet (`bfl` image generation, `stt`). | Added to the `tools disable` list (upstream already disabled web, browser, image_gen, tts, vision, ...). | `agent/docker-entrypoint.sh:188` |
| A host of `api.anthropic.com` made the runtime switch `providers.custom` to native Anthropic Messages and lazily pip-install the `anthropic` SDK. | `providers.custom.api_mode: chat_completions` pinned (this is also a correctness fix for using Claude). | `agent/docker-entrypoint.sh:130-134` |

The build itself still reaches nodesource, astral.sh, github.com, PyPI and npm;
the running container does not need them.

## Verification

- Backend: `mvn test -Dtest='TelemetryConfigTest,Telemetry*Test,Install*Test,HeartbeatRollupTrackerTest,CredentialServiceTelemetryTest,SlowQueryIngestionTelemetryTest,BrainRetrievalCountingVectorStoreTest,EventSchemaRegistryTest,QueryExecutorServiceCounterTest,SelfHostPropertiesSafetyTest'`:
  52 run, 51 pass. The one error is `InstallTelemetryIdentityRepositoryTest`, a full-context
  `@SpringBootTest` that needs a live test database (`TEST_DB_PASSWORD` etc., see
  CLAUDE.md "Testing"); it errors the same way without our change.
- Frontend: `npm run build` passes. MCP: `npm test` 294/294.
- `agent/webui/crate-no-egress.sh` was run against a fresh `hermes-webui@v0.52.76`
  clone: 12 CDN URLs rewritten, CSP patched, both functions disabled, Python and JS
  still parse (`ast.parse`, `node --check`), and a second run is a no-op.
- Runtime egress: see EVALUATION.md, "Verification run".
