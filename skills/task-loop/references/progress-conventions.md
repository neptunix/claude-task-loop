# Progress File Conventions

The progress file is the coordination mechanism between the bash loop and Claude. It tracks what's done, what's next, and when to stop.

## File Format

```markdown
# Task Name — Progress

## Status

**Current phase:** Working through task queue
**Next topic:** (see queue below)

## Completed

- `output-file-1.md` — Brief description of what was produced
- `output-file-2.md` — Brief description of what was produced

## Queue

- [x] `output-file-1.md` — Item description
- [x] `output-file-2.md` — Item description
- [ ] `output-file-3.md` — Item description <-- NEXT
- [ ] `output-file-4.md` — Item description

## Notes

- Any standing instructions or conventions
- When all items are checked, add a line at the very top: ALL_TASKS_COMPLETE
```

## Checkbox Queue

Work items use GitHub-flavored markdown checkboxes:
- `- [ ]` — Pending (not started)
- `- [x]` — Completed

Each item should include:
- An output filename or identifier
- A brief description of the work

### Good Items

```markdown
- [ ] `05-asset-selection.md` — Asset rollout sequence, graduation criteria, per-asset parameters
- [ ] `test-auth.ts` — Unit tests for authentication module: login, logout, token refresh
- [ ] `api-docs/users.md` — REST API docs for /users endpoints: CRUD, search, pagination
```

### Bad Items

```markdown
- [ ] Write some tests        # Too vague — which tests? For what?
- [ ] Improve documentation   # No specific output file or scope
- [ ] Fix bugs               # Not a discrete unit of work
```

## The NEXT Marker

The `<-- NEXT` marker tells Claude which item to work on this iteration. It appears at the end of exactly one unchecked item.

```markdown
- [x] `01-overview.md` — Product overview
- [x] `02-analysis.md` — Market analysis
- [ ] `03-logic.md` — Trading decision logic <-- NEXT
- [ ] `04-risk.md` — Risk rules
```

### Rules for NEXT Marker

1. Exactly ONE item has `<-- NEXT` at any time
2. It must be on an unchecked `- [ ]` item
3. When Claude completes an item, it checks it off AND moves NEXT to the next unchecked item
4. If no NEXT marker is found, Claude should work on the first unchecked item

### Updating Progress

After completing an item, Claude should:

1. Check off the completed item: `- [x] description`
2. Move `<-- NEXT` to the next unchecked item
3. Add the output to the "Completed" section
4. If ALL items are checked, add the completion sentinel

```markdown
# Before
- [ ] `03-logic.md` — Trading logic <-- NEXT
- [ ] `04-risk.md` — Risk rules

# After
- [x] `03-logic.md` — Trading logic
- [ ] `04-risk.md` — Risk rules <-- NEXT
```

## Sentinel Patterns

Sentinels are standalone lines that the bash loop checks with `grep -q "^SENTINEL$"`. They must appear on their own line, exactly matching the configured value.

### Completion Sentinel

Default: `ALL_TASKS_COMPLETE`

When Claude completes the last item in the queue, it adds the sentinel at the very top of the progress file:

```markdown
ALL_TASKS_COMPLETE
# Task Name — Progress

## Status
...
```

The bash loop detects this and exits with success.

### Stop Sentinel

Default: `STOP`

When Claude encounters a situation requiring human input, it writes to the blockers file:

```markdown
STOP

## Blocker: Need API credentials

The task requires Hyperliquid API credentials to proceed.
Please provide testnet API key and secret.
```

The `STOP` must be on its own line. The bash loop detects this and exits, printing the blockers file content.

### Auto-Resume with RESUME_AFTER

When Claude needs to pause (e.g., waiting for PR reviews), it can write a timed blocker instead of halting permanently:

```markdown
STOP

## Waiting for PR review

PR #11 created. Waiting for CI and review feedback.

RESUME_AFTER=300
```

The loop will:
1. Detect `STOP` as usual
2. Find `RESUME_AFTER=300` (seconds)
3. Sleep 300 seconds (5 minutes)
4. Continue to the next iteration

Claude decides whether to clear the blocker on the next iteration. If the PR still isn't reviewed, it can write `STOP` + `RESUME_AFTER` again.

**Important:** `RESUME_AFTER=<seconds>` must be on its own line, with an integer value. If the line is missing, the loop halts as before (backward compatible).

### Custom Sentinels

Configure different sentinels in `.task-loop.env`:

```bash
COMPLETION_SENTINEL="ALL_DOCS_GENERATED"
STOP_SENTINEL="BLOCKED"
```

The grep pattern is `^SENTINEL$` — the sentinel must be the entire line.

## Ordering Work Items

### Dependencies

If items build on each other, order them so dependencies come first:

```markdown
- [ ] `01-overview.md` — Product overview (foundation)
- [ ] `02-analysis.md` — Market analysis (needs overview context)
- [ ] `03-logic.md` — Trading logic (needs analysis)
```

### Grouping

Group related items together. The loop processes them in order, so grouping creates natural phases:

```markdown
### Phase 1: Foundation
- [ ] `01-overview.md` — Product overview
- [ ] `02-analysis.md` — Market analysis

### Phase 2: Core Logic
- [ ] `03-logic.md` — Trading logic
- [ ] `04-risk.md` — Risk rules

### Phase 3: Operations
- [ ] `05-ops.md` — Operational requirements
```

Note: The NEXT marker works across groups. Claude scans the entire file for `<-- NEXT`.

## Integration with the Loop Script

The bash loop (`run-task-loop.sh`) interacts with the progress file in two ways:

1. **Pre-iteration check:** `grep -q "^${COMPLETION_SENTINEL}$" "$PROGRESS_FILE"` — if found, exit
2. **Progress display:** `grep -n "<-- NEXT" "$PROGRESS_FILE"` — show current item in console

Claude interacts with it by:
1. Reading to find the NEXT item
2. Editing to check off completed items and move NEXT
3. Adding the completion sentinel when all items are done

## Recovering from Issues

### NEXT Marker Missing

If the NEXT marker is lost (e.g., Claude forgot to move it), add it manually to the first unchecked item and restart the loop.

### Item Checked but Work Incomplete

If Claude checked off an item but the output is incomplete, uncheck it, add `<-- NEXT` to it, and restart. Claude will redo the work.

### Multiple Items Checked in One Iteration

This usually means the prompt isn't enforcing "one item per iteration." Add explicit instructions: "Work on exactly ONE item per iteration. Do not proceed to the next item."

### Sentinel Added Prematurely

If the completion sentinel was added but items remain unchecked, remove the sentinel line and add `<-- NEXT` to the first unchecked item.
