#!/usr/bin/env python3
"""Merge agent rule proposals into dfd-rules.md.

After Phase 2 agents analyze failures, those that classify as "unknown" may
write rule_proposal.json files suggesting new taxonomy entries. This script
collects those proposals, validates them, deduplicates (using Claude for
semantic dedup when there are multiple proposals), and inserts new entries
into dfd-rules.md.

Usage:
    python3 merge-rule-proposals.py \
        --runs-dir runs/2026-04-10 \
        --rules-file dfd-rules.md \
        --output dfd-rules.md

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


REQUIRED_FIELDS = ["root_cause", "category", "error_signature", "priority_rule", "reasoning"]
ROOT_CAUSE_PATTERN = re.compile(r"^[a-z][a-z0-9_]{2,50}$")


def find_proposals(runs_dir):
    """Find and load all rule_proposal.json files."""
    proposals = []
    pattern = os.path.join(runs_dir, "*", "rule_proposal.json")
    for path in sorted(glob.glob(pattern)):
        try:
            with open(path) as f:
                data = json.load(f)
            data["_source_file"] = path
            proposals.append(data)
        except (json.JSONDecodeError, IOError) as e:
            print(f"WARNING: Skipping invalid proposal {path}: {e}", file=sys.stderr)
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
            print(f"WARNING: Claude dedup failed (exit {result.returncode}), using all proposals", file=sys.stderr)
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
                print(f"Claude dedup: {len(proposals)} proposals -> {len(deduped)} unique", file=sys.stderr)
                return deduped

        print("WARNING: Could not parse Claude output, using all proposals", file=sys.stderr)
        return proposals

    except (subprocess.TimeoutExpired, json.JSONDecodeError, Exception) as e:
        print(f"WARNING: Claude dedup error ({e}), using all proposals", file=sys.stderr)
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


def main():
    parser = argparse.ArgumentParser(description="Merge rule proposals into dfd-rules.md")
    parser.add_argument("--runs-dir", required=True, help="Path to the runs directory")
    parser.add_argument("--rules-file", required=True, help="Path to dfd-rules.md")
    parser.add_argument("--output", required=True, help="Output path for updated rules file")
    args = parser.parse_args()

    # 1. Find proposals
    proposals = find_proposals(args.runs_dir)
    if not proposals:
        print("No rule proposals found.")
        return

    print(f"Found {len(proposals)} proposal(s):")
    for p in proposals:
        print(f"  - {p['root_cause']} from {p.get('_source_file', '?')}")

    # 2. Validate
    valid_proposals = []
    for p in proposals:
        is_valid, error = validate_proposal(p)
        if is_valid:
            valid_proposals.append(p)
        else:
            print(f"  SKIPPED (invalid): {p.get('root_cause', '?')} — {error}")

    if not valid_proposals:
        print("No valid proposals after validation.")
        return

    # 3. Read existing rules
    with open(args.rules_file) as f:
        rules_text = f.read()

    existing = extract_existing_root_causes(rules_text)
    print(f"Existing taxonomy has {len(existing)} root causes.")

    # 4. Deduplicate against existing rules
    novel_proposals = [p for p in valid_proposals if p["root_cause"] not in existing]
    skipped = len(valid_proposals) - len(novel_proposals)
    if skipped > 0:
        print(f"  Skipped {skipped} proposal(s) that duplicate existing rules.")

    if not novel_proposals:
        print("No new rules to add (all proposals duplicate existing rules).")
        return

    # 5. Semantic dedup across proposals (uses Claude if 2+)
    deduped = deduplicate_with_claude(novel_proposals, existing)

    # Final check: make sure deduped entries don't match existing rules
    final_proposals = [p for p in deduped if p["root_cause"] not in existing]

    if not final_proposals:
        print("No new rules after deduplication.")
        return

    # 6. Insert into taxonomy table
    rules_text = insert_taxonomy_rows(rules_text, final_proposals)

    # 7. Insert into priority rules
    rules_text = insert_priority_rules(rules_text, final_proposals)

    # 8. Write output
    with open(args.output, "w") as f:
        f.write(rules_text)

    print(f"\nAdded {len(final_proposals)} new rule(s) to {args.output}:")
    for p in final_proposals:
        print(f"  + {p['root_cause']} ({p['category']}): {p['error_signature']}")


if __name__ == "__main__":
    main()
