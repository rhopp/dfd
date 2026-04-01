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

1. **Phase 1 — Data Collection**: Fetches failed pipelineruns from KubeArchive, downloads taskruns, pod logs, and (optionally) cluster artifacts via `oras pull`.
2. **Phase 2 — Per-Failure Analysis**: Spawns parallel Claude sub-agents, each analyzing one failure using Ginkgo output, pod logs, and cluster artifacts. Each agent classifies the root cause using a taxonomy defined in `dfd-rules.md`.
3. **Phase 3 — Consolidation**: A final Claude agent reads all individual analyses and produces a consolidated report with failure breakdowns, root cause categories, and prioritized action items.

Results are cached in `runs/<date>/` — rerunning the same day skips already-collected data and completed analyses.

## Output

Reports are written to `runs/<date>/`:
- `consolidated-report.md` — the full summary
- `<pipelinerun>/analysis.md` — individual failure analysis
- `<pipelinerun>/kubearchive/` — raw taskruns and logs
- `<pipelinerun>/artifacts/` — cluster artifacts (if downloaded)
