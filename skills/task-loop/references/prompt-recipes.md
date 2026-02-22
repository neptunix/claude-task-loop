# Prompt Recipes

Copy-paste-ready prompt blocks for common autonomous loop workflows. Each recipe includes: when to use, the prompt block, required config, and an example state file.

## PR-Review-Fix-Merge Cycle

**When to use:** Your loop creates PRs and needs to wait for CI/review, address feedback, and merge — all without human intervention.

### Prompt Block

```markdown
## PR-CHECKPOINT Protocol

When you reach a task marked `PR-CHECKPOINT`:

1. **Check for open PR on the current branch:**
   ```
   gh pr list --head $(git branch --show-current) --json number,title,state --jq '.[0]'
   ```

2. **If no PR exists:** Create one using `gh pr create --fill`.

3. **If PR exists:** Check CI and review status:
   ```
   gh pr checks <PR_NUMBER> --watch --fail-level all
   gh api repos/<OWNER>/<REPO>/pulls/<PR_NUMBER>/comments
   gh pr view <PR_NUMBER> --comments
   ```

4. **If CI fails or reviewers flagged issues:**
   - Read the feedback carefully
   - Fix the issues in new commits (do NOT amend)
   - Push fixes and write to the state file:
     ```json
     {"pr_number": <N>, "fix_cycle": <count>, "branch": "<name>"}
     ```
   - Write BLOCKERS.md with STOP + RESUME_AFTER=300 to wait for re-review

5. **If CI passes and no blocking feedback:**
   - Merge with `gh pr merge <PR_NUMBER> --squash --delete-branch`
   - Clear the state file
   - Check off the PR-CHECKPOINT item and continue

6. **Safety limits:**
   - If fix_cycle > 5, write STOP without RESUME_AFTER (human intervention needed)
   - Never force-push or amend published commits
```

### Required Config

```bash
POST_HOOK=""                    # Optional: "npm run validate 2>&1 | tail -20"
PRE_CONTEXT="echo 'Branch: '$(git branch --show-current); gh pr list --limit 3 2>/dev/null || true"
STATE_FILE=".task-loop-state.json"
```

### Example State File

```json
{
  "pr_number": 11,
  "fix_cycle": 2,
  "branch": "phase1/p0-safety",
  "last_action": "pushed-fixes"
}
```

---

## Multi-Branch Workflow

**When to use:** Work is organized into phases or sections, each on its own branch. The loop creates a branch, does the work, opens a PR, and moves to the next phase.

### Prompt Block

```markdown
## Branch Strategy

Each task group gets its own branch:
1. Read the state file for the current branch (if any)
2. If no branch, create one: `git checkout -b <phase>/<task-slug> master`
3. Do the work for the current task
4. When the group is done, create a PR and write to state:
   ```json
   {"phase": "<name>", "branch": "<branch>", "pr_number": <N>, "status": "pr_open"}
   ```
5. Follow the PR-CHECKPOINT protocol above to merge
6. After merge, checkout master, pull, and start the next group
```

### Required Config

```bash
STATE_FILE=".task-loop-state.json"
PRE_CONTEXT="git branch --show-current; git log --oneline -3"
```

### Example State File

```json
{
  "phase": "p1-indicators",
  "branch": "phase1/p1-indicators",
  "pr_number": null,
  "status": "in_progress"
}
```

---

## Smoke Test with Retry

**When to use:** After each unit of work, you want Claude to run a validation command and retry if it fails, before moving on.

### Prompt Block

```markdown
## Verification Protocol

After completing each work item:

1. Run the smoke test: `npm run validate`
2. If it passes, proceed to commit and update progress
3. If it fails:
   - Read the error output carefully
   - Fix the issue
   - Re-run the smoke test
   - Retry up to 3 times
   - If still failing after 3 retries, commit what you have with a `fix:` prefix,
     add a note in the progress file, and move on
```

### Required Config

```bash
# Use POST_HOOK as a safety net — catches failures Claude missed
POST_HOOK="npm run validate 2>&1 | tail -20"
POST_HOOK_FAIL_ACTION="retry"
```

### Example State File

Not needed for this recipe — retries happen within the iteration.

---

## Quality Gate with Follow-Up

**When to use:** After completing a batch of items, run a comprehensive quality scan and create follow-up tasks for any issues found.

### Prompt Block

```markdown
## Quality Gate

When you reach a task marked `QUALITY-GATE`:

1. Run the full quality suite:
   ```
   npm run validate
   npm test -- --coverage
   ```

2. Analyze the results:
   - Any test failures? → Fix immediately
   - Coverage dropped below threshold? → Add tests for uncovered paths
   - Type errors? → Fix type issues

3. If issues were found:
   - Fix what you can in this iteration
   - For remaining issues, add new unchecked items to the progress file
     below the QUALITY-GATE item (do NOT add them above completed items)
   - Move the NEXT marker to the first new issue

4. If all checks pass:
   - Check off the QUALITY-GATE item
   - Move NEXT to the next unchecked item
   - Commit with: `chore(quality): pass quality gate for <phase>`
```

### Required Config

```bash
POST_HOOK="npm test 2>&1 | tail -5"
POST_HOOK_FAIL_ACTION="warn"
```

### Example Progress File

```markdown
- [x] `src/indicators/rsi.ts` — RSI indicator
- [x] `src/indicators/atr.ts` — ATR indicator
- [ ] QUALITY-GATE: Phase 1 indicators <-- NEXT
- [ ] `src/signals/entry.ts` — Entry signal detection
```
