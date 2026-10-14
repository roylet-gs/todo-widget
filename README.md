# Todo Widget

An always-on macOS todo list that AI agents keep up to date. Agents (Claude Code, Claude Desktop, Hermes, or the
built-in `claude -p` runner) connect to a local MCP command, `todo mcp`, check your sources on a schedule, and
add, complete and re-rank tasks. You see one notification per run, changed tasks are marked unread, and every
change can be undone.

## Install

```sh
brew tap roylet-gs/todo-widget https://github.com/roylet-gs/todo-widget
brew install --cask todo-widget
```

This installs `TodoWidget.app` into `/Applications` and links the `todo` CLI onto your PATH. Open the app once
to run setup. The app checks GitHub for new releases every 6 hours, shows a banner in the drawer and a
notification when one is out, and can run `brew upgrade --cask todo-widget` for you (Settings › General).
Settings › General › Open at login starts it automatically when you log in.

## Releases

Every merge to `main` runs CI, builds a universal (arm64 + x86_64) app, publishes a GitHub Release
(`TodoWidget-vX.Y.Z.zip`) and regenerates `Casks/todo-widget.rb` from `packaging/todo-widget.rb.tmpl`
(`.github/workflows/publish.yml`). The version is the workspace version in `Cargo.toml`, or the next patch
past the latest release; bump `Cargo.toml` for a minor or major release. The app is ad-hoc signed, and the
cask clears the quarantine flag after install.

## Layout

| Path | What |
|---|---|
| `core/` | Rust `todo-core`: SQLite (WAL) store, event log, undo/redo, prompt rendering. Exposed to Swift via UniFFI. |
| `cli/` | Rust `todo` binary: CLI plus `todo mcp`, the stdio MCP server agents launch. |
| `app/` | SwiftUI app (macOS 26+): edge-tab drawer, menubar item, settings, setup flow, notifications, built-in runner. |
| `scripts/` | `build-core.sh`, `bundle-app.sh`, `dev-run.sh`, `mcp_smoke.py`. |

Data lives in `~/Library/Application Support/TodoWidget/todo.db` (override with `TODO_DB`). Every write posts the
Darwin notification `com.todowidget.db.changed`, which the app uses to refresh immediately.

## Build and run

```sh
./scripts/bundle-app.sh            # builds core, CLI and app → build/TodoWidget.app (ad-hoc signed)
UNIVERSAL=1 ZIP=1 ./scripts/bundle-app.sh   # release build: universal app + zip
open build/TodoWidget.app
```

During development: `./scripts/dev-run.sh` rebuilds the Swift app and relaunches it. Useful env vars:
`TODO_DB=/path/test.db`, `TODO_WIDGET_OPEN=1` (open the drawer), `TODO_WIDGET_SETTINGS=1`,
`TODO_WIDGET_SKIP_SETUP=1`, `TODO_WIDGET_SNAPSHOT=dir` (write PNGs of the app's windows).

## Connect an agent

Settings › Agents does this for you. Manually:

```sh
claude mcp add --scope user todo -- /Applications/TodoWidget.app/Contents/MacOS/todo mcp --agent "Claude Code"
```

Any other MCP client:

```json
{ "mcpServers": { "todo": { "command": "/Applications/TodoWidget.app/Contents/MacOS/todo", "args": ["mcp", "--agent", "Hermes"] } } }
```

Agents should call `get_instructions` first; it returns your editable prompt (Settings › Prompt), your sources and
the open tasks.

## Tests

```sh
cargo test -p todo-core
cargo build -p todo-cli && TODO_DB=$(mktemp -d)/t.db python3 scripts/mcp_smoke.py target/debug/todo
```
