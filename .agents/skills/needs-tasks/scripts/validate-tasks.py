#!/usr/bin/env python3
"""
Validates implementation task YAML files against:
1. JSON Schema (structure and types)
2. Task ID uniqueness
3. Sequential task IDs (TASK-001, TASK-002, ... without gaps)
4. Dependency references (all depends_on targets exist)
5. No circular dependencies (DAG validation)
6. Requirement coverage (cross-reference against spec.yaml if provided)
7. Story coverage (every story referenced exists in spec.yaml if provided)

Usage:
  python skills/needs-tasks/scripts/validate-tasks.py docs/features/shopping-cart/tasks.yaml
  python skills/needs-tasks/scripts/validate-tasks.py docs/features/*/tasks.yaml
  python skills/needs-tasks/scripts/validate-tasks.py --all
  python skills/needs-tasks/scripts/validate-tasks.py docs/features/shopping-cart/tasks.yaml --spec docs/features/shopping-cart/spec.yaml

Dependencies:
  pip install pyyaml jsonschema

Exit codes:
  0 = all valid
  1 = validation errors found
  2 = usage error
"""

import json
import sys
from collections import defaultdict, deque
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
SCHEMA_PATH = SCRIPT_DIR.parent / "schemas" / "tasks.schema.json"

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


def find_task_files(args: list[str]) -> tuple[list[Path], Path | None]:
    """Returns (task_files, explicit_spec_path)."""
    spec_path = None
    filtered_args = []

    i = 0
    while i < len(args):
        if args[i] == "--spec" and i + 1 < len(args):
            spec_path = Path(args[i + 1])
            i += 2
        else:
            filtered_args.append(args[i])
            i += 1

    if "--all" in filtered_args:
        features_dir = Path("docs/features")
        if not features_dir.exists():
            print("No docs/features/ directory found.", file=sys.stderr)
            sys.exit(2)
        files = sorted(features_dir.glob("*/tasks.yaml"))
        if not files:
            print("No tasks.yaml files found under docs/features/.", file=sys.stderr)
            sys.exit(2)
        return files, spec_path

    non_flag_args = [a for a in filtered_args if not a.startswith("--")]
    if not non_flag_args:
        print(
            "Usage:\n"
            "  python skills/needs-tasks/scripts/validate-tasks.py docs/features/*/tasks.yaml\n"
            "  python skills/needs-tasks/scripts/validate-tasks.py --all\n"
            "  python skills/needs-tasks/scripts/validate-tasks.py <tasks.yaml> --spec <spec.yaml>",
            file=sys.stderr,
        )
        sys.exit(2)

    return [Path(a) for a in non_flag_args], spec_path


def load_spec_ids(
    task_file: Path, explicit_spec: Path | None
) -> tuple[set[str], set[str]] | None:
    """Try to load requirement IDs and story IDs from the feature's spec.yaml."""
    if explicit_spec:
        spec_path = explicit_spec
    else:
        spec_path = task_file.parent / "spec.yaml"

    if not spec_path.exists():
        return None

    try:
        spec = yaml.safe_load(spec_path.read_text())
    except Exception:
        return None

    req_ids = set()
    story_ids = set()
    for story in spec.get("stories", []):
        story_ids.add(story["id"])
        for req in story.get("requirements", []):
            req_ids.add(req["id"])

    return req_ids, story_ids


def detect_circular_dependencies(tasks: list[dict]) -> list[str]:
    """Detect circular dependencies using Kahn's algorithm."""
    task_ids = {task["id"] for task in tasks}
    in_degree = {task_id: 0 for task_id in task_ids}
    adjacency: dict[str, list[str]] = defaultdict(list)

    for task in tasks:
        for dep in task["depends_on"]:
            if dep not in task_ids:
                continue
            adjacency[dep].append(task["id"])
            in_degree[task["id"]] += 1

    queue = deque(
        sorted(task_id for task_id, degree in in_degree.items() if degree == 0)
    )
    processed = []

    while queue:
        current_id = queue.popleft()
        processed.append(current_id)
        for dependent_id in adjacency[current_id]:
            in_degree[dependent_id] -= 1
            if in_degree[dependent_id] == 0:
                queue.append(dependent_id)

    if len(processed) != len(tasks):
        cycle_nodes = sorted(
            task_id for task_id, degree in in_degree.items() if degree > 0
        )
        return ["Circular dependency detected involving: " + ", ".join(cycle_nodes)]

    return []


