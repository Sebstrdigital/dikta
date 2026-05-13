# CLAUDE.md

## Workflow Rules — READ FIRST

**Do not write code without explicit approval.** When the user describes a change, bug, or feature:

1. **Analyze** — Read the relevant code, understand the problem
2. **Propose** — Explain your approach concisely
3. **Wait** — Get explicit approval before touching any code
4. **Implement** — Only then make changes

**Use takt for non-trivial work.** For features likely 3+ stories, suggest `/takt-prd` → `/takt` → `takt solo`/`takt team`. Opus is the analyst/architect. Sonnet implements via takt agents.

## Project Overview

Dikta is a minimal, fully offline dictation app for macOS (v0.4). Press a hotkey, speak, and your words are pasted. Menu bar app, no cloud services.

- **dikta-macos/** — Primary implementation (Swift/SwiftUI/WhisperKit)
- **dikta-windows/** — Windows port (.NET 8/C#/WPF)
- **dikta-python/** — Legacy, not actively developed

## Conventions

- **Release titles**: `Dikta vX.Y — Short Subtitle` (e.g. "Dikta v0.4 — Stability & Polish")
- **No debug builds for testing** — only release builds (`build-release.sh`)

## Build & Run

```bash
cd dikta-macos
open Dikta.xcodeproj        # Development
./scripts/build-release.sh   # Release: signed, notarized DMG → build/Dikta.dmg
```

## Validation (HARD RULE)

Before and after ANY code change, run the relevant test suite defined in **[docs/validation.md](docs/validation.md)**. Read that file to find the correct test command for the area you're working in. Establish a green baseline BEFORE proposing fixes. Never skip this.

## Detailed Docs

- **[Architecture](docs/architecture.md)** — Key files, hotkey system, config, menu structure, permissions
- **[Validation](docs/validation.md)** — Mandatory test runs per code area

## jCodeMunch
indexed_commit: c3185a3
indexed_at: 2026-03-07

# context-mode — MANDATORY routing rules

You have context-mode MCP tools available. These rules are NOT optional — they protect your context window from flooding. A single unrouted command can dump 56 KB into context and waste the entire session.

## BLOCKED commands — do NOT attempt these

### curl / wget — BLOCKED
Any Bash command containing `curl` or `wget` is intercepted and replaced with an error message. Do NOT retry.
Instead use:
- `ctx_fetch_and_index(url, source)` to fetch and index web pages
- `ctx_execute(language: "javascript", code: "const r = await fetch(...)")` to run HTTP calls in sandbox

### Inline HTTP — BLOCKED
Any Bash command containing `fetch('http`, `requests.get(`, `requests.post(`, `http.get(`, or `http.request(` is intercepted and replaced with an error message. Do NOT retry with Bash.
Instead use:
- `ctx_execute(language, code)` to run HTTP calls in sandbox — only stdout enters context

### WebFetch — BLOCKED
WebFetch calls are denied entirely. The URL is extracted and you are told to use `ctx_fetch_and_index` instead.
Instead use:
- `ctx_fetch_and_index(url, source)` then `ctx_search(queries)` to query the indexed content

## REDIRECTED tools — use sandbox equivalents

### Bash (>20 lines output)
Bash is ONLY for: `git`, `mkdir`, `rm`, `mv`, `cd`, `ls`, `npm install`, `pip install`, and other short-output commands.
For everything else, use:
- `ctx_batch_execute(commands, queries)` — run multiple commands + search in ONE call
- `ctx_execute(language: "shell", code: "...")` — run in sandbox, only stdout enters context

### Read (for analysis)
If you are reading a file to **Edit** it → Read is correct (Edit needs content in context).
If you are reading to **analyze, explore, or summarize** → use `ctx_execute_file(path, language, code)` instead. Only your printed summary enters context. The raw file content stays in the sandbox.

### Grep (large results)
Grep results can flood context. Use `ctx_execute(language: "shell", code: "grep ...")` to run searches in sandbox. Only your printed summary enters context.

## Tool selection hierarchy

1. **GATHER**: `ctx_batch_execute(commands, queries)` — Primary tool. Runs all commands, auto-indexes output, returns search results. ONE call replaces 30+ individual calls.
2. **FOLLOW-UP**: `ctx_search(queries: ["q1", "q2", ...])` — Query indexed content. Pass ALL questions as array in ONE call.
3. **PROCESSING**: `ctx_execute(language, code)` | `ctx_execute_file(path, language, code)` — Sandbox execution. Only stdout enters context.
4. **WEB**: `ctx_fetch_and_index(url, source)` then `ctx_search(queries)` — Fetch, chunk, index, query. Raw HTML never enters context.
5. **INDEX**: `ctx_index(content, source)` — Store content in FTS5 knowledge base for later search.

## Subagent routing

When spawning subagents (Agent/Task tool), the routing block is automatically injected into their prompt. Bash-type subagents are upgraded to general-purpose so they have access to MCP tools. You do NOT need to manually instruct subagents about context-mode.

## Output constraints

- Keep responses under 500 words.
- Write artifacts (code, configs, PRDs) to FILES — never return them as inline text. Return only: file path + 1-line description.
- When indexing content, use descriptive source labels so others can `ctx_search(source: "label")` later.

## ctx commands

| Command | Action |
|---------|--------|
| `ctx stats` | Call the `ctx_stats` MCP tool and display the full output verbatim |
| `ctx doctor` | Call the `ctx_doctor` MCP tool, run the returned shell command, display as checklist |
| `ctx upgrade` | Call the `ctx_upgrade` MCP tool, run the returned shell command, display as checklist |
