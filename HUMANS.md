# Human Operator / Product Owner Guide

Welcome! This document is your starting point as a Product Owner or operator managing AI agents in this RUP-based development project.

> **Submodule Usage:** If RUPStrikesBack is added as a submodule, prefix all paths with `RUPStrikesBack/`. For example:
> - `rules/generic/` → `RUPStrikesBack/rules/generic/`
> - `@rup-manager.md` → `@RUPStrikesBack/.claude/commands/rup-manager.md`
> - `.claude/commands/` → `RUPStrikesBack/.claude/commands/`

## Quick Start

### First Time Setup

1. **Define your project scope** in `BACKLOG.md`
2. **Organize iterations** in `PLAN.md`
3. **Read the complete Product Owner Guide**: `rules/generic/PRODUCT_OWNER_GUIDE*.md`
4. **Mark your first Sprint as "Progress"** in `PLAN.md`
5. **Invoke the agent**: Send `@rup-manager.md` to your AI agent
6. **Monitor progress** via `PROGRESS_BOARD.md` and git commits

### Daily Operation

```
1. Check PROGRESS_BOARD.md for current status
2. Review completed phase artifacts in progress/
3. Approve designs when needed (change Status to "Accepted")
4. Answer agent questions when they arise
5. Mark next Sprint as "Progress" when ready
```

## Management Commands (Version 2.0)

Use these commands to manage your project lifecycle:

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

## Your Role

### Files You Own and Modify

- **`BACKLOG.md`** - Project requirements and Backlog Items
- **`PLAN.md`** - Sprint planning and iteration organization
- **Status tokens** in design/implementation files (Proposed/Accepted/Rejected)

### Files Agents Own

- **`progress/*.md`** - All analysis, design, implementation, test, documentation files
- **`PROGRESS_BOARD.md`** - Current status tracking (agents update)
- **`README.md`** - Project overview (agents update)
- **Code and tests** in `scripts/`, `.github/`, `tests/`

## Working with Agents

### Invoking Agents

**Full RUP Cycle**:
```
@rup-manager.md
```

**Individual Phases**:
```
@agent-contractor.md   # Review scope
@agent-analyst.md      # Analyze requirements
@agent-designer.md     # Create design
@agent-constructor.md  # Implement & test
@agent-documentor.md   # Document & validate
```

### Agent Workflow

Agents execute RUP phases automatically:
1. **Contracting** - Confirm understanding of scope and rules
2. **Inception** - Analyze requirements and assess feasibility
3. **Elaboration** - Create detailed design (waits for your approval)
4. **Construction** - Implement, test, and document
5. **Documentation** - Validate docs and update README

### Execution Modes

You control agent autonomy by setting the Mode field in each Sprint section of `PLAN.md`:

**Mode: managed (Default - Interactive)**
- Agents ask for clarification
- Wait for design approval
- Stop for any ambiguity
- Recommended for complex/high-risk work

**Mode: YOLO (Autonomous)**
- Agents make reasonable assumptions
- Auto-approve designs
- Minimal human interaction
- All decisions logged in documentation
- Recommended for routine/low-risk work

**How to Configure Sprint:**

Edit PLAN.md for your Sprint:
```markdown
## Sprint 20

Status: Progress
Mode: YOLO                    # managed (default) or YOLO
Test: unit, integration       # smoke, unit, integration, none
Regression: unit              # smoke, unit, integration, none

Backlog Items:
* GH-27. Feature implementation
```

| Field | Values | Default |
|-------|--------|---------|
| Status | `Planned`, `Progress`, `Done` | `Planned` |
| Mode | `managed`, `YOLO` | `managed` |
| Test | `smoke`, `unit`, `integration`, `none` | `unit, integration` |
| Regression | `smoke`, `unit`, `integration`, `none` | `unit, integration` |

**Audit Trail:**
The Mode field creates a permanent git record showing which sprints were autonomous vs supervised - important for compliance and retrospectives.

### When Agents Need You

**In Managed Mode** (default), agents will stop and wait when:
- **Design approval needed** - Review and change Status to "Accepted"
- **Clarification needed** - Answer questions in openquestions files
- **Conflicts found** - Provide guidance to resolve

**In YOLO Mode**, agents will only stop for:
- **Critical failures** - Build errors, major API issues
- **Explicit requests** - When you ask for status updates

All YOLO decisions are logged in implementation documents for your review.

## Rules and Guidelines

All detailed rules are in the `rules/` directory:

1. **`rules/generic/PRODUCT_OWNER_GUIDE*.md`** - Your complete workflow guide
2. **`rules/generic/GENERAL_RULES*.md`** - Cooperation rules and file ownership
3. **`rules/generic/GIT_RULES*.md`** - Git conventions
4. **`rules/github_actions/GitHub_DEV_RULES*.md`** - Development standards

**Read these files** for complete details on:
- Sprint state machines
- Backlog Item states
- File ownership policies
- Design approval process
- Status token usage
- Git workflow
- Quality gates

## Monitoring Progress

### PROGRESS_BOARD.md

Check this file to see current Sprint and Backlog Item status:

```
| Sprint | Sprint Status | Backlog Item | Item Status |
|--------|---------------|--------------|-------------|
| Sprint 20 | implemented | GH-27. ... | tested |
```

### Git Commits

Each phase completion creates a git commit:
- Check commit messages for phase summaries
- All commits follow semantic format: `type: (sprint-XX) description`

### Progress Files

Check `progress/` directory for detailed artifacts:
- `sprint_${no}_analysis.md` - Requirements analysis
- `sprint_${no}_design.md` - Technical design
- `sprint_${no}_implementation.md` - Implementation notes
- `sprint_${no}_tests.md` - Test results
- `sprint_${no}_documentation.md` - Documentation validation

## Summary

As Product Owner:

1. ✅ Define scope in `BACKLOG.md`
2. ✅ Plan iterations in `PLAN.md`
3. ✅ Read complete guide: `rules/generic/PRODUCT_OWNER_GUIDE*.md`
4. ✅ Invoke agents: `@rup-manager.md`
5. ✅ Monitor via `PROGRESS_BOARD.md`
6. ✅ Approve designs when requested
7. ✅ Answer questions when agents ask

**For complete details**, see `rules/generic/PRODUCT_OWNER_GUIDE*.md`

---

**Ready to start?** Mark a Sprint as "Progress" in `PLAN.md` and invoke `@rup-manager.md`
