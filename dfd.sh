#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# DFD — Dumpster Fire Diving
# Because our dumpsters are always on fire.
#
# Dives into failed e2e pipelineruns via KubeArchive, downloads artifacts,
# spawns parallel Claude sub-agents for per-failure analysis, then consolidates
# into a single report.
#
# Usage:
#   export TOKEN="sha256~..."   # OCP bearer token for KubeArchive
#   ./dfd.sh [HOURS_BACK] [MAX_PARALLEL] [COMPONENTS...]
#
# Optional env vars:
#   PAGES_DATA_DIR  — If set, path to directory containing component JSON
#                     files (e.g. pages/public/data). Used to skip pipelineruns
#                     already present. If unset, all failures are analyzed.
#
# Components: tsf-cli (default), tssc-cli, tssc-test
# Examples:
#   ./dfd.sh                        # tsf-cli, last 24h, 5 parallel
#   ./dfd.sh 48 8                   # tsf-cli, last 48h, 8 parallel
#   ./dfd.sh 24 5 tssc-cli tssc-test  # both tssc repos
#   ./dfd.sh 24 5 tsf-cli tssc-cli    # tsf + tssc-cli
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOURS_BACK="${1:-24}"
MAX_PARALLEL="${2:-5}"

# Remaining args are component names; default to tsf-cli
shift 2 2>/dev/null || true
if [[ $# -gt 0 ]]; then
    COMPONENTS=("$@")
else
    COMPONENTS=("tsf-cli")
fi

# --- Per-component configuration ---
declare -A COMPONENT_LABELS
declare -A COMPONENT_PR_PREFIXES
declare -A COMPONENT_ORAS_REPOS
declare -A COMPONENT_DISPLAY_NAMES

COMPONENT_LABELS[tsf-cli]="appstudio.openshift.io/component=tsf-cli"
COMPONENT_PR_PREFIXES[tsf-cli]="tsf-e2e-"
COMPONENT_ORAS_REPOS[tsf-cli]="quay.io/konflux-test-storage/rhads/tsf-cli"
COMPONENT_DISPLAY_NAMES[tsf-cli]="TSF"

COMPONENT_LABELS[tssc-cli]="appstudio.openshift.io/component=tssc-cli"
COMPONENT_PR_PREFIXES[tssc-cli]="e2e-"
COMPONENT_ORAS_REPOS[tssc-cli]="quay.io/konflux-test-storage/rhtap-team/rhtap-cli"
COMPONENT_DISPLAY_NAMES[tssc-cli]="TSSC CLI"

COMPONENT_LABELS[tssc-test]="appstudio.openshift.io/component=tssc-test"
COMPONENT_PR_PREFIXES[tssc-test]="e2e-"
COMPONENT_ORAS_REPOS[tssc-test]="quay.io/konflux-test-storage/rhtap-team/rhtap-cli"
COMPONENT_DISPLAY_NAMES[tssc-test]="TSSC Test"

# Validate component names
for comp in "${COMPONENTS[@]}"; do
    if [[ -z "${COMPONENT_LABELS[$comp]:-}" ]]; then
        echo "ERROR: Unknown component '$comp'. Valid components: tsf-cli, tssc-cli, tssc-test" >&2
        exit 1
    fi
done

# --- Constants ---
KUBEARCHIVE_BASE="${KUBEARCHIVE_BASE:-}"
ARTIFACT_BROWSER_BASE="${ARTIFACT_BROWSER_BASE:-}"
NAMESPACE="rhtap-shared-team-tenant"

# --- Output directory ---
TODAY="$(date +%Y-%m-%d)"
RUN_DIR="${SCRIPT_DIR}/runs/${TODAY}"
mkdir -p "${RUN_DIR}"

# --- Logging ---
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }
warn() { echo "[$(date +%H:%M:%S)] WARNING: $*" >&2; }
err()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; }

# =============================================================================
# Pre-flight checks
# =============================================================================

# Source .env file if present (for TOKEN)
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/.env"
fi

