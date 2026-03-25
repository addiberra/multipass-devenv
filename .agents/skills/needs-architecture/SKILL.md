---
name: needs-architecture
description: Create and maintain the system architecture document. Use when the proven-needs orchestrator determines the architecture document needs creating or updating. Operates at the project level, producing docs/architecture.adoc as a living document reflecting the current system state. Supports greenfield projects (from feature designs), existing projects (from codebase analysis), and updates after feature implementations.
---

## Prerequisites

This skill is invoked by the `proven-needs` orchestrator, which provides the current state context.

## Observe

Assess the current state of architecture documentation.

### 1. Check for existing architecture document

If `docs/architecture.adoc` exists:
- Read `:version:`, `:last-updated:`
- Read the Feature Design Sources section to determine which feature design versions the architecture was synthesized from
- Read the full content

### 2. Check for feature designs

List all feature packages in `docs/features/`. For each, check if `design.adoc` exists and read its `:version:` and `:status:`.

### 3. Read project-wide artifacts

- **`docs/adrs/`** -- read all ADRs with status `Accepted`
- **`docs/constraints.yaml`** -- read architecture constraints

### 4. Analyze codebase

Check for source files beyond documentation and configuration. Understand:
- Directory structure, module organization
- Configuration files (package.json, Cargo.toml, go.mod, etc.)
- Entry points, key patterns

### 5. Report observation

Return to the orchestrator:
```
Architecture: {exists: true/false, version: "X.Y.Z", source-design-version: "X.Y.Z"}
Feature designs: [{slug: "...", version: "X.Y.Z", status: "..."}]
Codebase: {exists: true/false, language: "...", framework: "..."}
ADRs: {count: N, accepted: N}
Mode: greenfield / reverse-engineer / update
```

## Evaluate

Given the desired state from the orchestrator, determine what action is needed.

### 1. Determine mode

| Existing architecture? | Codebase exists? | Mode |
|---|---|---|
| No | No | **Greenfield** -- generate from feature designs |
| No | Yes | **Reverse-engineer** -- analyze codebase, use designs if available |
| Yes | Any | **Update** -- refresh the existing architecture document |

### 2. Check preconditions

**Greenfield mode:** At least one feature design must exist. If not, report to orchestrator that designs are needed first.

**Update mode:** Compare each feature's current design version against the version recorded in the architecture document's Feature Design Sources section. If any designs have been updated or new features implemented since the last architecture update, note what has changed.

### 3. Check constraints

Verify that the architecture description will address all architecture constraints from `docs/constraints.yaml`.

### 4. Report evaluation

Return to the orchestrator:
```
Action: create / update / none
Mode: greenfield / reverse-engineer / update
Changes since last update: [list of feature designs that changed]
Constraint issues: [list or none]
```

## Execute

### Generate or update the architecture document

Write `docs/architecture.adoc` using the C4 model for structural diagrams. The document combines C4 diagrams (via Mermaid) with prose sections for context that diagrams alone cannot convey.

