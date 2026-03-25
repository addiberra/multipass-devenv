#!/usr/bin/env python3
"""
Render YAML artifacts as human-readable AsciiDoc or Markdown documents.

Auto-detects artifact type from YAML content and applies the appropriate
Jinja2 template. Supports feature specs, tasks, constraints, ADRs, and
ADR indexes.

Usage:
  python skills/proven-needs/scripts/render.py <file.yaml>
  python skills/proven-needs/scripts/render.py <file.yaml> --format md
  python skills/proven-needs/scripts/render.py <file.yaml> --format adoc
  python skills/proven-needs/scripts/render.py <file.yaml> -o output.md
  python skills/proven-needs/scripts/render.py docs/adrs/              # renders all ADRs + index

Artifact type detection:
  - Has "stories" key           -> feature spec
  - Has "tasks" + "overview"    -> tasks
  - Has "categories" key        -> constraints
  - Has "decisions" key         -> ADR index
  - Has "context" + "decision"  -> individual ADR

Output:
  Prints to stdout by default. Use -o to write to a file.

Dependencies:
  pip install pyyaml jinja2
"""

import argparse
import sys
from pathlib import Path

try:
    import yaml
    from jinja2 import Environment, FileSystemLoader, TemplateNotFound
except ImportError:
    print(
        "Missing dependencies. Install them with:\n  pip install pyyaml jinja2",
        file=sys.stderr,
    )
    sys.exit(2)

SCRIPT_DIR = Path(__file__).resolve().parent
TEMPLATES_DIR = SCRIPT_DIR / "templates"


def detect_type(doc: dict) -> str:
    """Detect artifact type from YAML content."""
    if "stories" in doc:
        return "spec"
    if "tasks" in doc and "overview" in doc:
        return "tasks"
    if "categories" in doc:
        return "constraints"
    if "decisions" in doc:
        return "adr-index"
    if "context" in doc and "decision" in doc:
        return "adr"
    return "unknown"


def render_file(file_path: Path, fmt: str, env: Environment) -> str:
    """Render a single YAML file to the specified format."""
    try:
        doc = yaml.safe_load(file_path.read_text())
    except yaml.YAMLError as e:
        print(f"YAML parse error in {file_path}: {e}", file=sys.stderr)
        sys.exit(1)

    artifact_type = detect_type(doc)
    if artifact_type == "unknown":
        print(
            f"Cannot detect artifact type for {file_path}. "
            f"Expected one of: spec, tasks, constraints, adr, adr-index.",
            file=sys.stderr,
        )
        sys.exit(1)

    template_name = f"{artifact_type}.{fmt}.j2"
    try:
        template = env.get_template(template_name)
    except TemplateNotFound:
        print(
            f"Template not found: {template_name} (in {TEMPLATES_DIR})",
            file=sys.stderr,
        )
        sys.exit(2)

    return template.render(doc=doc, file_path=str(file_path))


def render_directory(dir_path: Path, fmt: str, env: Environment) -> str:
    """Render all YAML files in a directory (for ADR directories)."""
    yaml_files = sorted(f for f in dir_path.iterdir() if f.suffix == ".yaml")
    if not yaml_files:
        print(f"No YAML files found in {dir_path}", file=sys.stderr)
        sys.exit(1)

    parts = []
    for f in yaml_files:
        parts.append(render_file(f, fmt, env))

    return "\n\n---\n\n".join(parts) if fmt == "md" else "\n\n''''\n\n".join(parts)


def main():
    parser = argparse.ArgumentParser(
        description="Render YAML artifacts as AsciiDoc or Markdown.",
    )
    parser.add_argument(
        "input",
        type=Path,
        help="YAML file or directory (for ADRs) to render.",
    )
    parser.add_argument(
        "--format",
        "-f",
        choices=["adoc", "md"],
        default="md",
        help="Output format (default: md).",
    )
    parser.add_argument(
        "--output",
        "-o",
        type=Path,
        default=None,
        help="Output file (default: stdout).",
    )
    args = parser.parse_args()

    env = Environment(
        loader=FileSystemLoader(str(TEMPLATES_DIR)),
        keep_trailing_newline=True,
        trim_blocks=True,
        lstrip_blocks=True,
    )

    if args.input.is_dir():
        result = render_directory(args.input, args.format, env)
    elif args.input.exists():
        result = render_file(args.input, args.format, env)
    else:
        print(f"Not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    if args.output:
        args.output.write_text(result)
        print(f"Written to {args.output}")
    else:
        print(result)


if __name__ == "__main__":
    main()
