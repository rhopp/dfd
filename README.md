<p align="center">
  <img src="assets/logo.png" alt="DFD mascot" width="300">
</p>

# DFD — Dumpster Fire Diving

Because our dumpsters are always on fire.

DFD dives into failed e2e pipelineruns, pulls logs and artifacts, spawns parallel [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sub-agents to analyze each failure, and consolidates everything into a single report.

## Prerequisites

- **claude** CLI ([Claude Code](https://docs.anthropic.com/en/docs/claude-code))
- **jq**
- **python3**
- **oras** (optional — for downloading cluster artifacts from Quay)
- An OCP bearer token for KubeArchive access

## Setup

```bash
cp .env.template .env
# Edit .env and fill in your TOKEN, KUBEARCHIVE_BASE, and ARTIFACT_BROWSER_BASE
```

## Usage

```bash
./dfd.sh [HOURS_BACK] [MAX_PARALLEL] [COMPONENTS...]
```

### Components

| Component | Description |
|-----------|-------------|
| `tsf-cli` | TSF (Trusted Software Factory) — default |
| `tssc-cli` | TSSC CLI |
| `tssc-test` | TSSC Test |

### Examples

```bash
./dfd.sh                              # tsf-cli, last 24h, 5 parallel agents
./dfd.sh 48 8                         # tsf-cli, last 48h, 8 parallel agents
./dfd.sh 24 5 tssc-cli tssc-test      # both TSSC repos
./dfd.sh 24 8 tsf-cli tssc-cli        # TSF + TSSC CLI
```

## How it works

1. **Phase 1 — Data Collection**: Fetches PipelineRuns from KubeArchive, filters by component prefix and time window, writes `filtered_runs_{component}.json` with all run statuses. Downloads taskruns, pod logs, and (optionally) cluster artifacts via `oras pull` for failures.
2. **Phase 2 — Per-Failure Analysis**: Spawns parallel Claude sub-agents, each analyzing one failure using Ginkgo output, pod logs, and cluster artifacts. Each agent classifies the root cause using a taxonomy defined in `dfd-rules.md`. If a failure can't be classified, the agent investigates deeper and may propose a new taxonomy rule.
3. **Phase 2.5 — Rule Proposal Merge**: Collects any `rule_proposal.json` files written by agents that discovered new failure patterns. Validates and deduplicates proposals (using Claude for semantic dedup when there are multiple), then inserts new entries into per-component rule files (`dfd-rules-{component}.md`). This makes the taxonomy self-evolving.
4. **Phase 2.6 — Re-analyze Unknowns**: After the taxonomy is updated, any analyses still classified as `unknown` are re-run with the updated rules so agents can now properly classify them.
5. **Phase 2.7 — Analysis Validation**: Validates every `analysis.json` (structured output enforced via `--json-schema`). Checks that root_cause is a valid taxonomy ID for the component. Invalid analyses are re-run with specific feedback (up to 1 retry). Any remaining invalid analyses are replaced with a fallback template (root_cause `unknown`, metadata from `metadata.json`), guaranteeing clean data for downstream consumers.
6. **Phase 3 — Consolidation**: A final Claude agent reads all individual analyses and produces a consolidated report with failure breakdowns, root cause categories, and prioritized action items. A cost summary table is printed at the end.

Results are cached in `runs/<date>/` — rerunning the same day skips already-collected data and completed analyses.

## Output

Reports are written to `runs/<date>/`:
- `filtered_runs_{component}.json` — all runs (succeeded, failed, aborted), pre-filtered by prefix and time
- `consolidated-report.md` — the full summary
- `<pipelinerun>/analysis.json` — structured analysis data (JSON)
- `<pipelinerun>/analysis.md` — rendered analysis for human reading and consolidation
- `<pipelinerun>/kubearchive/` — raw taskruns and logs
- `<pipelinerun>/artifacts/` — cluster artifacts (if downloaded)
- `cost/` — per-invocation Claude cost/token data (JSON files)
- `<pipelinerun>/rule_proposal.json` — new taxonomy rule proposed by agent (if any)
