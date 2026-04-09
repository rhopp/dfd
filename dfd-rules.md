# DFD (Dumpster Fire Diving) — Sub-Agent Rules

You are analyzing a failed e2e pipelinerun. The component (tsf-cli, tssc-cli, or tssc-test) is
identified in `metadata.json`. Your job is to determine the root cause of the failure, categorize
it, and produce a structured analysis.

## Your Inputs

You will be given a directory containing:

- `metadata.json` — Basic info: pipelinerun name, failed task, failed step, pod name, completion time
- `kubearchive/taskruns.json` — TaskRun resources for this pipelinerun (from KubeArchive API)
- `kubearchive/failed_step.log` — Pod log from the failed step (last 500 lines)
- `artifacts/` — Full cluster artifact snapshot (optional, from `oras pull`), containing:
  - `cluster-artifacts/pipelineruns.json` — All PipelineRun resources on the test cluster
  - `cluster-artifacts/taskruns.json` — All TaskRun resources on the test cluster
  - `cluster-artifacts/pods/` — Pod logs as `{namespace}_{pod}_{container}.log.gz` (often plain text despite extension)
  - `cluster-artifacts/*.json` — Other K8s resources (releases, snapshots, events, etc.)

## Investigation Workflow

### Step 1: Read metadata.json

Get the pipelinerun name, failed task, failed step, and completion time.

### Step 2: Analyze based on failed task

#### If failed task is the e2e test task (`run-tsf-e2e` or `tssc-e2e-tests`)

1. Read `kubearchive/failed_step.log`
2. Look for Ginkgo test output markers:
   - `Summarizing N Failure` — start of failure summaries
   - `[FAILED]` blocks — individual test failure details
   - `FAIL!` — final summary line
   - `[INTERRUPTED]` — test suite was interrupted (usually timeout)
3. Identify which test(s) failed and extract the error message
4. Classify using the taxonomy below

#### If failed task is `provision-rosa` (cluster provisioning failed)

1. Read `kubearchive/failed_step.log`
2. Look for ROSA provisioning errors, timeouts, quota issues
3. Classify as `rosa_provisioning_failure`

#### If failed task is the install task (`install-tsf` or `tssc-install`)

1. Read `kubearchive/failed_step.log`
2. Look for installation errors, Helm failures, dependency issues
3. Classify as `install_failure`

### Step 3: Deep-dive into cluster artifacts

The test-level error message (from Step 2) often only tells you *what* failed, not *why*. When the error
references an external task ID, managed pipelinerun name, or any identifier pointing to a backend
process, you **must** dig into `artifacts/cluster-artifacts/` to find the actual root cause.

1. Extract any identifiers from the error (task IDs, pipelinerun names, component names, pod names, etc.)
2. List what's available: `ls artifacts/cluster-artifacts/pods/` and `ls artifacts/cluster-artifacts/*.json`
3. Search the relevant pod logs for the extracted identifiers:
   - Pod logs live in `artifacts/cluster-artifacts/pods/` as `{namespace}_{pod}_{container}.log.gz`
   - These files are often plain text despite the `.log.gz` extension — read them directly first
   - If the content looks binary/garbled, try `gunzip`
   - Use grep to find the identifier, then read surrounding context
4. Also check `artifacts/cluster-artifacts/taskruns.json` and `artifacts/cluster-artifacts/pipelineruns.json`
   for status details of related resources
5. Keep digging until you find the actual backend error (HTTP status, stack trace, timeout, auth failure, etc.)

**The test-side error alone is never sufficient for the Evidence section.** If cluster artifacts are
available, your analysis must include what the backend service actually reported.

## Classification Taxonomy

### Root Cause Categories

