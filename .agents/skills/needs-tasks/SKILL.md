---
name: needs-tasks
description: Create task graphs for a feature in schema-validated YAML format. Use when the proven-needs orchestrator determines that a feature needs a task breakdown. Operates within a single feature package at docs/features/<slug>/. Tasks form a DAG where each node has explicit depends_on edges to its prerequisites. Full traceability back to the feature's spec.yaml requirements.
---

## Prerequisites

This skill is invoked by the `proven-needs` orchestrator, which provides the feature context (slug, intent, current state).

## Artifact Format

The task list is a single YAML file at `docs/features/<slug>/tasks.yaml`, validated by a JSON schema.

**Schema:** `skills/needs-tasks/schemas/tasks.schema.json`

**Validation:** `python skills/needs-tasks/scripts/validate-tasks.py docs/features/<slug>/tasks.yaml`

The validation script also cross-references against the feature's `spec.yaml` to verify that every requirement is covered by at least one task and that all referenced IDs exist.

## Observe

Assess the current state of the task list for this feature.

### 1. Read feature design

Read `docs/features/<slug>/design.adoc`. Extract `:version:`, `:source-spec-version:`, `:status:`, system design sections, requirement resolution mappings. Also read `data-model.adoc` and `contracts/` if they exist within the feature package.

**If missing:** Note that design is unavailable. Report to the orchestrator. Tasks will be derived directly from spec.yaml requirements (requirement-driven derivation). In that case, omit `source_design_version` and record spec provenance only.

### 2. Read feature spec

Read `docs/features/<slug>/spec.yaml`. Extract:
- All story IDs and titles
- All requirement IDs, EARS texts, and verifications

### 3. Read existing task list

If `docs/features/<slug>/tasks.yaml` exists:
- Read `version`, `status`, and any recorded provenance fields (`source_design_version`, `source_spec_version`)
- Read all tasks, done states, and dependency structure
- Perform topological analysis to identify root tasks and execution order

### 4. Read constraints

Read `docs/constraints.yaml`. Identify quality constraints relevant to task planning.

### 5. Analyze codebase

If this is not a greenfield project, analyze what already exists to avoid creating tasks for things already implemented.

### 6. Report observation

Return to the orchestrator:
```
Feature: <slug>
Design: {exists: true/false, version: "X.Y.Z", status: "Current/Stale"}
Spec: {exists: true, version: "X.Y.Z", stories: N, requirements: N}
Tasks: {exists: true/false, version: "X.Y.Z", status: "Current/Stale/Implemented", progress: "N/M done", root_tasks: N}
```

## Evaluate

Given the desired state from the orchestrator, determine what action is needed.

### 1. Does the desired state require task changes?

| Condition | Action |
|---|---|
| No task list exists | Create task list |
| Task list exists, `status` is `Implemented` | Previous cycle complete. Create fresh task list (overwrite). |
| Recorded source versions match, no tasks done | Task list appears current. Report to orchestrator. |
| Recorded source versions match, some tasks done | Partial progress. Report to orchestrator. |
| Any recorded source version differs from its upstream artifact | Task list is stale. Determine whether to recreate or incrementally update. |
| No provenance fields are present | Task list is invalid. Regenerate it before proceeding. |

### 2. Transitive staleness check

Evaluate staleness only against the provenance fields that are actually present:

- If `source_design_version` exists, compare it to the current design version.
- If `source_spec_version` exists, compare it to the current spec version.
- If both exist, either mismatch makes the task list stale.
- If neither exists, the task file is invalid, not merely stale.

If tasks are design-driven and design provenance is stale, recommend updating the design first so upstream spec changes flow through the design before tasks are regenerated.

### 3. Check constraints

Verify that task organization respects quality constraints (e.g., test coverage must not decrease -- ensure testing tasks exist if the project uses TDD).

### 4. Report evaluation

Return to the orchestrator:
```
Action: create / update / none
Staleness: {design: true/false, transitive: true/false}
Constraint issues: [list or none]
```

## Execute

### Design-driven task decomposition (default)

When a design document exists, walk through it systematically to identify discrete implementation units. Each task should be a single coding unit -- small enough to implement in one sitting.

**Sources of tasks:**

| Design Section | Task Types |
|---|---|
| Data model entities | Entity/model creation, migrations, validation rules |
| System design components | Module/service setup, core logic implementation |
| Interface contracts / API endpoints | Endpoint implementation, request/response handling |
| Frontend components | Component creation, state management wiring |
| External integrations | Service client setup, integration logic |
| Requirement resolution -- error cases | Error handling, edge cases |
| Requirement resolution -- notifications | Notification/email implementation |

**For each task, record:**
- A clear, actionable title
- Which design components are involved
- Which requirement IDs it satisfies
- Which stories it contributes to
- Explicit dependencies via `depends_on` (task IDs that must complete first)

### Requirement-driven task derivation (when no design exists)

When design is absent, derive tasks directly from spec.yaml requirements:

