#!/usr/bin/env python3
"""
Validates feature specification YAML files against:
1. JSON Schema (structure and types)
2. ID uniqueness (no duplicate story IDs or requirement IDs within a feature)
3. Prefix consistency (all requirement IDs use the declared prefix)
4. Sequential numbering (IDs are sequential without gaps)
5. Cross-feature uniqueness (no two features share the same prefix)
6. EARS pattern compliance (requirement text matches declared type)

Usage:
  python skills/needs-features/scripts/validate-specs.py docs/features/*/spec.yaml
  python skills/needs-features/scripts/validate-specs.py docs/features/shopping-cart/spec.yaml
  python skills/needs-features/scripts/validate-specs.py --all

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
SCHEMA_PATH = SCRIPT_DIR.parent / "schemas" / "feature-spec.schema.json"

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


def find_spec_files(args: list[str]) -> list[Path]:
    if "--all" in args:
        features_dir = Path("docs/features")
        if not features_dir.exists():
            print("No docs/features/ directory found.", file=sys.stderr)
            sys.exit(2)
        files = sorted(features_dir.glob("*/spec.yaml"))
        if not files:
            print("No spec.yaml files found under docs/features/.", file=sys.stderr)
            sys.exit(2)
        return files

    if not args:
        print(
            "Usage:\n"
            "  python skills/needs-features/scripts/validate-specs.py docs/features/*/spec.yaml\n"
            "  python skills/needs-features/scripts/validate-specs.py --all",
            file=sys.stderr,
        )
        sys.exit(2)

    return [Path(a) for a in args]


def validate_file(file_path: Path) -> tuple[list[str], dict | None]:
    errors = []
    label = str(file_path)

    # Parse YAML
    try:
        doc = yaml.safe_load(file_path.read_text())
    except yaml.YAMLError as e:
        errors.append(f"{label}: YAML parse error: {e}")
        return errors, None

    # JSON Schema validation
    try:
        validate(instance=doc, schema=schema)
    except ValidationError as e:
        path = "/".join(str(p) for p in e.absolute_path) or "(root)"
        errors.append(f"{label}: schema: /{path} {e.message}")
        return errors, doc

    # Schema version compatibility
    errors.extend(check_schema_version(doc, label))

    feature = doc["feature"]
    prefix = doc["prefix"]
    stories = doc["stories"]

    # Story ID uniqueness
    story_ids = set()
    for story in stories:
        if story["id"] in story_ids:
            errors.append(f"{label}: duplicate story ID: {story['id']}")
        story_ids.add(story["id"])

    # Requirement ID uniqueness and prefix consistency
    req_ids = set()
    for story in stories:
        for req in story["requirements"]:
            req_prefix = req["id"].split("-")[0]
            if req_prefix != prefix:
                errors.append(
                    f'{label}: requirement {req["id"]} uses prefix "{req_prefix}" '
                    f'but feature declares prefix "{prefix}"'
                )
            if req["id"] in req_ids:
                errors.append(f"{label}: duplicate requirement ID: {req['id']}")
            req_ids.add(req["id"])

    # Sequential story IDs
    story_nums = [int(s["id"].replace("US-", "")) for s in stories]
    for i, num in enumerate(story_nums):
        if num != i + 1:
            errors.append(
                f"{label}: story ID gap or out of order: "
                f"expected US-{i + 1:03d} but found {stories[i]['id']}"
            )

    # Sequential requirement IDs (across the whole feature)
    all_reqs = []
    for story in stories:
        for req in story["requirements"]:
            num = int(req["id"].split("-")[1])
            all_reqs.append((req["id"], num))

    for i in range(1, len(all_reqs)):
        if all_reqs[i][1] <= all_reqs[i - 1][1]:
            errors.append(
                f"{label}: requirement IDs not in ascending order: "
                f"{all_reqs[i - 1][0]} followed by {all_reqs[i][0]}"
            )

    if all_reqs:
        for i, (req_id, num) in enumerate(all_reqs):
            if num != i + 1:
                errors.append(
                    f"{label}: requirement ID gap: "
                    f"expected {prefix}-{i + 1:03d} but found {req_id}"
                )
                break

    # EARS type consistency
    ears_checks = {
        "ubiquitous": (
            r"^The\s",
            'start with "The ...". Pattern: "The <system> shall <response>."',
        ),
        "event-driven": (
            r"^When\s",
            'start with "When ...". Pattern: "When <trigger>, the <system> shall <response>."',
        ),
        "state-driven": (
            r"^(While|During)\s",
            'start with "While ..." or "During ...". Pattern: "While <state>, the <system> shall <response>."',
        ),
        "unwanted-behavior": (
            r"^If\s",
            'start with "If ...". Pattern: "If <condition>, then the <system> shall <response>."',
        ),
        "optional-feature": (
            r"^Where\s",
            'start with "Where ...". Pattern: "Where <feature>, the <system> shall <response>."',
        ),
    }

    for story in stories:
        for req in story["requirements"]:
            text = req["text"].strip()
            ears_type = req["ears_type"]

            if ears_type in ears_checks:
                pattern, msg = ears_checks[ears_type]
                if not re.match(pattern, text, re.IGNORECASE):
                    errors.append(
                        f'{label}: {req["id"]}: ears_type is "{ears_type}" '
                        f"but text does not {msg}"
                    )
            elif ears_type == "complex":
                keywords = [
                    kw
                    for kw in ("Where", "While", "When", "If")
                    if re.search(rf"\b{kw}\b", text, re.IGNORECASE)
                ]
                if len(keywords) < 2:
                    errors.append(
                        f'{label}: {req["id"]}: ears_type is "complex" but text '
                        f"contains fewer than 2 EARS keywords (Where/While/When/If)."
                    )

            if not re.search(r"\bshall\b", text, re.IGNORECASE):
                errors.append(
                    f'{label}: {req["id"]}: requirement text does not contain "shall".'
                )

    return errors, doc


def validate_cross_file(parsed_docs: list[tuple[Path, dict]]) -> list[str]:
    errors = []
    prefixes: dict[str, str] = {}

    for file_path, doc in parsed_docs:
        if doc is None:
            continue
        prefix = doc["prefix"]
        feature = doc["feature"]
        if prefix in prefixes:
            errors.append(
                f'Cross-file: prefix "{prefix}" is used by both '
                f'"{feature}" ({file_path}) and {prefixes[prefix]}'
            )
        else:
            prefixes[prefix] = f"{feature} ({file_path})"

    return errors


def main():
    args = sys.argv[1:]
    files = find_spec_files(args)

    total_errors = 0
    parsed_docs = []

    for file_path in files:
        if not file_path.exists():
            print(f"File not found: {file_path}", file=sys.stderr)
            total_errors += 1
            continue

        errors, doc = validate_file(file_path)

        if not errors:
            print(f"PASS  {file_path}")
            parsed_docs.append((file_path, doc))
        else:
            print(f"FAIL  {file_path}")
            for err in errors:
                print(f"  - {err}")
            total_errors += len(errors)
            parsed_docs.append((file_path, doc))

    if len(parsed_docs) > 1:
        cross_errors = validate_cross_file(parsed_docs)
        if cross_errors:
            print("\nCross-file issues:")
            for err in cross_errors:
                print(f"  - {err}")
            total_errors += len(cross_errors)

    status = "All valid." if total_errors == 0 else f"{total_errors} error(s) found."
    print(f"\n{len(files)} file(s) checked. {status}")
    sys.exit(0 if total_errors == 0 else 1)


if __name__ == "__main__":
    main()
