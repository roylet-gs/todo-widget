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

- After any UI change, run the relevant specs and **read the PNGs** to check the result; add a spec (and an
  `E2EServer` command if needed) for new behaviour.
- Snapshots draw Liquid Glass as solid fills (offscreen rendering can't draw glass), and the Settings sidebar
  renders blank. Real glass needs a human look or `screencapture` with Screen Recording permission.
- Failures leave `e2e/tmp/run/<spec>/app.log` and a `<spec>--FAILURE.png`.

## Conventions
- Every merge to `main` publishes a release (patch bump) and regenerates `Casks/todo-widget.rb`; don't edit the
  cask by hand, edit `packaging/todo-widget.rb.tmpl`.
- Persisted app state goes through `AppDefaults` (not `UserDefaults.standard`) so e2e runs stay isolated.
- Use `.liquidGlass(...)` / `.glassButton(...)` instead of `.glassEffect` / `.buttonStyle(.glass)` so e2e
  snapshots stay legible.
