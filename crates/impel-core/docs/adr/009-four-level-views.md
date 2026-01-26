# ADR-009: Four-Level View Hierarchy

## Status
Accepted

## Context
Research coordination happens at multiple scales:
- Program level (multi-project oversight)
- Project level (collection of related threads)
- Thread level (individual work units)
- Event level (atomic activities)

The TUI needs to present information at appropriate detail for each scale.

## Decision
Implement a **four-level zoom hierarchy** in the Flight Director Console:

| Level | Key | View | Focus |
|-------|-----|------|-------|
| 1 | `1` | Program | Multi-project overview, global alerts |
| 2 | `2` | Project | Single project's threads, deliverables |
| 3 | `3` | Thread | Thread detail, events, dependencies |
| 4 | `4` | Event | Atomic activity detail |

### Level 1: Program View
```
┌─────────────────────────────────────────────────────────────┐
│ IMPEL  Program: Research 2024                12 projects    │
├───────────────┬─────────────────────────────────────────────┤
│ ALERTS        │         PROJECT GRAPH                       │
│ BY STATUS     │   ┌──────┐      ┌──────┐                   │
│ SUBMISSIONS   │   │Proj A│─────►│Proj B│                   │
│ AGENTS        │   └──────┘      └──────┘                   │
└───────────────┴─────────────────────────────────────────────┘
```

**Key questions answered:**
- Overall health of research program?
- Which projects need attention?
- What's in the submission queue?

### Level 2: Project View
```
┌─────────────────────────────────────────────────────────────┐
│ PROJECT: CMB Anomalies                    Status: Active    │
├───────────────┬─────────────────────────────────────────────┤
│ THREADS (12)  │         DELIVERABLES                        │
│ ● active (5)  │   Paper: 60% ████████░░░░                  │
│ ○ blocked (2) │   Code:  90% █████████████░                │
│ ✓ done (5)    │   Data:  100% ██████████████               │
└───────────────┴─────────────────────────────────────────────┘
```

**Key questions answered:**
- Is project on track?
- What's blocking progress?
- What's the team doing?

### Level 3: Thread View
Current Team View expanded with:
- Full event history
- Temperature breakdown
- Dependency graph
- Artifact list

### Level 4: Event View
Detailed view of single event:
- Full message content
- Actor information
- Related events (causation chain)
- Payload details

## Data Model Extensions

### Program
```rust
pub struct Program {
    pub id: ProgramId,
    pub name: String,
    pub projects: Vec<ProjectId>,
    pub created_at: DateTime<Utc>,
}
```

### Project
```rust
pub struct Project {
    pub id: ProjectId,
    pub program_id: Option<ProgramId>,
    pub name: String,
    pub status: ProjectStatus,
    pub threads: Vec<ThreadId>,
    pub deliverables: Vec<Deliverable>,
    pub relations: Vec<(ProjectId, ProjectRelation)>,
}

pub enum ProjectStatus {
    Planning,
    Active,
    Review,
    Complete,
    Paused,
    Cancelled,
}

pub enum ProjectRelation {
    FollowOn { predecessor: ProjectId },
    Synthesis { sources: Vec<ProjectId> },
    Sibling { shared_scope: String },
    Dependency { provides: Vec<String> },
}
```

## Navigation

### Keyboard
| Key | Action |
|-----|--------|
| `1-4` | Jump to zoom level |
| `Enter` | Drill down to next level |
| `Esc` | Return to previous level |
| `hjkl` | Navigate within level |

### Commands
```
:project-new <name> --config <file>
:project-pause <project>
:project-resume <project>
:link <p1> <p2> --as <relation>
:transfer <thread> --to <project>
:digest --level program
```

## Consequences

### Positive
- Information at appropriate granularity
- Natural drill-down workflow
- Supports multi-project research programs
- Clear hierarchy matches mental model

### Negative
- More complex state management
- Navigation can feel nested
- Requires maintaining multiple view implementations

## Implementation
New TUI view files:
- `program_view.rs` - Level 1
- `project_view.rs` - Level 2
- `thread_view.rs` - Level 3 (enhanced from Team)
- `event_view.rs` - Level 4 (enhanced from Ground)