if [[ -z "${TOKEN:-}" ]]; then
    err "TOKEN is not set."
    echo "Either:" >&2
    echo "  1. cp .env.template .env  and fill in your values" >&2
    echo "  2. export TOKEN=\"sha256~...\"" >&2
    exit 1
fi

if [[ -z "${KUBEARCHIVE_BASE:-}" ]]; then
    err "KUBEARCHIVE_BASE is not set. Set it in .env or export it."
    exit 1
fi

if [[ -z "${ARTIFACT_BROWSER_BASE:-}" ]]; then
    err "ARTIFACT_BROWSER_BASE is not set. Set it in .env or export it."
    exit 1
fi

if ! command -v claude &>/dev/null; then
    err "claude CLI not found in PATH"
    exit 1
fi

if ! command -v oras &>/dev/null; then
    warn "oras CLI not found — will skip artifact downloads"
    HAS_ORAS=false
else
    HAS_ORAS=true
fi

if ! command -v jq &>/dev/null; then
    err "jq not found in PATH"
    exit 1
fi

log "Checking KubeArchive access..."
HTTP_CODE=$(curl -s -k -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${TOKEN}" \
    "${KUBEARCHIVE_BASE}/apis/tekton.dev/v1/namespaces/${NAMESPACE}/pipelineruns?limit=1")

if [[ "${HTTP_CODE}" == "401" || "${HTTP_CODE}" == "403" ]]; then
    err "KubeArchive returned ${HTTP_CODE} — token is expired or invalid."
    echo "Re-authenticate and export TOKEN again." >&2
    exit 1
elif [[ "${HTTP_CODE}" != "200" ]]; then
    warn "KubeArchive returned HTTP ${HTTP_CODE} (expected 200). Proceeding anyway."
fi

COMPONENTS_STR="${COMPONENTS[*]}"
log "Pre-flight OK. Investigating last ${HOURS_BACK} hours, max ${MAX_PARALLEL} parallel agents."
log "Components: ${COMPONENTS_STR}"

# =============================================================================
# Phase 1: Data Collection
# =============================================================================

log "=== Phase 1: Data Collection ==="

# Calculate cutoff time
if [[ "$(uname)" == "Darwin" ]]; then
    CUTOFF=$(date -u -v-${HOURS_BACK}H +"%Y-%m-%dT%H:%M:%SZ")
else
    CUTOFF=$(date -u -d "${HOURS_BACK} hours ago" +"%Y-%m-%dT%H:%M:%SZ")
fi
log "Cutoff time: ${CUTOFF}"

# --- Fetch and filter pipelineruns for each component ---
FAILED_PRS_FILE="${RUN_DIR}/failed_prs.txt"
> "${FAILED_PRS_FILE}"  # truncate

for COMP in "${COMPONENTS[@]}"; do
    COMPONENT_LABEL="${COMPONENT_LABELS[$COMP]}"
    PR_PREFIX="${COMPONENT_PR_PREFIXES[$COMP]}"
    DISPLAY_NAME="${COMPONENT_DISPLAY_NAMES[$COMP]}"

    log "[${DISPLAY_NAME}] Fetching pipelineruns from KubeArchive..."
    PIPELINERUNS_FILE="${RUN_DIR}/all_pipelineruns_${COMP}.json"
    curl -s -k --max-time 120 --retry 3 --retry-delay 5 -H "Authorization: Bearer ${TOKEN}" \
        "${KUBEARCHIVE_BASE}/apis/tekton.dev/v1/namespaces/${NAMESPACE}/pipelineruns?labelSelector=${COMPONENT_LABEL}" \
        -o "${PIPELINERUNS_FILE}"

    python3 -c "
import json, sys
from datetime import datetime

cutoff_str = '${CUTOFF}'.replace('T', ' ').replace('Z', '')
cutoff = datetime.strptime(cutoff_str, '%Y-%m-%d %H:%M:%S')

with open('${PIPELINERUNS_FILE}', 'r', errors='replace') as f:
    data = json.loads(f.read())

total = 0
success = 0
failed = 0
aborted = 0
failed_prs = []
all_filtered = []

for item in data.get('items', []):
    name = item['metadata']['name']
    if not name.startswith('${PR_PREFIX}'):
        continue

    ct = item.get('status', {}).get('completionTime', '')
    if not ct:
        continue

    ct_clean = ct.replace('T', ' ').replace('Z', '').split('.')[0]
    try:
        ct_dt = datetime.strptime(ct_clean, '%Y-%m-%d %H:%M:%S')
    except ValueError:
        continue

    if ct_dt < cutoff:
        continue

    total += 1
    status = 'UNKNOWN'
    for c in item.get('status', {}).get('conditions', []):
        if c.get('type') == 'Succeeded':
            if c['status'] == 'True':
                status = 'SUCCESS'
                success += 1
            elif c.get('reason') == 'Cancelled' or c.get('reason') == 'StoppedRunFinally':
                status = 'ABORTED'
                aborted += 1
            else:
                status = 'FAILURE'
                failed += 1

    if status == 'UNKNOWN':
        continue

    run_status = {'SUCCESS': 'succeeded', 'FAILURE': 'failed', 'ABORTED': 'aborted'}[status]
    all_filtered.append({
        'pipelinerun': name,
        'component': '${COMP}',
        'completion_time': ct,
        'status': run_status,
    })

    if status == 'FAILURE':
        failed_prs.append(name)

print(f'Total: {total}, Success: {success}, Failed: {failed}, Aborted: {aborted}', file=sys.stderr)

# Write all filtered runs for extract-data.py
with open('${RUN_DIR}/filtered_runs_${COMP}.json', 'w') as f:
    json.dump(all_filtered, f, indent=2)

for pr in failed_prs:
    # Output component|pipelinerun so we know which component each PR belongs to
    print(f'${COMP}|{pr}')
" >> "${FAILED_PRS_FILE}" 2>&1 | head -1 >&2 || true

    # Clean up summary line if it leaked into the file
    sed -i '/^Total:/d' "${FAILED_PRS_FILE}"

    log "[${DISPLAY_NAME}] Done."
done

# --- Deduplicate: skip pipelineruns already analyzed in published data ---
if [[ -n "${PAGES_DATA_DIR:-}" ]]; then
    KNOWN_PRS_FILE="${RUN_DIR}/known_prs.txt"
    > "${KNOWN_PRS_FILE}"

    for COMP in "${COMPONENTS[@]}"; do
        COMP_JSON_FILE="${PAGES_DATA_DIR}/${COMP}.json"

        if [[ -f "${COMP_JSON_FILE}" ]]; then
            log "[${COMP}] Reading published data for dedup from ${COMP_JSON_FILE}..."
            python3 -c "
import json, sys
try:
    with open('${COMP_JSON_FILE}') as f:
        data = json.load(f)
    for run in data:
        pr = run.get('pipelinerun', '')
        if pr:
            print(pr)
except Exception as e:
    print(f'Warning: failed to parse ${COMP_JSON_FILE}: {e}', file=sys.stderr)
" >> "${KNOWN_PRS_FILE}" 2>/dev/null
        else
            warn "[${COMP}] No published data at ${COMP_JSON_FILE} — skipping dedup for this component"
        fi
    done

    KNOWN_COUNT=$(wc -l < "${KNOWN_PRS_FILE}" | tr -d ' ')
    if [[ "${KNOWN_COUNT}" -gt 0 ]]; then
        ORIGINAL_COUNT=$(wc -l < "${FAILED_PRS_FILE}" | tr -d ' ')
        python3 -c "
known = set()
with open('${KNOWN_PRS_FILE}') as f:
    for line in f:
        known.add(line.strip())
kept = []
skipped = 0
with open('${FAILED_PRS_FILE}') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        pr_name = line.split('|', 1)[1] if '|' in line else line
        if pr_name in known:
            skipped += 1
        else:
            kept.append(line)
with open('${FAILED_PRS_FILE}', 'w') as f:
    for line in kept:
        f.write(line + '\n')
import sys
print(f'Dedup: {skipped} already-analyzed, {len(kept)} new to process', file=sys.stderr)
" 2>&1 | head -1 | while read -r msg; do log "${msg}"; done
        NEW_COUNT=$(wc -l < "${FAILED_PRS_FILE}" | tr -d ' ')
        log "After dedup: ${ORIGINAL_COUNT} failed -> ${NEW_COUNT} new (skipped ${KNOWN_COUNT} known)"
    else
        log "No previously analyzed pipelineruns found — analyzing all failures"
    fi
fi

FAILED_COUNT=$(wc -l < "${FAILED_PRS_FILE}" | tr -d ' ')
log "Found ${FAILED_COUNT} total failed pipelineruns across all components"

if [[ "${FAILED_COUNT}" -eq 0 ]]; then
    log "No failures found in the last ${HOURS_BACK} hours."
    echo "No e2e failures in the last ${HOURS_BACK} hours for: ${COMPONENTS_STR}" > "${RUN_DIR}/consolidated-report.md"
    exit 0
fi

# --- Collect data for each failed PR ---
collect_pr_data() {
    local COMP="$1"
    local PR_NAME="$2"
    local ORAS_REPO="${COMPONENT_ORAS_REPOS[$COMP]}"
    local PR_DIR="${RUN_DIR}/${PR_NAME}"
    mkdir -p "${PR_DIR}/kubearchive" "${PR_DIR}/artifacts"

    # Skip if data already collected
    if [[ -f "${PR_DIR}/metadata.json" && -f "${PR_DIR}/kubearchive/taskruns.json" ]]; then
        log "[${PR_NAME}] Data already present — skipping collection"
        return
    fi

    log "[${PR_NAME}] Collecting data..."

    # Fetch taskruns from KubeArchive
    curl -s -k --max-time 120 --retry 3 --retry-delay 5 -H "Authorization: Bearer ${TOKEN}" \
        "${KUBEARCHIVE_BASE}/apis/tekton.dev/v1/namespaces/${NAMESPACE}/taskruns?labelSelector=tekton.dev/pipelineRun=${PR_NAME}" \
        -o "${PR_DIR}/kubearchive/taskruns.json" 2>/dev/null || true

    # Extract metadata (failed task, step, pod)
    python3 -c "
import json, sys

with open('${PR_DIR}/kubearchive/taskruns.json', 'r', errors='replace') as f:
    data = json.loads(f.read())

result = {
    'pipelinerun': '${PR_NAME}',
    'component': '${COMP}',
    'failed_task': None,
    'failed_step': None,
    'pod_name': None,
    'completion_time': None,
    'condition_message': None
}

for tr in data.get('items', []):
    task = tr['metadata'].get('labels', {}).get('tekton.dev/pipelineTask', '?')
    ct = tr.get('status', {}).get('completionTime', '')

    for c in tr.get('status', {}).get('conditions', []):
        if c.get('type') == 'Succeeded' and c.get('status') == 'False':
            result['failed_task'] = task
            result['pod_name'] = tr.get('status', {}).get('podName', '')
            result['completion_time'] = ct
            result['condition_message'] = c.get('message', '')[:300]

            for s in tr.get('status', {}).get('steps', []):
                t = s.get('terminated', {})
                if t.get('exitCode', 0) != 0:
                    result['failed_step'] = s['name']
                    break

            if result['failed_step']:
                break

print(json.dumps(result, indent=2))
" > "${PR_DIR}/metadata.json" 2>/dev/null || echo '{"pipelinerun":"'"${PR_NAME}"'","component":"'"${COMP}"'","error":"failed to parse taskruns"}' > "${PR_DIR}/metadata.json"

    # Read metadata for pod log fetch
    local FAILED_STEP POD_NAME
    FAILED_STEP=$(jq -r '.failed_step // empty' "${PR_DIR}/metadata.json" 2>/dev/null || true)
    POD_NAME=$(jq -r '.pod_name // empty' "${PR_DIR}/metadata.json" 2>/dev/null || true)

    # Fetch failed step pod log from KubeArchive
    if [[ -n "${POD_NAME}" && -n "${FAILED_STEP}" ]]; then
        curl -s -k --max-time 60 --retry 3 --retry-delay 5 -H "Authorization: Bearer ${TOKEN}" \
            "${KUBEARCHIVE_BASE}/api/v1/namespaces/${NAMESPACE}/pods/${POD_NAME}/log?container=step-${FAILED_STEP}&tailLines=500" \
            -o "${PR_DIR}/kubearchive/failed_step.log" 2>/dev/null || true
    fi

    # Download artifacts via oras (if available)
    if [[ "${HAS_ORAS}" == "true" ]]; then
        if [[ -d "${PR_DIR}/artifacts/cluster-artifacts" ]]; then
            log "[${PR_NAME}] Artifacts already present — skipping oras pull"
        else
            (cd "${PR_DIR}/artifacts" && oras pull "${ORAS_REPO}:${PR_NAME}" 2>/dev/null) || \
                warn "[${PR_NAME}] oras pull failed — continuing with kubearchive data only"
        fi
    fi

    log "[${PR_NAME}] Data collection complete."
}

# Run data collection in parallel
JOBS_RUNNING=0
while IFS= read -r LINE; do
    [[ -z "${LINE}" ]] && continue
    COMP="${LINE%%|*}"
    PR_NAME="${LINE#*|}"
    collect_pr_data "${COMP}" "${PR_NAME}" < /dev/null &
    JOBS_RUNNING=$((JOBS_RUNNING + 1))

    if [[ ${JOBS_RUNNING} -ge ${MAX_PARALLEL} ]]; then
        wait -n 2>/dev/null || true
        JOBS_RUNNING=$((JOBS_RUNNING - 1))
    fi
done < "${FAILED_PRS_FILE}"
wait
log "Phase 1 complete. Data collected for ${FAILED_COUNT} failed pipelineruns."

# =============================================================================
# Phase 2: Per-Failure Analysis (parallel Claude sub-agents)
# =============================================================================

log "=== Phase 2: Per-Failure Analysis ==="

# Cost tracking
COST_DIR="${RUN_DIR}/cost"
mkdir -p "${COST_DIR}"

analyze_pr() {
    local COMP="$1"
    local PR_NAME="$2"
    local PR_DIR="${RUN_DIR}/${PR_NAME}"

    if [[ ! -f "${PR_DIR}/metadata.json" ]]; then
        warn "[${PR_NAME}] No metadata.json — skipping analysis"
        return
    fi

    if [[ -s "${PR_DIR}/analysis.md" ]]; then
        log "[${PR_NAME}] Analysis already present — skipping"
        return
    fi

    log "[${PR_NAME}] Starting Claude analysis..."

    local PROMPT="Analyze the failed e2e pipelinerun in directory: ${PR_DIR}

Start by reading ${PR_DIR}/metadata.json to understand which task/step failed and which component this belongs to.
Then read ${PR_DIR}/kubearchive/failed_step.log for the pod log.
If the failure involves a release pipeline, check ${PR_DIR}/artifacts/cluster-artifacts/ for managed pipelinerun data.

Follow the investigation workflow and classification rules in your system prompt.
Output your analysis as markdown following the specified format.

If you classify the failure as unknown but discover a new recognizable pattern, write a rule proposal to ${PR_DIR}/rule_proposal.json following the instructions in your system prompt."

    local CLAUDE_JSON="${PR_DIR}/claude_output.json"
    claude -p "${PROMPT}" \
        --verbose \
        --output-format json \
        --dangerously-skip-permissions \
        --allowedTools "Read,Write(${PR_DIR}/rule_proposal.json),Bash(cat*),Bash(ls*),Bash(head*),Bash(tail*),Bash(find*),Bash(gunzip*),Bash(wc*),Bash(file*),Bash(grep*)" \
        --append-system-prompt-file "${SCRIPT_DIR}/dfd-rules.md" \
        --append-system-prompt-file "${SCRIPT_DIR}/dfd-rules-${COMP}.md" \
        --max-budget-usd 5.00 \
        > "${CLAUDE_JSON}" 2> "${PR_DIR}/claude_stderr.log" || {
            warn "[${PR_NAME}] Claude analysis failed (exit code $?)"
            warn "[${PR_NAME}] stderr: $(cat "${PR_DIR}/claude_stderr.log")"
            printf '%s\n' "# Analysis: ${PR_NAME}" "" "## Summary" "" "- **Root Cause:** unknown" "- **Category:** unknown" "" "Claude analysis failed to complete." > "${PR_DIR}/analysis.md"
            return
        }

    # Extract analysis text and cost data from JSON output
    python3 -c "
import json, sys
with open('${CLAUDE_JSON}') as f:
    data = json.load(f)
for item in data:
    if item.get('type') == 'result':
        with open('${PR_DIR}/analysis.md', 'w') as out:
            out.write(item.get('result', ''))
        cost = {
            'invocation': '${PR_NAME}',
            'cost_usd': item.get('total_cost_usd', 0),
            'input_tokens': item.get('usage', {}).get('input_tokens', 0),
            'output_tokens': item.get('usage', {}).get('output_tokens', 0),
            'cache_read_tokens': item.get('usage', {}).get('cache_read_input_tokens', 0),
            'cache_creation_tokens': item.get('usage', {}).get('cache_creation_input_tokens', 0),
            'duration_ms': item.get('duration_api_ms', 0),
        }
        with open('${COST_DIR}/${PR_NAME}.json', 'w') as cf:
            json.dump(cost, cf, indent=2)
        break
" 2>/dev/null
    rm -f "${CLAUDE_JSON}"

    log "[${PR_NAME}] Analysis complete."
}

JOBS_RUNNING=0
while IFS= read -r LINE; do
    [[ -z "${LINE}" ]] && continue
    COMP="${LINE%%|*}"
    PR_NAME="${LINE#*|}"
    analyze_pr "${COMP}" "${PR_NAME}" < /dev/null &
    JOBS_RUNNING=$((JOBS_RUNNING + 1))

    if [[ ${JOBS_RUNNING} -ge ${MAX_PARALLEL} ]]; then
        wait -n 2>/dev/null || true
        JOBS_RUNNING=$((JOBS_RUNNING - 1))
    fi
done < "${FAILED_PRS_FILE}"
wait
log "Phase 2 complete. All analyses finished."

# =============================================================================
# Phase 2.5: Merge Rule Proposals (self-evolving taxonomy)
# =============================================================================

log "=== Phase 2.5: Rule Proposal Merge ==="

PROPOSALS_FOUND=$(find "${RUN_DIR}" -name "rule_proposal.json" -type f | wc -l | tr -d ' ')
if [[ "${PROPOSALS_FOUND}" -gt 0 ]]; then
    log "Found ${PROPOSALS_FOUND} rule proposal(s). Merging into dfd-rules.md..."
    python3 "${SCRIPT_DIR}/merge-rule-proposals.py" \
        --runs-dir "${RUN_DIR}" \
        --rules-dir "${SCRIPT_DIR}" \
        2>&1 | while IFS= read -r line; do log "[rules-merge] ${line}"; done
else
    log "No rule proposals found. Taxonomy unchanged."
fi

# =============================================================================
# Phase 3: Consolidation
# =============================================================================

log "=== Phase 3: Consolidation ==="

# Build the list of analysis files
ANALYSIS_LIST=""
while IFS= read -r LINE; do
    [[ -z "${LINE}" ]] && continue
    PR_NAME="${LINE#*|}"
    if [[ -f "${RUN_DIR}/${PR_NAME}/analysis.md" ]]; then
        ANALYSIS_LIST="${ANALYSIS_LIST} ${RUN_DIR}/${PR_NAME}/analysis.md"
    fi
done < "${FAILED_PRS_FILE}"

# Also build a summary of all pipelineruns (not just failed) for context
# Aggregate across all component files
TOTAL_RUNS=$(python3 -c "
import json, sys, glob
from datetime import datetime

cutoff_str = '${CUTOFF}'.replace('T', ' ').replace('Z', '')
cutoff = datetime.strptime(cutoff_str, '%Y-%m-%d %H:%M:%S')

components = '${COMPONENTS_STR}'.split()
prefixes = {
    'tsf-cli': 'tsf-e2e-',
    'tssc-cli': 'e2e-',
    'tssc-test': 'e2e-',
}

total = success = failed = aborted = 0

for comp in components:
    pr_file = '${RUN_DIR}/all_pipelineruns_' + comp + '.json'
    prefix = prefixes[comp]
    try:
        with open(pr_file, 'r', errors='replace') as f:
            data = json.loads(f.read())
    except (FileNotFoundError, json.JSONDecodeError):
        continue

    for item in data.get('items', []):
        name = item['metadata']['name']
        if not name.startswith(prefix): continue
        ct = item.get('status', {}).get('completionTime', '')
        if not ct: continue
        ct_clean = ct.replace('T', ' ').replace('Z', '').split('.')[0]
        try:
            ct_dt = datetime.strptime(ct_clean, '%Y-%m-%d %H:%M:%S')
        except ValueError: continue
        if ct_dt < cutoff: continue
        total += 1
        for c in item.get('status', {}).get('conditions', []):
            if c.get('type') == 'Succeeded':
                if c['status'] == 'True': success += 1
                elif c.get('reason') in ('Cancelled', 'StoppedRunFinally'): aborted += 1
                else: failed += 1

print(f'{total}|{success}|{failed}|{aborted}')
" 2>/dev/null || echo "?|?|?|?")

IFS='|' read -r T_TOTAL T_SUCCESS T_FAILED T_ABORTED <<< "${TOTAL_RUNS}"
PASS_RATE="N/A"
if [[ "${T_TOTAL}" =~ ^[0-9]+$ && "${T_TOTAL}" -gt 0 ]]; then
    PASS_RATE=$(python3 -c "print(f'{${T_SUCCESS}/${T_TOTAL}*100:.0f}%')" 2>/dev/null || echo "N/A")
fi

CONSOLIDATION_PROMPT="You are producing a consolidated e2e failure investigation report.

## Context

- Components investigated: ${COMPONENTS_STR}
- Time window: last ${HOURS_BACK} hours (cutoff: ${CUTOFF})
- Total pipelineruns: ${T_TOTAL}
- Success: ${T_SUCCESS} (${PASS_RATE})
- Failed: ${T_FAILED}
- Aborted: ${T_ABORTED}

## Individual Analyses

Read each of these analysis files — they are per-failure investigations by other agents:

$(for f in ${ANALYSIS_LIST}; do echo "- ${f}"; done)

## Your Task

Produce a consolidated report in this exact format:

# E2E Investigation Report — ${TODAY}

## Overview

| Metric | Value |
|---|---|
| Components | ${COMPONENTS_STR} |
| Time window | Last ${HOURS_BACK} hours |
| Total runs | {total} |
| Success | {count} ({percent}%) |
| Failed | {count} ({percent}%) |
| Aborted | {count} ({percent}%) |
| Pass rate | {percent}% |

## Failed Task Breakdown

| Component | Failed Task | Count | % of failures |
|---|---|---|---|
| {component} | {task} | {count} | {percent}% |

## Failure Categories

For each root_cause category found, create a section:

### {Category Name} ({count} runs, {percent}%)

| PipelineRun | Component | Completion Time |
|---|---|---|
| {name} | {component} | {time} |

**Error:** {common error pattern}

**Details:** {1-3 sentences}

**Suggested Action:** {what to fix}

## Summary of Root Causes

| Root Cause | Category | Count | % |
|---|---|---|---|
| {root_cause} | {category} | {count} | {percent}% |

## Recommended Actions

{Prioritized list of actions based on frequency and impact}

---
Be concise. Group similar failures. Prioritize by frequency. Do not repeat raw log output."

CONSOLIDATION_JSON="${RUN_DIR}/consolidation_output.json"
log "Running consolidation claude command..."
claude -p "${CONSOLIDATION_PROMPT}" \
    --verbose \
    --output-format json \
    --dangerously-skip-permissions \
    --allowedTools "Read,Bash(cat*),Bash(ls*),Bash(head*),Bash(tail*),Bash(wc*)" \
    --max-budget-usd 5.00 \
    > "${CONSOLIDATION_JSON}" 2> "${RUN_DIR}/consolidation_stderr.log" || {
        err "Consolidation failed (exit code $?)"
        err "stderr output:"
        cat "${RUN_DIR}/consolidation_stderr.log" >&2
        err "stdout/JSON output:"
        cat "${CONSOLIDATION_JSON}" >&2
        echo "# Consolidation Failed" > "${RUN_DIR}/consolidated-report.md"
        echo "" >> "${RUN_DIR}/consolidated-report.md"
        echo "Individual analyses are available in each pipelinerun subdirectory." >> "${RUN_DIR}/consolidated-report.md"
    }

if [[ -f "${CONSOLIDATION_JSON}" ]]; then
    python3 -c "
import json
with open('${CONSOLIDATION_JSON}') as f:
    data = json.load(f)
for item in data:
    if item.get('type') == 'result':
        with open('${RUN_DIR}/consolidated-report.md', 'w') as out:
            out.write(item.get('result', ''))
        cost = {
            'invocation': 'consolidation',
            'cost_usd': item.get('total_cost_usd', 0),
            'input_tokens': item.get('usage', {}).get('input_tokens', 0),
            'output_tokens': item.get('usage', {}).get('output_tokens', 0),
            'cache_read_tokens': item.get('usage', {}).get('cache_read_input_tokens', 0),
            'cache_creation_tokens': item.get('usage', {}).get('cache_creation_input_tokens', 0),
            'duration_ms': item.get('duration_api_ms', 0),
        }
        with open('${COST_DIR}/consolidation.json', 'w') as cf:
            json.dump(cost, cf, indent=2)
        break
" 2>/dev/null
    rm -f "${CONSOLIDATION_JSON}"
fi

# =============================================================================
# Cost Summary
# =============================================================================

log "=== Cost Summary ==="
python3 -c "
import json, glob, os

cost_files = sorted(glob.glob('${COST_DIR}/*.json'))
if not cost_files:
    print('  No cost data captured.')
else:
    total_cost = 0
    total_input = 0
    total_output = 0
    print()
    print(f'  {\"Invocation\":<50} {\"Cost (USD)\":>10} {\"Input\":>8} {\"Output\":>8} {\"Duration\":>10}')
    print(f'  {\"-\" * 50} {\"-\" * 10} {\"-\" * 8} {\"-\" * 8} {\"-\" * 10}')
    for cf in cost_files:
        with open(cf) as f:
            c = json.load(f)
        name = c['invocation']
        if len(name) > 48:
            name = name[:45] + '...'
        cost = c.get('cost_usd', 0)
        inp = c.get('input_tokens', 0)
        out = c.get('output_tokens', 0)
        dur = c.get('duration_ms', 0)
        total_cost += cost
        total_input += inp
        total_output += out
        print(f'  {name:<50} \${cost:>9.4f} {inp:>8,} {out:>8,} {dur/1000:>9.1f}s')
    print(f'  {\"-\" * 50} {\"-\" * 10} {\"-\" * 8} {\"-\" * 8}')
    print(f'  {\"TOTAL\":<50} \${total_cost:>9.4f} {total_input:>8,} {total_output:>8,}')
    print()
" 2>&1 | while IFS= read -r line; do log "${line}"; done

log "=== Investigation Complete ==="
log "Report: ${RUN_DIR}/consolidated-report.md"
log "Individual analyses: ${RUN_DIR}/*/analysis.md"

# Print report path to stdout
echo "${RUN_DIR}/consolidated-report.md"
