# Capture E2E Evidence

Collect lint, test, and visual evidence that the current changes work. Uses the Cargo test suite, the MCP smoke test, and the e2e runner (`e2e/run.py`), which launches the real app in e2e mode against a throwaway database, drives it through its command channel, asserts on its state, and writes window snapshots to `e2e/tmp/`.

**IMPORTANT: You MUST complete ALL steps below. Do NOT skip steps, cut corners, or summarize. Every agent MUST be spawned. Every result MUST be collected.**

## Steps

1. **Lint check** — Run `cargo clippy --workspace --all-targets -- -D warnings` and capture the output. If it fails, stop and report.

2. **Analyze diff** — Run `git diff main...HEAD --name-only` and map changed files to tests:
   - `core/src/**` → Rust unit tests (`core/src/tests.rs`); any spec whose assertions depend on store behaviour
   - `cli/src/**` → `scripts/mcp_smoke.py`, specs `drawer_shows_seeded_tasks`, `live_update_from_agent`
   - `app/Sources/TodoWidget/DrawerView.swift`, `DrawerController.swift`, `TaskDetailView.swift`, `AppModel.swift` → drawer/tab specs
   - `SettingsView.swift` → `settings_tabs`; `SetupView.swift`, `PromptActions.swift` → `setup_flow`, `sources_managed_by_agent`, `schedule_prompt_is_hourly`
   - `core/src/prompt.rs` → `schedule_prompt_is_hourly`, `sources_managed_by_agent` and the prompt unit tests
   - `E2E.swift`, `e2e/run.py`, `scripts/*` → run everything
   `python3 e2e/run.py --list` shows all specs.

3. **Spawn ALL parallel sub-agents** using the Agent tool. You MUST launch all applicable agents in a SINGLE message with PARALLEL tool calls. Do NOT run them sequentially. Do NOT skip any agent.

   **Agent A: Rust tests** (REQUIRED) — Run `cargo test --workspace`, then `cargo build -p todo-cli && TODO_NO_NOTIFY=1 TODO_DB=$(mktemp -d)/t.db python3 scripts/mcp_smoke.py target/debug/todo`. Return pass/fail counts per test binary and the smoke-test tool results as a table, and list any failing tests by name.

   **Agent B: App e2e + screenshots** (REQUIRED) — Steps:
   1. Decide on gaps: the diff changes visible behaviour that no spec in `e2e/run.py` asserts. If so, add a `@spec` function following the existing pattern: `app.cmd(...)` to drive the app (commands are listed in `E2EServer.handle` in `app/Sources/TodoWidget/E2E.swift`; add a command there if one is missing), `app.wait_state(...)` / `expect(...)` to assert, and `app.snapshot("<window>", "<label>")` for each screen the change affects. Every spec gets a freshly seeded database and app instance, so specs never depend on each other.
   2. Run `python3 e2e/run.py --build` (rebuilds `build/TodoWidget.app`, then runs every spec). For a quick loop on one area pass words from spec names, e.g. `python3 e2e/run.py drawer sticky`.
   3. **Look at the screenshots** with the Read tool (`e2e/tmp/<spec>--<label>.png`) and check the changed UI really looks right: text legible, nothing clipped or overlapping, the new state visible. Glass is drawn as solid fills in e2e mode, and the Settings sidebar (a system material) renders blank in snapshots; neither is a bug.
   4. On failure: read `e2e/tmp/run/<spec>/app.log` and the `<spec>--FAILURE.png` snapshot, and report the assertion message.
   5. Return a pass/fail table (spec, seconds, status), what you checked in each screenshot, and the screenshot file list.
   6. Upload screenshots: `bash .claude/scripts/upload-evidence.sh e2e/tmp`

   Not covered by e2e (note this in the evidence rather than adding a spec unless the diff changes visible behaviour): real Liquid Glass rendering, the menubar item, macOS notifications, `claude -p` runs of the built-in runner, Homebrew upgrades, login items, and the installers in `Integrations.swift` (they edit real agent configs).

4. **Aggregate evidence** — Wait for ALL sub-agents to complete. Collect all results and format into structured markdown:

   ```markdown
   ## Evidence

   ### Clippy
   <details><summary>Output</summary>

   ```
   (clippy output here)
   ```

   </details>

   ### Rust Tests (X/Y passed)
   | Test Binary | Tests | Status |
   |-------------|-------|--------|
   | todo-core (lib) | 12/12 | ✅ |
   | MCP smoke test | 8/8 calls | ✅ |

   ### App E2E (X/Y passed)
   | Spec | Time | Status |
   |------|------|--------|
   | drawer_shows_seeded_tasks | 2.3s | ✅ |

   ### Screenshots
   ![Drawer](uploaded-url)
   ```

5. **Update the PR description** (if a PR exists) — Read current body, then update the `## Evidence` section. Use the REST API to avoid the GraphQL classic projects bug:
   ```bash
   gh pr view --json number,body -q '.number,.body'
   OWNER_REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
   gh api "repos/$OWNER_REPO/pulls/$PR_NUMBER" -X PATCH -f body='...'
   ```

   If no PR exists yet, return the evidence markdown for the caller to embed.

6. **Return the evidence markdown** for display.

## Completion Checklist

Before returning, verify ALL of the following:
- [ ] Clippy ran and output captured
- [ ] Agent A (Rust tests + MCP smoke test) was spawned and results collected
- [ ] Agent B (app e2e + screenshots) was spawned, screenshots were looked at, and results collected
- [ ] Evidence markdown is complete with all sections populated
- [ ] Screenshots uploaded via `upload-evidence.sh e2e/tmp`
