#!/usr/bin/env python3
"""
Validates project constraints YAML file against:
1. JSON Schema (structure and types)
2. Constraint ID uniqueness (no duplicates across categories)
3. Sequential constraint IDs (C-001, C-002, ... without gaps)
4. Category name uniqueness

Usage:
  python skills/proven-needs/scripts/validate-constraints.py docs/constraints.yaml
  python skills/proven-needs/scripts/validate-constraints.py   # defaults to docs/constraints.yaml

Dependencies:
  pip install pyyaml jsonschema

Exit codes:
  0 = valid
  1 = validation errors found
  2 = usage error
"""

import json
import sys
from pathlib import Path

try:
    import yaml
    from jsonschema import validate, ValidationError
except ImportError:
    print(
        "Missing dependencies. Install them with:\n  pip install pyyaml jsonschema",
        file=sys.stderr,
    )
    sys.exit(2)

SCRIPT_DIR = Path(__file__).resolve().parent
SCHEMA_PATH = SCRIPT_DIR.parent / "schemas" / "constraints.schema.json"

if not SCHEMA_PATH.exists():
    print(f"Schema not found at: {SCHEMA_PATH}", file=sys.stderr)
    sys.exit(2)

schema = json.loads(SCHEMA_PATH.read_text())
SCHEMA_VERSION = schema.get("version", "0.0.0")


def check_schema_version(doc: dict, label: str) -> list[str]:
    """Check that the artifact's schema_version is compatible with the schema."""
    artifact_ver = doc.get("schema_version", "")
    if not artifact_ver:
        return [f"{label}: missing schema_version field"]
    schema_major = SCHEMA_VERSION.split(".")[0]
    artifact_major = artifact_ver.split(".")[0]
    if schema_major != artifact_major:
        return [
            f"{label}: schema_version {artifact_ver} is incompatible with "
            f"schema version {SCHEMA_VERSION} (major version mismatch)"
        ]
    return []


def main():
    args = sys.argv[1:]
    file_path = (
        Path(args[0])
        if args and args[0] != "--default"
        else Path("docs/constraints.yaml")
    )

    if not file_path.exists():
        print(f"File not found: {file_path}", file=sys.stderr)
        sys.exit(2)

    errors = []

    try:
        doc = yaml.safe_load(file_path.read_text())
    except yaml.YAMLError as e:
        print(f"YAML parse error: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        validate(instance=doc, schema=schema)
    except ValidationError as e:
        path = "/".join(str(p) for p in e.absolute_path) or "(root)"
        errors.append(f"schema: /{path} {e.message}")
        print(f"FAIL  {file_path}")
        for err in errors:
            print(f"  - {err}")
        print(f"\n{len(errors)} error(s) found.")
        sys.exit(1)

    errors.extend(check_schema_version(doc, str(file_path)))

    category_names = set()
    for cat in doc["categories"]:
        if cat["name"] in category_names:
            errors.append(f'duplicate category name: "{cat["name"]}"')
        category_names.add(cat["name"])

    all_ids = []
    for cat in doc["categories"]:
        for c in cat["constraints"]:
            all_ids.append({"id": c["id"], "category": cat["name"]})

    id_set = set()
    for entry in all_ids:
        if entry["id"] in id_set:
            errors.append(
                f'duplicate constraint ID: {entry["id"]} (in category "{entry["category"]}")'
            )
        id_set.add(entry["id"])

    nums = [int(e["id"].replace("C-", "")) for e in all_ids]
    for i, num in enumerate(nums):
        if num != i + 1:
            errors.append(
                f"constraint ID gap or out of order: "
                f"expected C-{i + 1:03d} but found {all_ids[i]['id']}"
            )
            break

    if not errors:
        print(f"PASS  {file_path}")
        print(
            f"  {len(all_ids)} constraint(s) across {len(doc['categories'])} categories."
        )
    else:
        print(f"FAIL  {file_path}")
        for err in errors:
            print(f"  - {err}")

    status = "Valid." if not errors else f"{len(errors)} error(s) found."
    print(f"\n{status}")
    sys.exit(0 if not errors else 1)


if __name__ == "__main__":
    main()
