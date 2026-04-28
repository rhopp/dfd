# TSSC CLI — Classification Taxonomy

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
| `component_creation_github_404` | infrastructure | Component creation fails when publishing repository to GitHub with 404 Not Found error |
| `gitlab_ci_empty_logs` | infrastructure | GitLab CI pipeline fails with unavailable or empty job logs |
| `image_pull_failure` | infrastructure | Container image pull failures (Back-off pulling image, failed to pull the image) |
| `developer_hub_api_socket_hangup` | infrastructure | Component creation test fails with 'Failed to retrieve Developer Hub task status: socket hang up' |
| `component_creation_developer_hub_auth` | infrastructure | Component creation fails when Developer Hub (Backstage) API returns 401 Unauthorized |
| `component_creation_github_500` | infrastructure | Component creation fails when Developer Hub (Backstage) tries to publish/push the scaffolded repository to GitHub and receives HTTP 500 Internal Server Error |
| `tuf_tls_certificate_failure` | infrastructure | TLS certificate verification failure when accessing TUF (The Update Framework) server for SBOM attestation |
| `gitlab_ci_pipeline_not_triggered` | infrastructure | GitLab CI pipeline was not triggered after merge request creation |
| `hive_provisioning_failure` | infrastructure | Hive cluster pool provisioning timeout or failure |
| `component_creation_developer_hub_404` | infrastructure | Component creation fails when Developer Hub (Backstage) API returns 404 Not Found during component scaffolding |
| `tekton_chains_signing_failure` | infrastructure | Stage promotion pipeline fails because Tekton Chains cannot sign the pipeline, causing downstream attestation-dependent tasks to fail |
| `github_actions_workflow_not_triggered` | infrastructure | GitHub Actions workflow was not triggered after PR/commit creation |
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
12. If component creation fails AND error contains '404 Not Found' AND step name contains 'Publish' AND 'GitHub' -> component_creation_github_404
13. If GitLab CI pipeline status is failure AND job logs are empty/unavailable after multiple retries -> `gitlab_ci_empty_logs`
14. If condition_message or pod logs contain 'Back-off pulling image' or 'failed to pull' -> `image_pull_failure`
15. If component creation test AND error contains 'Failed to retrieve Developer Hub task status' AND 'socket hang up' -> developer_hub_api_socket_hangup
16. If component creation test fails AND error contains 'Failed to create Developer Hub component' AND 'status code 401' -> component_creation_developer_hub_auth
17. If component creation fails AND error contains '500 Internal Server Error' AND step name contains 'publish' AND 'GitHub' -> component_creation_github_500
18. If logs contain 'tls: failed to verify certificate' AND ('tuf' OR 'root.json') AND 'Custom root CA variable is not set' -> tuf_tls_certificate_failure
19. If GitLab merge request creation succeeds AND subsequent pipeline lookup repeatedly returns 0 pipelines for the commit SHA AND error contains 'Pipeline not found or not yet running' -> gitlab_ci_pipeline_not_triggered
20. If Task name is 'provision-hive' AND (log contains 'timed out waiting for the condition on clusterclaims' OR 'Cluster failed to start in 60 minutes') -> `hive_provisioning_failure`
21. If component creation test fails AND error contains 'Failed to create Developer Hub component' AND 'status code 404' -> component_creation_developer_hub_404
22. If stage promotion pipeline fails AND annotations show 'chains.tekton.dev/signed: failed' AND verify/download tasks dependent on attestations fail -> tekton_chains_signing_failure
23. If test project name contains 'github-githubactions' AND error contains 'Pipeline not found or not yet running' AND error occurs during getPipelineAndWaitForCompletion -> github_actions_workflow_not_triggered
24. Otherwise -> `unknown`
