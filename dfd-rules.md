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

## Classification

The classification taxonomy and priority rules are in the component-specific rules file
(loaded alongside this file). Use those categories and rules to classify the failure.

### When You Classify as "unknown"

If you reach the `unknown` classification after exhausting all rules above, you **must**:

1. **Investigate deeper**: Re-examine the failure evidence. Read additional log files in
   `artifacts/cluster-artifacts/pods/`, check `events.json`, look at other K8s resources.
   Spend extra effort to identify the actual root cause pattern.

2. **Check for existing proposals from sibling agents**: Before writing a proposal, check if
   other agents already proposed a rule for the same root cause:
   ```
   ls ../*/rule_proposal.json
   ```
   If any exist, read them. If another agent already proposed a rule for the same underlying
   issue (even with different naming), do NOT write a duplicate — just use the already-proposed
   `root_cause` in your analysis instead of `unknown`.

3. **If you identify a clear, nameable root cause pattern**, write a proposal file to
   `{your_pipelinerun_directory}/rule_proposal.json` with **exactly** these field names
   (do NOT rename, add, or restructure them):

   ```json
   {
     "root_cause": "snake_case_id",
     "category": "infrastructure",
     "error_signature": "Brief description of the error pattern that identifies this failure",
     "priority_rule": "If {condition} -> `snake_case_id`",
     "reasoning": "Why this is a distinct, recurring failure pattern worth adding to the taxonomy",
     "pipelinerun": "the-pipelinerun-name"
   }
   ```

   **IMPORTANT**: Use these exact six field names. Do not use alternatives like
   `proposed_root_cause`, `description`, `detection_logic`, `example_signature`, etc.
   The merge script will reject proposals with wrong field names.

   Then use the proposed `root_cause` and `category` in your analysis output (not `unknown`).

4. **Do NOT propose a new rule if**:
   - The failure is a one-off fluke (classify as `test_flake` instead)
   - The failure fits an existing category but with slightly different wording
   - You are unsure whether the pattern would recur
   - A sibling agent already proposed a rule for the same issue

## Output Format

Write your analysis as markdown with **exactly** this structure. Do NOT rename sections,
reorder fields, move colons outside `**`, or add extra sections. The output is parsed by a
downstream script that depends on the exact format below.

```markdown
# Analysis: {pipelinerun-name}

## Summary

- **Root Cause:** `{root_cause_id}`
- **Category:** `{category}`
- **Component:** `{component from metadata.json}`
- **Failed Task:** `{task name}`
- **Failed Step:** `{step name}`
- **Completion Time:** {timestamp}

## Failed Test

- **Test Name:** {Ginkgo test name or "N/A" if not a test failure}
- **Error Message:** {one-line error}

## Evidence

```
{Key log lines or error output that led to the classification. Include 5-15 relevant lines.}
```

## Details

{1-3 sentences explaining what happened and why it was classified this way.
If a release pipeline failure, include the managed pipelinerun name and which task/step failed in it.}

## Suggested Action

{1-2 sentences on what to investigate or fix.}
```

### Formatting rules (IMPORTANT — output is machine-parsed)

- Section headers must be exactly `## Summary`, `## Failed Test`, `## Evidence`, `## Details`, `## Suggested Action`
- Each Summary field must be on its own line as `- **Field Name:** value` — colon INSIDE the bold markers
- Root Cause and Category values must use backtick-wrapped taxonomy IDs: `- **Root Cause:** \`rosa_provisioning_failure\``
- Do NOT use `### Classification` or any other heading variations
- Do NOT put the colon outside bold like `**Root Cause**: value` — it must be `**Root Cause:** value`

### Example output

```markdown
# Analysis: e2e-4.19-x5f2n

## Summary

- **Root Cause:** `rosa_provisioning_failure`
- **Category:** `infrastructure`
- **Component:** `tssc-cli`
- **Failed Task:** `provision-rosa`
- **Failed Step:** `provision`
- **Completion Time:** 2026-04-09T16:54:38Z

## Failed Test

- **Test Name:** N/A
- **Error Message:** ROSA cluster provisioning timed out

## Evidence

```
ERR: Cluster 'kx-6207678ac4' is not yet ready
certificate request has failed: 404 urn:ietf:params:acme:error:malformed
```

## Details

ROSA cluster provisioning failed due to a certificate error during cluster initialization.

## Suggested Action

Retry the pipeline. If recurring, investigate ACME certificate provisioning in the target region.
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
