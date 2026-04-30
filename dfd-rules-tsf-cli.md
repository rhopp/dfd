# TSF CLI — Classification Taxonomy

## Root Cause Categories

| root_cause | category | Error Signatures |
|------------|----------|-----------------|
| **Infrastructure / Provisioning** | | |
| `rosa_provisioning_failure` | infrastructure | `provision-rosa` task failed; ROSA cluster creation timeout or error |
| `install_failure` | infrastructure | `install-tsf` task failed; Helm or TSF installation error |
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
| `integration_test_ec_policy_violation` | infrastructure | Integration test pipelinerun name matches `enterprise-contract` pipeline AND TaskRun verify step-assert fails with TEST_OUTPUT containing `"result":"FAILURE"` AND violations array is non-empty |
| `e2e_test_compilation_failure` | infrastructure | E2e test fails during test binary compilation due to Go module dependency version conflicts or interface incompatibilities |
| `e2e_test_cleanup_namespace_deletion_timeout` | infrastructure | E2e test cleanup fails because namespace deletion times out waiting for stuck PipelineRun(s) to be removed |
| `release_tuf_dns_failure` | infrastructure | Release pipeline fails in process-component-sbom task due to DNS resolution failure when accessing TUF (The Update Framework) server for cosign initialization |
| `e2e_test_compilation_oom` | infrastructure | E2e test fails during test binary compilation due to out-of-memory condition killing the Go compiler process |
| `release_autorelease_concurrent_snapshot_race` | test_flake | E2e test fails when waiting for Release CR creation because a concurrent build's snapshot completed integration tests first and triggered auto-release, causing the tracked snapshot to be marked as 'Released in newer Snapshot' without its own Release CR |
| `release_tuf_tls_cert_failure` | infrastructure | Release pipeline fails in process-component-sbom task due to TLS certificate verification failure when cosign initializes with TUF server |
| `image_pull_failure` | infrastructure | Image pull failures during pod initialization |
| `unknown` | unknown | Cannot determine root cause from available data |

## Classification Priority Rules

Apply these in order — first match wins:

1. If `provision-rosa` task failed -> `rosa_provisioning_failure`
2. If `install-tsf` task failed -> `install_failure`
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
12. If test is `should eventually complete successfully` (integration test) AND pipelinerun is `enterprise-contract` AND step-assert fails with EC violations -> `integration_test_ec_policy_violation`
13. If e2e/integration test fails AND step log contains 'go test -c' OR 'make build' AND compilation errors mention interface type mismatches or 'does not implement' OR 'cannot use .* as .* value in return statement' -> e2e_test_compilation_failure
14. If error in AfterAll cleanup AND message contains 'namespace was not deleted in expected timeframe' AND 'context deadline exceeded' AND 'Remaining resources in namespace' with stuck pipelineruns -> `e2e_test_cleanup_namespace_deletion_timeout`
15. If Release pipeline failure in 'process-component-sbom' task AND step log contains 'cosign initialize' AND error message contains 'dial tcp: lookup tuf-' AND 'no such host' -> `release_tuf_dns_failure`
16. If e2e/integration test step fails AND metadata shows OOMKilled AND step log contains Go compilation command ('go test -c' OR 'make build') AND error shows '/usr/lib/golang/pkg/tool/.*/compile: signal: killed' -> e2e_test_compilation_oom
17. If test fails with 'timed out when waiting for Release CR to be created for snapshot' AND snapshot has AutoReleased condition 'Released in newer Snapshot' -> `release_autorelease_concurrent_snapshot_race`
18. If task='process-component-sbom' AND error contains 'tls: failed to verify certificate' AND log contains 'cosign initialize' -> `release_tuf_tls_cert_failure`
19. If task fails with 'failed to pull the image' OR pod shows ErrImagePull/ImagePullBackOff -> `image_pull_failure`
20. Otherwise -> `unknown`
