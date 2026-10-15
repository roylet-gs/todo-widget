# Todo Widget

macOS todo list kept up to date by AI agents through a local stdio MCP server (`todo mcp`).
See README.md for the overview, install and release flow.

## Layout
- `core/` Rust `todo-core`: SQLite store, event log + undo, prompts. Exposed to Swift via UniFFI.
- `cli/` Rust `todo` binary: CLI and `todo mcp` (rmcp).
- `app/` SwiftUI app (macOS 26). Generated bindings land in `app/Sources/TodoWidget/Generated/` and
  `app/Generated/` (gitignored; `scripts/build-core.sh` regenerates them).
- `e2e/run.py` end-to-end runner; `.claude/commands/` has `/create-pr`, `/capture-evidence`, `/merge-main`.

## Build and check
- `cargo clippy --workspace --all-targets -- -D warnings` and `cargo test --workspace` (CI enforces both).
- `./scripts/bundle-app.sh` builds `build/TodoWidget.app`; `./scripts/dev-run.sh` rebuilds the Swift app and relaunches it.
- After changing the core's exported API, rerun `./scripts/build-core.sh` before building the app.

## Seeing the app (e2e)
`python3 e2e/run.py [--build] [words…]` launches the real app with `TODO_E2E_DIR` (isolated database and
preferences, never your real data), seeds it through the real CLI and MCP server, drives it with JSON
commands (`E2EServer` in `app/Sources/TodoWidget/E2E.swift`), asserts on its state, and writes snapshots
of its windows to `e2e/tmp/<spec>--<label>.png`.

- `python3 e2e/run.py --vm [words…]` (`scripts/e2e-vm.sh`) runs the suite in a headless macOS 26 VM (Tart), so the
  test app never appears on your screen; PNGs and logs are copied back to `e2e/tmp/`. First run clones a large
  image and installs Rust in the VM; `E2E_VM_KEEP=1` leaves the VM running for faster repeat runs.
- After any UI change, run the relevant specs and **read the PNGs** to check the result; add a spec (and an
  `E2EServer` command if needed) for new behaviour.
- Snapshots draw Liquid Glass as solid fills (offscreen rendering can't draw glass), and the Settings sidebar
  renders blank. Real glass needs a human look or `screencapture` with Screen Recording permission.
- Failures leave `e2e/tmp/run/<spec>/app.log` and a `<spec>--FAILURE.png`.

## Product rules
- Agent-agnostic: prompts and UI never name a specific agent. Agents identify themselves via `start_run` /
  `get_instructions`; that name is only stored as the actor on their changes. Only the MCP installers
  (`Integrations.swift`, setup's Connect step) know about specific tools.
- Sources are managed by agents through the MCP (`save_source`, `remove_source`); the app shows them read-only.
- Learning: when the user completes or rejects (`reject_task`) a task an agent added, the core stores it as feedback.
  `render_prompt` appends notes plus pending feedback to every run prompt, custom templates included. Agents fold the
  feedback into capped notes with `save_learnings`, which clears what they used.
- Prompts live in `core/src/prompt.rs` (run, discovery, schedule); the schedule cadence comes from
  `get_schedule` / `set_schedule` in the core.

## Conventions
- Every merge to `main` publishes a release (patch bump) and regenerates `Casks/todo-widget.rb`; don't edit the
  cask by hand, edit `packaging/todo-widget.rb.tmpl`.
- Persisted app state goes through `AppDefaults` (not `UserDefaults.standard`) so e2e runs stay isolated.
- Use `.liquidGlass(...)` / `.glassButton(...)` instead of `.glassEffect` / `.buttonStyle(.glass)` so e2e
  snapshots stay legible.