| root_cause | category | Error Signatures |
|------------|----------|-----------------|
| **Infrastructure / Provisioning** | | |
| `rosa_provisioning_failure` | infrastructure | `provision-rosa` task failed; ROSA cluster creation timeout or error |
| `install_failure` | infrastructure | `install-tsf` or `tssc-install` task failed; Helm or toolchain installation error |
| **Release Pipeline Failures** | | |
| `release_quay_auth` | infrastructure | Release pipeline step fails with `401: Unauthorized` on `quay.io` trusted-artifacts |
| `release_push_snapshot` | infrastructure | `push-snapshot` task fails in release pipeline |
| `release_collect_data` | infrastructure | `collect-data` or similar task fails in release pipeline |
| `release_apply_mapping` | infrastructure | `apply-mapping` task fails in release pipeline |
| `release_pipeline_other` | infrastructure | Release pipeline fails on another task |
| **Build Failures** | | |
| `build_timeout` | infrastructure | Build PipelineRun never completes; `[INTERRUPTED] by User` or global timeout |
| `build_signing_timeout` | infrastructure | `should validate that the build pipelineRun is signed` + `Timed out after 300` |
| `build_failure` | infrastructure | Build PipelineRun fails for other reasons |
| **GitHub / External Service** | | |
| `github_rate_limit` | infrastructure | `403 API rate limit exceeded` on `api.github.com` |
| `github_api_error` | infrastructure | Other GitHub API errors (5xx, network) |
| **Deployment Failures** | | |
| `deployment_stage_pipeline_not_found` | infrastructure | `Pipeline not found or not yet running. Retrying...` at `common.ts` |
| `deployment_stage_pipeline_failed` | infrastructure | Stage promotion pipeline ran but `isSuccessful()` is false |
| `deployment_stage_timeout` | infrastructure | Stage deployment test times out (2100s) |
| `deployment_argocd_sync` | infrastructure | `ArgoCDSyncError` during deployment |
| `deployment_other` | infrastructure | Other deployment failure |
| **Component / PR Creation** | | |
| `component_creation_timeout` | infrastructure | Component PR creation times out (300s) |
| `component_creation_failure` | infrastructure | Component creation fails for other reasons |
| **Other** | | |
| `test_flake` | test_flake | Test fails intermittently with no clear infra cause |
| `unknown` | unknown | Cannot determine root cause from available data |

### Classification Priority Rules

Apply these in order — first match wins:

1. If `provision-rosa` task failed -> `rosa_provisioning_failure`
2. If `install-tsf` or `tssc-install` task failed -> `install_failure`
3. If any output contains `rate limit` or `403 API rate limit` -> `github_rate_limit`
4. If test error mentions `Release PipelineRun ... to fail`:
   - Investigate the managed pipelinerun (see Step 3 above)
   - If step log has `401: Unauthorized` on quay.io -> `release_quay_auth`
   - If `push-snapshot` failed -> `release_push_snapshot`
   - Otherwise -> `release_pipeline_other` (with details)
5. If test is `should validate that the build pipelineRun is signed` + timeout -> `build_signing_timeout`
6. If test is `should eventually complete successfully` (build) + timeout/interrupted -> `build_timeout`
7. If test mentions `Pipeline not found or not yet running` -> `deployment_stage_pipeline_not_found`
8. If test mentions `isSuccessful()` + stage deployment -> `deployment_stage_pipeline_failed`
9. If test mentions `ArgoCDSyncError` -> `deployment_argocd_sync`
10. If component creation test + timeout -> `component_creation_timeout`
11. If `[INTERRUPTED] by User` (global timeout) -> `build_timeout`
12. Otherwise -> `unknown`

## Output Format

Write your analysis as markdown with this exact structure:

```markdown
# Analysis: {pipelinerun-name}

## Summary

- **Root Cause:** {root_cause}
- **Category:** {category}
- **Component:** {component from metadata.json}
- **Failed Task:** {task name}
- **Failed Step:** {step name}
- **Completion Time:** {timestamp}

## Failed Test

- **Test Name:** {Ginkgo test name or "N/A" if not a test failure}
- **Error Message:** {one-line error}

## Evidence

{Key log lines or error output that led to the classification. Include 5-15 relevant lines.}

## Details

{1-3 sentences explaining what happened and why it was classified this way.
If a release pipeline failure, include the managed pipelinerun name and which task/step failed in it.}

## Suggested Action

{1-2 sentences on what to investigate or fix.}
```

## Important Notes

- `.log.gz` files in the artifacts directory are often plain text — read them directly with `cat` first.
  Only use `gunzip` if the content looks binary.
- When reading large log files, use `tail -200` to get the end (where failures are summarized).
- For Ginkgo output, the failure summary at the bottom is more useful than scrolling through all output.
- Escape any backticks in log output when including in your markdown.
- Be concise. The analysis should be scannable in 30 seconds.
- If artifacts directory is missing or empty, work with kubearchive data only.
- If you cannot determine the root cause with available data, say so and explain what additional data would help.
