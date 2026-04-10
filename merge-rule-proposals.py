#!/usr/bin/env python3
"""Merge agent rule proposals into per-component rule files.

After Phase 2 agents analyze failures, those that classify as "unknown" may
write rule_proposal.json files suggesting new taxonomy entries. This script
collects those proposals, validates them, deduplicates (using Claude for
semantic dedup when there are multiple proposals for the same component),
and inserts new entries into the appropriate dfd-rules-{component}.md file.

Usage:
    python3 merge-rule-proposals.py \
        --runs-dir runs/2026-04-10 \
        --rules-dir .

Exit codes:
    0 — success (rules may or may not have been updated)
    1 — error
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
from collections import defaultdict


REQUIRED_FIELDS = ["root_cause", "category", "error_signature", "priority_rule", "reasoning"]
ROOT_CAUSE_PATTERN = re.compile(r"^[a-z][a-z0-9_]{2,50}$")


def find_proposals(runs_dir):
    """Find and load all rule_proposal.json files, enriching with component from metadata.json."""
    proposals = []
    pattern = os.path.join(runs_dir, "*", "rule_proposal.json")
    for path in sorted(glob.glob(pattern)):
        try:
            with open(path) as f:
                data = json.load(f)
            data["_source_file"] = path

            # Read component from sibling metadata.json
            pr_dir = os.path.dirname(path)
            metadata_path = os.path.join(pr_dir, "metadata.json")
            if os.path.exists(metadata_path):
                with open(metadata_path) as mf:
                    metadata = json.load(mf)
                data["_component"] = metadata.get("component", "unknown")
            else:
                data["_component"] = "unknown"

            proposals.append(data)
        except (json.JSONDecodeError, IOError) as e:
            print(f"WARNING: Skipping invalid proposal {path}: {e}")
    return proposals


def validate_proposal(proposal):
    """Validate a single proposal. Returns (is_valid, error_message)."""
    for field in REQUIRED_FIELDS:
        if field not in proposal or not str(proposal[field]).strip():
            return False, f"missing or empty field: {field}"

    if not ROOT_CAUSE_PATTERN.match(proposal["root_cause"]):
        return False, f"invalid root_cause format: {proposal['root_cause']} (must be snake_case, 3-51 chars)"

    if len(proposal["error_signature"]) < 10:
        return False, f"error_signature too short: {proposal['error_signature']}"

    return True, None


def extract_existing_root_causes(rules_text):
    """Parse the taxonomy table to get existing root_cause IDs."""
    existing = set()
    for line in rules_text.split("\n"):
        match = re.match(r"\|\s*`(\w+)`\s*\|", line)
        if match:
            existing.add(match.group(1))
    return existing


def deduplicate_with_claude(proposals, existing_root_causes):
    """Use Claude to semantically deduplicate proposals.

    When multiple agents encounter similar failures, they may propose
    different root_cause names for the same underlying issue. This uses
    Claude to group equivalent proposals and pick the best representative.
    """
    if len(proposals) <= 1:
        return proposals

    proposals_text = json.dumps(
        [
            {
                "root_cause": p["root_cause"],
                "category": p["category"],
                "error_signature": p["error_signature"],
                "priority_rule": p["priority_rule"],
                "reasoning": p["reasoning"],
            }
            for p in proposals
        ],
        indent=2,
    )

    existing_text = ", ".join(sorted(existing_root_causes)) if existing_root_causes else "(none)"

    prompt = f"""You are deduplicating rule proposals for a CI failure classification taxonomy.

Multiple AI agents analyzed different CI failures and proposed new taxonomy rules. Some proposals
may describe the same underlying root cause using different names or wording. Your job is to:

1. Group semantically equivalent proposals (same root cause, different naming)
2. For each group, pick the best representative (clearest name, best error_signature, best priority_rule)
3. Return ONLY the deduplicated list

Existing root causes in the taxonomy (do NOT duplicate these):
{existing_text}

Proposals to deduplicate:
{proposals_text}

Respond with ONLY a JSON array of the deduplicated proposals. Each element must have exactly these fields:
root_cause, category, error_signature, priority_rule, reasoning

