# TSSC Dev Multi CI — Classification Taxonomy

## Root Cause Categories

| root_cause | category | Error Signatures |
|------------|----------|-----------------|
| **Infrastructure / Provisioning** | | |
| `rosa_provisioning_failure` | infrastructure | `provision-rosa` task failed; ROSA cluster creation timeout or error |
| `install_failure` | infrastructure | `tssc-install` task failed; toolchain installation error |
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
| **Agent-Discovered Patterns** | | |
| `unknown` | unknown | Cannot determine root cause from available data |

## Classification Priority Rules

Apply these in order — first match wins:

1. If `provision-rosa` task failed -> `rosa_provisioning_failure`
2. If `tssc-install` task failed -> `install_failure`
3. If any output contains `rate limit` or `403 API rate limit` -> `github_rate_limit`
4. If test error mentions `Release PipelineRun ... to fail`:
   - Investigate the managed pipelinerun (see Step 3 in the base rules)
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