```asciidoc
= System Architecture
:version: 1.0.0
:last-updated: YYYY-MM-DD
:toc:

== Feature Design Sources

[cols="1,1", options="header"]
|===
| Feature | Design Version

| product-browsing | 1.0.0
| shopping-cart | 1.0.0
| checkout | 1.0.0
|===

== Overview

<High-level description of the system, its purpose, and boundaries.>

== System Context (C4 Level 1)

<Who uses the system and what external systems does it interact with.>

[source,mermaid]
----
C4Context
  title System Context Diagram

  Person(user, "User", "Description of the user role")
  System(system, "System Name", "Brief description of the system")
  System_Ext(ext, "External System", "Brief description")

  Rel(user, system, "Uses")
  Rel(system, ext, "Integrates with")
----

== Container View (C4 Level 2)

<Major runtime containers: applications, databases, message queues, file stores.
 Show how containers communicate.>

[source,mermaid]
----
C4Container
  title Container Diagram

  Person(user, "User", "Description")

  System_Boundary(system, "System Name") {
    Container(app, "Application", "Technology", "Description")
    ContainerDb(db, "Database", "Technology", "Description")
  }

  System_Ext(ext, "External System", "Description")

  Rel(user, app, "Uses", "HTTPS")
  Rel(app, db, "Reads/writes", "SQL")
  Rel(app, ext, "Calls", "HTTPS/JSON")
----

== Component View (C4 Level 3)

<Internal structure of containers with significant complexity.
 Show major modules, services, or layers within a container.
 Include this section only when a container has meaningful internal structure.>

[source,mermaid]
----
C4Component
  title Component Diagram - <Container Name>

  Container_Boundary(container, "Container Name") {
    Component(comp1, "Component", "Technology", "Description")
    Component(comp2, "Component", "Technology", "Description")
  }

  ContainerDb(db, "Database", "Technology", "Description")

  Rel(comp1, comp2, "Uses")
  Rel(comp2, db, "Reads/writes")
----

== Deployment View (C4 Level 4)

<How containers are deployed to infrastructure.
 Include only for non-trivial deployment topologies.>

[source,mermaid]
----
C4Deployment
  title Deployment Diagram

  Deployment_Node(cloud, "Cloud Provider", "Description") {
    Deployment_Node(runtime, "Runtime", "Description") {
      Container(app, "Application", "Technology", "Description")
    }
    Deployment_Node(data, "Data Tier", "Description") {
      ContainerDb(db, "Database", "Technology", "Description")
    }
  }
----

== Technology Stack

<Languages, frameworks, databases, infrastructure.
 Reference relevant ADRs for rationale.>

* ADR-0001: TypeScript (backend and frontend) -- see docs/adrs/0001-use-typescript.yaml
* ADR-0002: PostgreSQL (persistence) -- see docs/adrs/0002-use-postgresql.yaml

== Data Architecture

<Data stores, schemas, data flow between components.>

== Cross-Cutting Concerns

<Authentication, logging, error handling, monitoring, etc.
 Skip sections that do not apply.>
```

### C4 level inclusion

The C4 levels included in the architecture document are adaptive based on project complexity. The orchestrator determines the appropriate levels during invocation.

| Project Type | C4 Levels | Rationale |
|---|---|---|
| Libraries, SDKs | L1 + L2 only | No deployment; containers are the library and its consumers |
| CLI tools | L1 + L2 only | Simple runtime; L2 shows the CLI and its data stores |
| Web applications (monolith) | L1 + L2 + L3 (backend) | Backend container benefits from component breakdown |
| Web applications (frontend + API) | L1 + L2 + L3 (API) | API container has meaningful internal structure |
| Microservices / distributed | L1 + L2 + L3 + L4 | Multiple containers with complex deployment topology |
| Mobile apps | L1 + L2 + L3 (app) | App container has layers (UI, state, data, platform) |

Remove C4 level sections that are not applicable rather than leaving them with placeholder content.

### Section guidance

The sections above are a default starting point. Adapt based on the project:

- **Libraries/SDKs:** Replace "Data Architecture" with "Data Flow". Omit Deployment View and Cross-Cutting Concerns if trivial.
- **CLI tools:** "Cross-Cutting Concerns" may include "Error Output" and "Exit Codes". Omit Deployment View.
- **Microservices:** Add "Service Communication" and "Service Discovery" under Cross-Cutting Concerns.
- **Simple projects:** Merge or remove sections that add no value.

Remove sections that do not apply rather than leaving them empty.

**Feature integration:** When multiple feature designs exist, the architecture document synthesizes them into a cohesive system view. It shows how features relate at the system level without duplicating feature-specific design details.

**Version rules:**
- `:version:` uses SemVer, starts at `1.0.0`
- The Feature Design Sources table records which feature design versions the architecture was synthesized from. When updating, update the table to reflect the current design versions.
- MAJOR bump: components removed or fundamentally restructured
- MINOR bump: components added or modified
- PATCH bump: clarifications, formatting, metadata updates
- Always update `:last-updated:` to today's date

## Quality Checklist

Before finalizing, verify:
- C4 System Context diagram accurately shows all users and external systems
- C4 Container diagram includes all major runtime containers and their communication
- C4 Component diagrams (if included) match the actual module/service structure
- C4 Deployment diagram (if included) reflects the real infrastructure topology
- All ADR technology decisions are reflected in Technology Stack
- Component descriptions match the actual codebase (if one exists)
- No empty sections remain (remove instead)
- Data architecture covers all persistent data stores
- Architecture constraints from `docs/constraints.yaml` are addressed
- Feature Design Sources table lists all feature designs and their current versions
- Version and date are updated

## Reference

See `references/example.adoc` for a complete example showing an architecture document for the e-commerce system.
