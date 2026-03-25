#!/usr/bin/env python3
"""
Validates ADR YAML files against:
1. JSON Schema (individual ADR files + index)
2. ID uniqueness (no duplicate ADR IDs)
3. Sequential ADR numbering (ADR-0001, ADR-0002, ...)
4. Index consistency (index entries match individual files)
5. Supersession integrity (superseded ADRs reference valid successors)
6. Filename-ID consistency (file 0001-*.yaml must contain ADR-0001)

Usage:
  python skills/needs-adr/scripts/validate-adrs.py docs/adrs/
  python skills/needs-adr/scripts/validate-adrs.py             # defaults to docs/adrs/

Dependencies:
  pip install pyyaml jsonschema

Exit codes:
  0 = all valid
  1 = validation errors found
  2 = usage error
"""

import json
import re
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
ADR_SCHEMA_PATH = SCRIPT_DIR.parent / "schemas" / "adr.schema.json"
INDEX_SCHEMA_PATH = SCRIPT_DIR.parent / "schemas" / "adr-index.schema.json"

for p in (ADR_SCHEMA_PATH, INDEX_SCHEMA_PATH):
    if not p.exists():
        print(f"Schema not found at: {p}", file=sys.stderr)
        sys.exit(2)

adr_schema = json.loads(ADR_SCHEMA_PATH.read_text())
index_schema = json.loads(INDEX_SCHEMA_PATH.read_text())
ADR_SCHEMA_VERSION = adr_schema.get("version", "0.0.0")
INDEX_SCHEMA_VERSION = index_schema.get("version", "0.0.0")


def check_schema_version(doc: dict, label: str, schema_version: str) -> list[str]:
    """Check that the artifact's schema_version is compatible with the schema."""
    artifact_ver = doc.get("schema_version", "")
    if not artifact_ver:
        return [f"{label}: missing schema_version field"]
    schema_major = schema_version.split(".")[0]
    artifact_major = artifact_ver.split(".")[0]
    if schema_major != artifact_major:
        return [
            f"{label}: schema_version {artifact_ver} is incompatible with "
            f"schema version {schema_version} (major version mismatch)"
        ]
    return []


def main():
    args = sys.argv[1:]
    adrs_dir = Path(args[0]) if args and args[0] != "--default" else Path("docs/adrs")

    if not adrs_dir.exists():
        print(f"Directory not found: {adrs_dir}", file=sys.stderr)
        sys.exit(2)

    errors = []
    adr_docs: dict[str, dict] = {}

    yaml_files = sorted(f for f in adrs_dir.iterdir() if f.suffix == ".yaml")
    index_file = next((f for f in yaml_files if f.name == "index.yaml"), None)
    adr_files = [
        f
        for f in yaml_files
        if f.name != "index.yaml" and re.match(r"^\d{4}-.+\.yaml$", f.name)
    ]

    if not adr_files:
        print(f"No ADR files found in {adrs_dir}", file=sys.stderr)
        sys.exit(2)

    for adr_file in adr_files:
        filename = adr_file.name

        try:
            doc = yaml.safe_load(adr_file.read_text())
        except yaml.YAMLError as e:
            errors.append(f"{filename}: YAML parse error: {e}")
            continue

        try:
            validate(instance=doc, schema=adr_schema)
        except ValidationError as e:
            path = "/".join(str(p) for p in e.absolute_path) or "(root)"
            errors.append(f"{filename}: schema: /{path} {e.message}")
            continue

        errors.extend(check_schema_version(doc, filename, ADR_SCHEMA_VERSION))

        file_num_match = re.match(r"^(\d{4})-", filename)
        id_num_match = re.match(r"^ADR-(\d{4})$", doc["id"])
        if file_num_match and id_num_match and file_num_match[1] != id_num_match[1]:
            errors.append(
                f"{filename}: file number {file_num_match[1]} does not match ADR ID {doc['id']}"
            )

        if doc["id"] in adr_docs:
            errors.append(
                f"{filename}: duplicate ADR ID {doc['id']} "
                f"(also in {adr_docs[doc['id']]['filename']})"
            )
        else:
            adr_docs[doc["id"]] = {"doc": doc, "filename": filename}

        print(f"PASS  {filename} ({doc['id']}: {doc['status']})")

    sorted_ids = sorted(adr_docs.keys())
    for i, adr_id in enumerate(sorted_ids):
        expected = f"ADR-{i + 1:04d}"
        if adr_id != expected:
            errors.append(f"ADR numbering gap: expected {expected} but found {adr_id}")
            break

    for adr_id, entry in adr_docs.items():
        doc = entry["doc"]
        filename = entry["filename"]

        if doc["status"] == "Superseded":
            if "superseded_by" not in doc or not doc["superseded_by"]:
                errors.append(
                    f'{filename}: status is "Superseded" but no superseded_by field'
                )
            elif doc["superseded_by"] not in adr_docs:
                errors.append(
                    f"{filename}: superseded_by references {doc['superseded_by']} which does not exist"
                )

        if doc.get("superseded_by") and doc["status"] != "Superseded":
            errors.append(
                f'{filename}: has superseded_by field but status is "{doc["status"]}" (should be "Superseded")'
            )

    if index_file:
        try:
            index_doc = yaml.safe_load(index_file.read_text())
        except yaml.YAMLError as e:
            errors.append(f"index.yaml: YAML parse error: {e}")
            index_doc = None

        if index_doc:
            try:
                validate(instance=index_doc, schema=index_schema)
            except ValidationError as e:
                path = "/".join(str(p) for p in e.absolute_path) or "(root)"
                errors.append(f"index.yaml: schema: /{path} {e.message}")
            else:
                print("PASS  index.yaml")

                errors.extend(
                    check_schema_version(index_doc, "index.yaml", INDEX_SCHEMA_VERSION)
                )

                index_ids = {d["id"] for d in index_doc["decisions"]}
                for adr_id, entry in adr_docs.items():
                    if adr_id not in index_ids:
                        errors.append(
                            f"index.yaml: missing entry for {adr_id} (file: {entry['filename']})"
                        )

                for decision in index_doc["decisions"]:
                    if decision["id"] not in adr_docs:
                        errors.append(
                            f"index.yaml: entry {decision['id']} has no corresponding ADR file"
                        )
                    else:
                        adr = adr_docs[decision["id"]]
                        if decision["title"] != adr["doc"]["title"]:
                            errors.append(
                                f"index.yaml: {decision['id']} title mismatch -- "
                                f'index: "{decision["title"]}" vs file: "{adr["doc"]["title"]}"'
                            )
                        if decision["status"] != adr["doc"]["status"]:
                            errors.append(
                                f"index.yaml: {decision['id']} status mismatch -- "
                                f'index: "{decision["status"]}" vs file: "{adr["doc"]["status"]}"'
                            )
                        if decision["file"] != adr["filename"]:
                            errors.append(
                                f"index.yaml: {decision['id']} file mismatch -- "
                                f'index: "{decision["file"]}" vs actual: "{adr["filename"]}"'
                            )
    else:
        errors.append(f"index.yaml not found in {adrs_dir}")

    total_files = len(adr_files) + (1 if index_file else 0)
    status = "All valid." if not errors else f"{len(errors)} error(s) found."
    print(f"\n{total_files} file(s) checked. {status}")

    if errors:
        print("\nErrors:")
        for err in errors:
            print(f"  - {err}")

    sys.exit(0 if not errors else 1)


if __name__ == "__main__":
    main()
