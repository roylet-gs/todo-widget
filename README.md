# Todo Widget

An always-on macOS todo list that AI agents keep up to date. Agents (Claude Code, Claude Desktop, Hermes, or the
built-in `claude -p` runner) connect to a local MCP command, `todo mcp`, check your sources on a schedule, and
add, complete and re-rank tasks. You see one notification per run, changed tasks are marked unread, and every
change can be undone.

## Quick start

You need macOS 26 (Tahoe) or later and [Homebrew](https://brew.sh).

**1. Install**

```sh
brew tap roylet-gs/todo-widget https://github.com/roylet-gs/todo-widget
brew install --cask todo-widget
```

This puts **TodoWidget** in your Applications folder and the `todo` command on your PATH.

**2. Open it**

```sh
open -a TodoWidget
```

You can also open **TodoWidget** from Spotlight (⌘ Space) or the Applications folder. It runs from the menu bar
(no Dock icon) and opens automatically every time you log in; you can turn that off in Settings › General.

**3. Follow the setup window** (it opens on first launch)

1. **Connect:** add the `todo` MCP to the AI agent you use (one click for Claude Code or Claude Desktop, or copy
   the config for any other MCP client), then allow notifications. If you added it to Claude Desktop,
   restart Claude Desktop.
2. **Discover sources:** copy the discovery prompt and paste it into a chat with your agent. It asks which of
   your tools to check and what matters in each, then saves them. You'll see them appear in the setup window.
3. **Schedule:** copy the schedule prompt and paste it into your agent's scheduler as a recurring task. By
   default it runs every hour, Monday to Friday, 09:00–17:00 (adjustable).

That's it. Your list lives in the small tab on the edge of your screen: click it to open the list, drag it to
move it to the other side. You can run setup again any time from Settings › General.

**Keyboard:** double-tap ⌘ in any app to show or hide the list (macOS asks for Accessibility access the first
time). Then ↑ ↓ select a task, ↩ opens it, Space marks it done, ⌫ deletes it (⌘Z undoes), Esc goes back, and
? lists every shortcut. Change any of them in Settings › Keyboard.

**Update:** the app tells you when a new version is out and can update itself (Settings › General), or run
`brew update && brew upgrade --cask todo-widget`.

**Uninstall:** `brew uninstall --cask todo-widget`. Add `--zap` to also delete your tasks and settings. Remove
the `todo` entry from your agent's MCP settings too.

## How it works

The app is agent-agnostic: agents connect to the local `todo mcp` command, pass their own name to `start_run` /
`get_instructions` (shown next to their changes; nothing is registered per agent), manage your sources with
`save_source` / `remove_source`, and update the list. Every scheduled run calls `get_instructions` first, so
changes to sources and rules apply without touching the schedule. `todo prompt --discovery` and
`todo prompt --setup` print the setup prompts. The app checks GitHub for new releases every 6 hours.

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
claude mcp add --scope user todo -- /Applications/TodoWidget.app/Contents/MacOS/todo mcp
```

Any other MCP client:

```json
{ "mcpServers": { "todo": { "command": "/Applications/TodoWidget.app/Contents/MacOS/todo", "args": ["mcp"] } } }
```

Agents should call `get_instructions` first; it returns the run prompt (Settings › Prompt), your sources and
the open tasks.

## Tests

```sh
cargo test -p todo-core
cargo build -p todo-cli && TODO_DB=$(mktemp -d)/t.db python3 scripts/mcp_smoke.py target/debug/todo
```
