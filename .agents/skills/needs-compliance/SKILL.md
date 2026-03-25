---
name: needs-compliance
description: Verify and enforce license and policy compliance across the project. Use when the proven-needs orchestrator determines that compliance needs checking or enforcement. Operates at the project level. Observes dependency licenses, policy requirements, and regulatory constraints. Identifies violations and proposes remediations.
---

## Prerequisites

This skill is invoked by the `proven-needs` orchestrator, which provides the desired state and current state context.

## Observe

Assess the current compliance posture of the project.

### 1. Dependency license analysis

For each dependency (direct and transitive):
- Identify the declared license (from package metadata)
- Classify the license type (permissive, copyleft, proprietary, unknown)

Common license classifications:

| Category | Licenses | Typical constraint |
|---|---|---|
| Permissive | MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, ISC | Generally allowed |
| Weak copyleft | LGPL-2.1, LGPL-3.0, MPL-2.0 | May have linking restrictions |
| Strong copyleft | GPL-2.0, GPL-3.0, AGPL-3.0 | Often restricted in proprietary projects |
| Proprietary | Various commercial licenses | Requires license agreement |
| Unknown | No license declared | Risk -- may not be legally usable |

### 2. Read constraints

Read `docs/constraints.yaml`. Identify licensing constraints (e.g., "Only MIT, Apache-2.0, and BSD-licensed dependencies are permitted").

### 3. Identify violations

Compare each dependency's license against the licensing constraints. Flag:
- **Direct violations** -- dependency uses a prohibited license
- **Transitive violations** -- a dependency of a dependency uses a prohibited license
- **Unknown licenses** -- no license metadata available

### 4. Report observation

Return to the orchestrator:
```
Compliance:
  total-dependencies: N (direct: N, transitive: N)
  license-distribution: {MIT: N, Apache-2.0: N, GPL-3.0: N, unknown: N, ...}
  violations: [{package, license, constraint-violated, direct/transitive}]
  unknown-licenses: [{package, reason}]
```

## Evaluate

Given the desired state from the orchestrator, determine what action is needed.

### 1. Map desired state to actions

| Desired State | Actions |
|---|---|
| "All dependencies are license-compliant" | Replace or remove violating dependencies |
| "No unknown licenses" | Research and document unknown licenses, replace if non-compliant |
| "Full compliance audit" | Comprehensive report of all licenses and their status |

### 2. Assess remediation options

For each violation:
- Is there a drop-in replacement with a compliant license?
- Can the dependency be removed entirely?
- Is a license exception warranted (requires constraint update)?

### 3. Report evaluation

Return to the orchestrator:
```
Action: remediate / audit-only / none
Violations: N
Proposed remediations: [{package, current-license, action: replace/remove/exception, replacement-package}]
Constraint updates needed: [list or none]
```

## Execute

### 1. Replace non-compliant dependencies

For each approved replacement:
1. Remove the non-compliant dependency
2. Add the compliant replacement
3. Update import/require statements in the codebase
4. Run the package manager's install command

### 2. Remove unnecessary non-compliant dependencies

For dependencies that can be removed:
1. Remove the dependency
2. Replace its usage with native/built-in alternatives or inline implementations
3. Run the package manager's install command

### 3. Document exceptions

If the user approves a license exception:
1. Record the exception in `docs/constraints.yaml` as a noted exception under the licensing section
2. Document the rationale

### 4. Verify

After all remediations:
1. Re-run license analysis to confirm violations are resolved
2. Run the build and test suite
3. Verify all licensing constraints are satisfied

### 5. Report results

Return to the orchestrator:
```
Remediations applied: [{package, action, status}]
Verification: {compliance-scan: pass/fail, build: pass/fail, tests: pass/fail}
Constraint violations resolved: [list]
Remaining violations: [list or none]
```

## Reference

See `references/example.adoc` for an example showing a compliance audit and remediation cycle.