Do not add any other text, explanation, or markdown formatting. Just the JSON array."""

    try:
        result = subprocess.run(
            ["claude", "-p", prompt, "--output-format", "json", "--max-budget-usd", "0.50"],
            capture_output=True,
            text=True,
            timeout=120,
        )

        if result.returncode != 0:
            print(f"WARNING: Claude dedup failed (exit {result.returncode}), using all proposals")
            return proposals

        # Parse Claude's JSON output format
        output = json.loads(result.stdout)
        for item in output:
            if item.get("type") == "result":
                result_text = item.get("result", "").strip()
                # Strip markdown code fences if present
                if result_text.startswith("```"):
                    result_text = re.sub(r"^```\w*\n?", "", result_text)
                    result_text = re.sub(r"\n?```$", "", result_text)
                deduped = json.loads(result_text)
                print(f"Claude dedup: {len(proposals)} proposals -> {len(deduped)} unique")
                return deduped

        print("WARNING: Could not parse Claude output, using all proposals")
        return proposals

    except (subprocess.TimeoutExpired, json.JSONDecodeError, Exception) as e:
        print(f"WARNING: Claude dedup error ({e}), using all proposals")
        return proposals


def insert_taxonomy_rows(rules_text, new_rules):
    """Insert new rows into the taxonomy table before the 'unknown' row."""
    lines = rules_text.split("\n")
    result = []
    inserted = False

    for line in lines:
        # Insert before the unknown row
        if not inserted and re.match(r"\|\s*`unknown`\s*\|", line):
            for rule in new_rules:
                result.append(
                    f"| `{rule['root_cause']}` | {rule['category']} | {rule['error_signature']} |"
                )
            inserted = True
        result.append(line)

    return "\n".join(result)


def insert_priority_rules(rules_text, new_rules):
    """Insert new priority rules before 'Otherwise -> unknown'."""
    lines = rules_text.split("\n")
    result = []
    inserted = False

    for line in lines:
        # Insert before "Otherwise -> unknown"
        if not inserted and re.match(r"\d+\.\s+Otherwise\s*->\s*`unknown`", line):
            # Extract the current rule number
            match = re.match(r"(\d+)\.", line)
            if match:
                rule_num = int(match.group(1))
                for i, rule in enumerate(new_rules):
                    result.append(f"{rule_num + i}. {rule['priority_rule']}")
                # Renumber the "Otherwise" rule
                line = f"{rule_num + len(new_rules)}. Otherwise -> `unknown`"
            inserted = True
        result.append(line)

    return "\n".join(result)


def process_component(component, proposals, rules_file):
    """Process proposals for a single component, updating its rules file."""
    print(f"\n=== Processing {component} ({len(proposals)} proposal(s)) ===")

    # Read existing rules
    if os.path.exists(rules_file):
        with open(rules_file) as f:
            rules_text = f.read()
    else:
        print(f"  Rules file {rules_file} does not exist, skipping")
        return False

    existing = extract_existing_root_causes(rules_text)
    print(f"  Existing taxonomy has {len(existing)} root causes.")

    # Deduplicate against existing rules
    novel = [p for p in proposals if p["root_cause"] not in existing]
    skipped = len(proposals) - len(novel)
    if skipped > 0:
        print(f"  Skipped {skipped} proposal(s) that duplicate existing rules.")

    if not novel:
        print(f"  No new rules for {component}.")
        return False

    # Semantic dedup across proposals (uses Claude if 2+)
    deduped = deduplicate_with_claude(novel, existing)

    # Final check
    final = [p for p in deduped if p["root_cause"] not in existing]
    if not final:
        print(f"  No new rules after deduplication.")
        return False

    # Insert into taxonomy table and priority rules
    rules_text = insert_taxonomy_rows(rules_text, final)
    rules_text = insert_priority_rules(rules_text, final)

    # Write
    with open(rules_file, "w") as f:
        f.write(rules_text)

    print(f"  Added {len(final)} new rule(s) to {rules_file}:")
    for p in final:
        print(f"    + {p['root_cause']} ({p['category']}): {p['error_signature']}")
    return True


def main():
    parser = argparse.ArgumentParser(description="Merge rule proposals into per-component rule files")
    parser.add_argument("--runs-dir", required=True, help="Path to the runs directory")
    parser.add_argument("--rules-dir", required=True, help="Directory containing dfd-rules-{component}.md files")
    args = parser.parse_args()

    # 1. Find proposals
    proposals = find_proposals(args.runs_dir)
    if not proposals:
        print("No rule proposals found.")
        return

    print(f"Found {len(proposals)} proposal(s):")
    for p in proposals:
        print(f"  - {p.get('root_cause', '???')} ({p['_component']}) from {p.get('_source_file', '?')}")
        # Log actual keys for debugging
        keys = [k for k in p.keys() if not k.startswith("_")]
        print(f"    keys: {keys}")

    # 2. Validate
    valid = []
    for p in proposals:
        is_valid, error = validate_proposal(p)
        if is_valid:
            valid.append(p)
        else:
            print(f"  SKIPPED (invalid): {p.get('root_cause', '?')} — {error}")

    if not valid:
        print("No valid proposals after validation.")
        return

    # 3. Group by component
    by_component = defaultdict(list)
    for p in valid:
        by_component[p["_component"]].append(p)

    # 4. Process each component
    any_updated = False
    for component, comp_proposals in sorted(by_component.items()):
        rules_file = os.path.join(args.rules_dir, f"dfd-rules-{component}.md")
        updated = process_component(component, comp_proposals, rules_file)
        if updated:
            any_updated = True

    if not any_updated:
        print("\nNo rule files were updated.")
    else:
        print("\nRule files updated successfully.")


if __name__ == "__main__":
    main()