def validate_file(
    file_path: Path, explicit_spec: Path | None
) -> tuple[list[str], dict | None]:
    errors = []
    label = str(file_path)

    try:
        doc = yaml.safe_load(file_path.read_text())
    except yaml.YAMLError as e:
        errors.append(f"{label}: YAML parse error: {e}")
        return errors, None

    try:
        validate(instance=doc, schema=schema)
    except ValidationError as e:
        path = "/".join(str(p) for p in e.absolute_path) or "(root)"
        errors.append(f"{label}: schema: /{path} {e.message}")
        return errors, doc

    errors.extend(check_schema_version(doc, label))

    if not doc.get("source_design_version") and not doc.get("source_spec_version"):
        errors.append(
            f"{label}: at least one provenance field is required: "
            "source_design_version or source_spec_version"
        )

    tasks = doc["tasks"]

    task_ids = set()
    for task in tasks:
        if task["id"] in task_ids:
            errors.append(f"{label}: duplicate task ID: {task['id']}")
        task_ids.add(task["id"])

    task_nums = [int(t["id"].replace("TASK-", "")) for t in tasks]
    for i, num in enumerate(task_nums):
        if num != i + 1:
            errors.append(
                f"{label}: task ID gap or out of order: "
                f"expected TASK-{i + 1:03d} but found {tasks[i]['id']}"
            )
            break

    for i in range(1, len(task_nums)):
        if task_nums[i] <= task_nums[i - 1]:
            errors.append(
                f"{label}: task IDs not in ascending order: "
                f"{tasks[i - 1]['id']} followed by {tasks[i]['id']}"
            )
            break

    all_deps = set()
    for task in tasks:
        deps = task["depends_on"]
        for dep in deps:
            all_deps.add(dep)

    unknown_deps = all_deps - task_ids
    for dep in unknown_deps:
        errors.append(f"{label}: depends_on references unknown task: {dep}")

    errors.extend(detect_circular_dependencies(tasks))

    root_tasks = [t for t in tasks if not t["depends_on"]]
    if not root_tasks and tasks:
        errors.append(f"{label}: no root tasks found (every task has dependencies)")

    if doc["status"] == "Implemented":
        not_done = [t["id"] for t in tasks if not t.get("done", False)]
        if not_done:
            errors.append(
                f"{label}: status is 'Implemented' but {len(not_done)} task(s) "
                f"not marked done: {', '.join(not_done)}"
            )

    spec_data = load_spec_ids(file_path, explicit_spec)
    if spec_data:
        spec_req_ids, spec_story_ids = spec_data

        task_req_ids = set()
        for task in tasks:
            task_req_ids.update(task.get("requirements", []))

        unknown_reqs = task_req_ids - spec_req_ids
        if unknown_reqs:
            errors.append(
                f"{label}: tasks reference requirement IDs not in spec.yaml: "
                f"{', '.join(sorted(unknown_reqs))}"
            )

        uncovered_reqs = spec_req_ids - task_req_ids
        if uncovered_reqs:
            errors.append(
                f"{label}: spec.yaml requirements not covered by any task: "
                f"{', '.join(sorted(uncovered_reqs))}"
            )

        task_story_ids = set()
        for task in tasks:
            task_story_ids.update(task.get("stories", []))

        unknown_stories = task_story_ids - spec_story_ids
        if unknown_stories:
            errors.append(
                f"{label}: tasks reference story IDs not in spec.yaml: "
                f"{', '.join(sorted(unknown_stories))}"
            )

    return errors, doc


def main():
    args = sys.argv[1:]
    files, explicit_spec = find_task_files(args)

    total_errors = 0

    for file_path in files:
        if not file_path.exists():
            print(f"File not found: {file_path}", file=sys.stderr)
            total_errors += 1
            continue

        errors, doc = validate_file(file_path, explicit_spec)

        if not errors:
            task_count = len(doc["tasks"])
            done_count = sum(1 for t in doc["tasks"] if t.get("done", False))
            print(f"PASS  {file_path} ({done_count}/{task_count} done)")
        else:
            print(f"FAIL  {file_path}")
            for err in errors:
                print(f"  - {err}")
            total_errors += len(errors)

    status = "All valid." if total_errors == 0 else f"{total_errors} error(s) found."
    print(f"\n{len(files)} file(s) checked. {status}")
    sys.exit(0 if total_errors == 0 else 1)


if __name__ == "__main__":
    main()
