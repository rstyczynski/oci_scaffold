# Agent Starting Point

Welcome! This document is your starting point after checking out this project.

> **Submodule Usage:** If RUPStrikesBack is added as a submodule, prefix all paths with `RUPStrikesBack/`. For example:
> - `rules/generic/` → `RUPStrikesBack/rules/generic/`
> - `@rup-manager.md` → `@RUPStrikesBack/.claude/commands/rup-manager.md`
> - `.claude/commands/` → `RUPStrikesBack/.claude/commands/`

## Quick Start

To execute a complete development cycle automatically:

```
/rup-manager
```

## Management Commands (Version 2.0)

```
/backlog add <title>              # Add new backlog item
/backlog list [--status <status>] # List items (filtered)
/backlog prioritize               # Reorder items

/sprint create [<N>]              # Create new sprint
/sprint start [<N>]               # Start sprint (Planned → Progress)
/sprint status [<N>]              # Show sprint status
/sprint close [<N>]               # Close sprint after gates pass

/bug report <title>               # Report bug during sprint
/bug triage [<BUG-ID>]            # Evaluate for promotion
/bug list [--sprint <N>]          # List bugs

/archive-sprint <N>               # Archive completed sprint
```

## Phase Agents

To execute individual phases:

```
@agent-contractor.md   # Phase 1: Setup (Contracting)
@agent-analyst.md      # Phase 1: Setup (Inception) — merged with contractor
@agent-designer.md     # Phase 2: Design + Test Specification
@agent-constructor.md  # Phase 3: Construction (fills test skeletons, no new tests)
                       # Phase 4: Quality Gates (executed via rup-manager.md)
@agent-documentor.md   # Phase 5: Wrap-up
```

**Note:** Phase 4 (Quality Gates) is orchestrated by `rup-manager.md` using procedures from `rules/generic/test_procedures.md`. It runs quality gates (A1-A3 new-code, B1-B3 regression) and handles the fix-and-retry loop with the Constructor.

## Execution Modes

The RUP process supports two execution modes configured in `PLAN.md`:

### Mode: managed (Default - Interactive)

**Characteristics:**
- Human-supervised execution
- Agents ask for clarification on ambiguities
- Interactive decision-making at each phase
- Recommended for complex or high-risk sprints

**Behavior:**
- Wait for design approval
- Stop for unclear requirements
- Ask about significant implementation choices
- Confirm before making major decisions

### Mode: YOLO (Autonomous - "You Only Live Once")

**Characteristics:**
- Fully autonomous execution
- Agents make reasonable assumptions for weak problems
- No human interaction required
- All decisions logged in implementation docs
- Recommended for well-understood, low-risk sprints

**Behavior:**
- Auto-approve designs
- Make reasonable assumptions (documented)
- Proceed with partial test success
- Auto-fix simple issues
- Only stop for critical failures

**Decision Logging:**
All YOLO mode decisions are logged in phase documents with:
- What was ambiguous
- What assumption was made
- Rationale for the decision
- Risk assessment

**Audit Trail:**
The Mode field in PLAN.md creates a permanent git record showing which sprints were autonomous vs supervised.

**How to Detect Mode and Test Parameters:**
Read the active Sprint section in PLAN.md:
```markdown
## Sprint 20

Status: Progress
Mode: YOLO
Test: unit, integration
Regression: unit

Backlog Items:
* GH-27. Feature implementation
```

**Required fields:**
- `Mode:` — `YOLO` or `managed` (default: managed)
- `Test:` — `smoke`, `unit`, `integration`, `none` (default: unit, integration)
- `Regression:` — `smoke`, `unit`, `integration`, `none` (default: unit, integration)

See `rules/generic/sprint_definition.md` for full specification.

## Rules (MUST READ)

Before starting any work, you MUST read and understand all rules in `rules/generic` directory.

**IMPORTANT**: You MUST comply with all rules without exceptions. If anything is unclear or conflicts, ask immediately. 

## Summary

As an agent:

1. ✅ Read all rules in `rules/generic` directory
2. ✅ Invoke `@rup-manager.md` for full cycle
3. ✅ Follow agent instructions from `.claude/commands/agents/`
4. ✅ Ask questions when unclear - NEVER assume

**Ready to start?** Invoke `@rup-manager.md` to begin.
