---
name: ralph
description: "Convert a PRD into prd.json for the Ralph autonomous loop. Use when you have an existing PRD and need Ralph's JSON user-story format. Triggers on: convert this prd, turn this into ralph format, create prd.json from this, ralph json, 转成 ralph 格式, 生成 prd.json, 把 PRD 转 JSON."
---

# Ralph PRD Converter

Converts an existing PRD (markdown file or text) into the `prd.json` format that Ralph executes.

---

## The Job

Take a PRD and write `prd.json` in the project root (the directory that holds `.git`), so the loop can run there.

Do NOT implement anything. Only convert.

---

## Output Format

```json
{
  "project": "[Project Name]",
  "branchName": "ralph/[feature-name-kebab-case]",
  "description": "[Feature description from PRD title/intro]",
  "userStories": [
    {
      "id": "US-001",
      "title": "[Story title]",
      "description": "As a [user], I want [feature] so that [benefit]",
      "acceptanceCriteria": [
        "Criterion 1",
        "Criterion 2",
        "Typecheck passes"
      ],
      "priority": 1,
      "passes": false,
      "notes": ""
    }
  ]
}
```

Field contract — `ralph.sh` and the `ralph-run` skill both read these, so keep the names exact:

| Field | Meaning |
|---|---|
| `branchName` | Branch the loop works on; `ralph/` prefix by convention |
| `userStories[].priority` | Lowest number runs first |
| `userStories[].passes` | `false` until an iteration finishes and commits the story |
| `userStories[].notes` | Free text for blockers an iteration wants to leave behind |

---

## Archive Before Overwriting

**Before writing a new `prd.json`, check for an existing one from a different feature:**

1. Read the current `prd.json` if it exists
2. Compare its `branchName` with the new feature's branch name
3. If they differ AND `progress.txt` has content beyond the header:
   - Create `archive/YYYY-MM-DD-<old-feature-name>/`
   - Copy the current `prd.json` and `progress.txt` into it
   - Reset `progress.txt` to a fresh header (`# Ralph Progress Log` / `Started: <date>` / `---`)

This is the only moment the old PRD still exists — archive it here. (`ralph.sh --prepare-only` also
archives, but by then a hand-swapped `prd.json` is already gone and it can only save `progress.txt`.)

---

## Story Size: The Number One Rule

**Each story must be completable in ONE Ralph iteration (one context window).**

Ralph spawns a fresh agent instance per iteration with no memory of previous work. If a story is too big, the LLM runs out of context before finishing and produces broken code.

### Right-sized stories:
- Add a database column and migration
- Add a UI component to an existing page
- Update a server action with new logic
- Add a filter dropdown to a list

### Too big (split these):
- "Build the entire dashboard" — split into: schema, queries, UI components, filters
- "Add authentication" — split into: schema, middleware, login UI, session handling
- "Refactor the API" — split into one story per endpoint or pattern

**Rule of thumb:** if you cannot describe the change in 2-3 sentences, it is too big.

---

## Story Ordering: Dependencies First

Stories execute in priority order. Earlier stories must not depend on later ones.

**Correct order:**
1. Schema/database changes (migrations)
2. Server actions / backend logic
3. UI components that use the backend
4. Dashboard/summary views that aggregate data

**Wrong order:**
1. UI component (depends on schema that does not exist yet)
2. Schema change

---

## Acceptance Criteria: Must Be Verifiable

Each criterion must be something an iteration can CHECK, not something vague.

### Good criteria (verifiable):
- "Add `status` column to tasks table with default 'pending'"
- "Filter dropdown has options: All, Active, Completed"
- "Clicking delete shows confirmation dialog"
- "Typecheck passes"
- "Tests pass"

### Bad criteria (vague):
- "Works correctly"
- "User can do X easily"
- "Good UX"
- "Handles edge cases"

### Always include as the final criterion:
```
"Typecheck passes"
```

For stories with testable logic, also include:
```
"Tests pass"
```

### For stories that change UI, also include:
```
"Verify in browser using the browser automation skill"
```

Frontend stories are NOT complete until visually verified. In ZCode the iteration agent uses
`browser-use:web-gui-tester` or `browser-use:control-browser` to navigate the page, interact with
the UI, and confirm the change works.

---

## Conversion Rules

1. **Each user story becomes one JSON entry**
2. **IDs**: Sequential (US-001, US-002, ...)
3. **Priority**: Based on dependency order, then document order
4. **All stories**: `passes: false` and empty `notes`
5. **branchName**: Derive from the feature name, kebab-case, prefixed with `ralph/`
6. **Always add**: "Typecheck passes" to every story's acceptance criteria

---

## Splitting Large PRDs

If a PRD has big features, split them:

**Original:**
> "Add user notification system"

**Split into:**
1. US-001: Add notifications table to database
2. US-002: Create notification service for sending notifications
3. US-003: Add notification bell icon to header
4. US-004: Create notification dropdown panel
5. US-005: Add mark-as-read functionality
6. US-006: Add notification preferences page

Each is one focused change that can be completed and verified independently.

---

## Example

**Input PRD:**
```markdown
# Task Status Feature

Add ability to mark tasks with different statuses.

## Requirements
- Toggle between pending/in-progress/done on task list
- Filter list by status
- Show status badge on each task
- Persist status in database
```

**Output prd.json:**
```json
{
  "project": "TaskApp",
  "branchName": "ralph/task-status",
  "description": "Task Status Feature - Track task progress with status indicators",
  "userStories": [
    {
      "id": "US-001",
      "title": "Add status field to tasks table",
      "description": "As a developer, I need to store task status in the database.",
      "acceptanceCriteria": [
        "Add status column: 'pending' | 'in_progress' | 'done' (default 'pending')",
        "Generate and run migration successfully",
        "Typecheck passes"
      ],
      "priority": 1,
      "passes": false,
      "notes": ""
    },
    {
      "id": "US-002",
      "title": "Display status badge on task cards",
      "description": "As a user, I want to see task status at a glance.",
      "acceptanceCriteria": [
        "Each task card shows colored status badge",
        "Badge colors: gray=pending, blue=in_progress, green=done",
        "Typecheck passes",
        "Verify in browser using the browser automation skill"
      ],
      "priority": 2,
      "passes": false,
      "notes": ""
    }
  ]
}
```

---

## Checklist Before Saving

Before writing `prd.json`, verify:

- [ ] **Previous run archived** (if prd.json exists with a different branchName, archive it first)
- [ ] Each story is completable in one iteration (small enough)
- [ ] Stories are ordered by dependency (schema → backend → UI)
- [ ] Every story has "Typecheck passes" as a criterion
- [ ] UI stories have a browser-verification criterion
- [ ] Acceptance criteria are verifiable (not vague)
- [ ] No story depends on a later story
- [ ] `prd.json` sits in the project root, valid JSON (`jq . prd.json` passes)

When `prd.json` is written, tell the user the next step: run `/ralph-run` (the `ralph-run` skill)
to start the loop.
