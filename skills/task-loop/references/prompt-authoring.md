# Prompt Authoring for Headless Task Loops

Writing effective prompts for headless autonomous Claude Code execution requires a different approach than interactive prompting. The prompt must be entirely self-contained — there is no user to ask for clarification.

## Prompt Structure

A headless task prompt has five essential sections:

### 1. Mission Statement

Open with a clear, one-paragraph description of what the task produces. Be specific about the output format and quality bar.

```markdown
# Task Name — Task Prompt

You are generating detailed unit tests for a TypeScript codebase. Each test file
covers one source module, uses Vitest, and achieves >80% branch coverage.
```

Avoid vague missions like "improve the codebase" or "write some tests." Specificity prevents Claude from wandering.

### 2. Headless Preamble

Every headless prompt MUST include this block. Without it, Claude will attempt interactive actions that fail silently.

```markdown
## CRITICAL: You Are Running in Headless Autonomous Mode

- There is NO user to interact with. Do NOT use AskUserQuestion.
- Do NOT invoke slash commands or skills (they are disabled).
- Use the Task tool with sub-agents for research and reasoning.
- Follow the process below exactly. Work autonomously.
```

This block is non-negotiable. Place it near the top of the prompt, before any process instructions.

### 3. Process Steps

Define the exact sequence Claude follows each iteration. Number the steps. Be explicit about inputs and outputs.

Good process steps share these traits:
- **Atomic:** Each step has one clear action
- **Verifiable:** Each step produces a checkable output
- **Sequential:** Steps build on previous outputs
- **Bounded:** No step requires unbounded exploration

Example flow:
1. Read progress file, find NEXT item
2. Research (sub-agents for context gathering)
3. Execute the work
4. Verify output (re-read from disk, cross-check)
5. Update progress file
6. Commit

### 4. Forbidden Actions

List what Claude must NOT do. Headless loops are particularly prone to:
- Attempting interactive questions
- Invoking disabled slash commands
- Working on multiple items per iteration
- Modifying files outside the declared scope
- Skipping verification
- Inventing data instead of researching

```markdown
## What You Must NOT Do

- Do NOT use AskUserQuestion — there is no user in headless mode
- Do NOT invoke slash commands or skills — they are disabled
- Do NOT skip the verification step
- Do NOT work on more than one item per iteration
- Do NOT modify files outside of <output-dir>
```

### 5. Quality Criteria

Define what "done" looks like. Without this, Claude will produce inconsistent quality across iterations.

```markdown
## What Makes Good Output

A good result is one where:
1. The work item is fully complete — no partial work
2. Output matches the format specified above
3. Verification passed — output was re-read and cross-checked
4. Progress file was updated correctly
5. Changes were committed
```

## Sub-Agent Architecture

Headless prompts should leverage sub-agents for research-heavy tasks. This keeps the main context focused on execution while sub-agents handle exploration.

### Pattern: Parallel Research

```markdown
### Step 2: Research (Use Sub-Agents in Parallel)

Launch TWO sub-agents in parallel using the Task tool:

**Sub-agent 1 — Context Reader** (subagent_type: "Explore"):
Read project files and extract information relevant to the current item.

**Sub-agent 2 — Web Researcher** (subagent_type: "general-purpose"):
Use WebSearch to find real-world data and best practices.
```

### Pattern: Design Before Execute

```markdown
### Step 3: Design (Use Sub-Agent)

After research, launch ONE sub-agent:

**Sub-agent — Design Thinker** (subagent_type: "general-purpose"):
Given the research outputs, identify key decisions, propose approaches
with trade-offs, and recommend a path forward.
```

### When to Use Sub-Agents

- Information gathering (reading many files, web searches)
- Analysis that requires comparing multiple sources
- Design decisions with trade-offs

### When NOT to Use Sub-Agents

- Simple file writes
- Progress file updates
- Git commits
- Tasks that need the main context's state

## Verification Step

The verification step is the most commonly skipped and most important. Without it, errors compound across iterations.

### Pattern: Re-Read From Disk

```markdown
### Step 4: Verify

Before claiming done:
1. Re-read your output from disk (use the Read tool, not memory)
2. Cross-check all values against source documents
3. Check consistency with previously completed items
4. Check that output is self-contained and complete

If any check fails, fix before proceeding.
```

The key insight: "use the Read tool, not memory." Claude's memory of what it wrote may differ from what's actually on disk, especially after edits. Always verify by reading the actual file.

## Commit Instructions

Specify commit format to maintain clean git history:

```markdown
### Step 6: Commit

Commit all changes with format:
```
type(scope): short description

- detail
- detail

Claude
```

Adapt the type/scope convention to the project.

## Common Mistakes in Headless Prompts

**Too vague:** "Write good tests" → Claude interprets "good" differently each iteration. Be specific: "Each test file must have describe blocks for each exported function, cover happy path and error cases, and use real fixture data from __fixtures__/."

**No verification:** Without the re-read step, Claude often claims success while the file has issues. Always require disk verification.

**No scope boundaries:** Without forbidden actions, Claude may "helpfully" refactor surrounding code, modify configs, or make changes outside its scope.

**No sub-agents:** Long-context prompts where Claude reads 20 files itself lose focus. Sub-agents keep the main context clean.

**Ambiguous progress updates:** "Update the progress file" is not enough. Specify: check off the item, move the NEXT marker, add to completed list, check for ALL_TASKS_COMPLETE.
