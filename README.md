# Todo Widget

An always-on macOS todo list that AI agents keep up to date. Agents (Claude Code, Claude Desktop, Hermes, or the
built-in `claude -p` runner) connect to a local MCP command, `todo mcp`, check your sources on a schedule, and
add, complete and re-rank tasks. You see one notification per run, changed tasks are marked unread, and every
change can be undone.

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
