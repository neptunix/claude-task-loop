---
description: Show task loop status dashboard
allowed-tools: Read, Glob, Grep, Bash
---

Show the current status of the task loop by reading metrics, state, progress, and blockers.

## Step 1: Find Config

Use Glob to check if `.task-loop.env` exists in the current directory.

If it does NOT exist, tell the user: "No `.task-loop.env` found. No task loop configured in this project."
Stop here.

## Step 2: Read Config and Data Files

Read `.task-loop.env` to determine file paths. Then read all available data files:

1. `.task-loop.env` — config
2. The progress file (default `TASK_PROGRESS.md`)
3. The blockers file if it exists (default `BLOCKERS.md`)
4. The state file if it exists (default `.task-loop-state.json`)
5. The summary file if it exists (default `.task-logs/summary.jsonl`)

## Step 3: Parse Metrics

If `summary.jsonl` exists, parse it to compute:
- **Total iterations** — number of lines
- **Success rate** — count of `"result":"success"` / total
- **Average duration** — mean of `duration_s` values
- **Last result** — the result field from the last line
- **Total commits** — sum of `new_commits` values

Use Bash with `jq` or simple text processing to extract these. Example:
```bash
cat .task-logs/summary.jsonl | jq -s '{total: length, successes: [.[] | select(.result=="success")] | length, avg_duration: ([.[].duration_s] | add / length | floor), total_commits: ([.[].new_commits] | add), last_result: .[-1].result}'
```

If the file doesn't exist, show "No metrics yet (loop hasn't run)."

## Step 4: Display Dashboard

Show a formatted dashboard:

```
═══════════════════════════════════════
  Task Loop Status: <TASK_NAME>
═══════════════════════════════════════

📊 Metrics
   Iterations:   <total> (<successes> success, <failures> failed)
   Success rate:  <pct>%
   Avg duration:  <seconds>s
   Total commits: <N>
   Last result:   <result>

📋 Progress
   Completed:  <checked> / <total> items
   Current:    <NEXT item text>

🔒 Blockers
   <"None" or blocker status with RESUME_AFTER info if present>

📦 State
   <"Empty" or formatted state file contents>

📁 Logs
   Latest: .task-logs/iteration-<N>.log
   Metrics: .task-logs/summary.jsonl
```

## Step 5: Show Recommendations

Based on the status, suggest next actions:
- If blocked without RESUME_AFTER: "Resolve the blocker in BLOCKERS.md, then restart the loop."
- If blocked with RESUME_AFTER: "Loop will auto-resume. Or clear BLOCKERS.md to resume immediately."
- If last result was `hook_failed`: "Check the post hook output in the latest log."
- If last result was `no_commits`: "Claude may be stuck. Check the latest log for issues."
- If completion sentinel found: "All tasks complete! Review the output."
- Otherwise: "Loop is ready to run." and show the run command.