1. Read each story and its requirements
2. For each story, create one or more tasks. Group related requirements into a single task when tightly coupled; split when independently implementable.
3. For each task, record:
   - A clear, actionable title
   - Which stories it implements
   - Which requirement IDs it satisfies
   - `components` is omitted since there is no design to reference
4. Use story groupings and requirement dependencies to inform task dependency structure

### Build the task DAG

Tasks form a Directed Acyclic Graph (DAG). For each task:

1. Identify which other tasks must complete before it can start
2. Record these as `depends_on: [TASK-ID, ...]`
3. Tasks with no dependencies are root tasks -- they can start immediately

**Guidelines:**
- A task depends on another when it needs the other's output (code, data model, API contract)
- A task belongs at the node where all its dependencies are satisfied
- Prefer granular dependencies over coarse ones (allows maximum parallelism)
- Ensure the graph has at least one root task (no dependencies)
- Verify no circular dependencies exist

**Typical dependency patterns:**
- Entity/model creation -> tasks that use the entity
- Service implementation -> tasks for API endpoints that call the service
- Frontend state management -> tasks for UI components that use the state

### Write task list

Create `docs/features/<slug>/tasks.yaml`:

```yaml
# yaml-language-server: $schema=../../../skills/needs-tasks/schemas/tasks.schema.json

schema_version: "3.0.0"
feature: <slug>
version: "1.0.0"
status: Current
source_design_version: "<design version>"        # include when design informed the task graph
source_spec_version: "<spec.yaml version>"       # include when spec informed the task graph
last_updated: "YYYY-MM-DD"

overview: >-
  <Brief summary: what is being implemented, total tasks, dependency structure.>

tasks:
  - id: TASK-001
    title: <Task title>
    depends_on: []
    components: [<design components involved>]
    stories: [US-001]
    requirements: [PREFIX-001, PREFIX-002]
    description: >-
      <What to implement and key details>

  - id: TASK-002
    title: <Task title>
    depends_on: [TASK-001]
    components: [<design components involved>]
    stories: [US-001]
    requirements: [PREFIX-003]
    description: >-
      <What to implement and key details>
```

When tasks are derived without design, omit `source_design_version` and `components`:

```yaml
schema_version: "3.0.0"
feature: <slug>
version: "1.0.0"
status: Current
source_spec_version: "<spec.yaml version>"
last_updated: "YYYY-MM-DD"

overview: >-
  <Brief summary: what is being implemented, total tasks, dependency structure.>

tasks:
  - id: TASK-001
    title: <Task title>
    depends_on: []
    stories: [US-001]
    requirements: [PREFIX-001, PREFIX-002]
    description: >-
      <What to implement and key details>

  - id: TASK-002
    title: <Task title>
    depends_on: [TASK-001]
    stories: [US-001]
    requirements: [PREFIX-003]
    description: >-
      <What to implement and key details>
```

**`status` values:**
- `Current` -- task list is valid and aligned with design
- `Stale` -- design has changed since this task list was created
- `Implemented` -- all tasks are done

**Version rules:**
- `schema_version` must match the tasks schema major version and is now `3.0.0`
- `version` uses SemVer, starts at `1.0.0`
- `source_design_version` is present only when design informed task creation or updates
- `source_spec_version` is present only when spec informed task creation or updates
- At least one provenance field (`source_design_version` or `source_spec_version`) must be present
- `last_updated` set to today's date

**Task IDs:** Sequential across the entire file: TASK-001, TASK-002, etc. IDs are stable -- do not renumber when updating.

**Marking tasks done:** When a task is completed, set `done: true`. When all tasks are done, set `status: Implemented`.

**Task file lifecycle:** Tasks guide implementation but are not the source of truth for feature completion -- passing tests (if TDD is adopted) or manual verification against spec.yaml requirements serve that role. Once a feature reaches `Implemented`, the task file may be removed at the team's discretion.

### Validate

Run the validation script to verify the task list:

```
python skills/needs-tasks/scripts/validate-tasks.py docs/features/<slug>/tasks.yaml
```

Fix any errors before reporting completion.

## Quality Checklist

Before finalizing, verify:
- Every requirement ID from spec.yaml appears in at least one task
- Every story is covered by the aggregate tasks
- Every design section has corresponding tasks (check only when `source_design_version` is present)
- The graph has at least one root task (no dependencies)
- No circular dependencies exist
- All `depends_on` references point to valid task IDs
- Each task is a discrete, implementable coding unit
- Dependency structure reflects actual implementation order
- At least one provenance field is recorded and all recorded source versions are correct
- Quality constraints from `docs/constraints.yaml` are addressed (e.g., testing tasks exist if the project uses TDD per ADR decision)
- The validation script passes: `python skills/needs-tasks/scripts/validate-tasks.py docs/features/<slug>/tasks.yaml`

## Reference

See `references/example.yaml` for a complete example showing how a feature design becomes a task graph with traceability.
