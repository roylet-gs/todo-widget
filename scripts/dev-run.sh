#!/usr/bin/env bash
# Rebuild the Swift app into build/TodoWidget.app and relaunch it.
# Env passthrough: TODO_DB, TODO_WIDGET_OPEN=1, TODO_WIDGET_SETTINGS=1, TODO_WIDGET_SNAPSHOT=dir
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if ! out=$(cd "$ROOT/app" && swift build -c release 2>&1); then
  echo "$out" | grep -E "error" | head -20
  exit 1
fi
echo "$out" | grep -E "warning: " | grep -v todo_core.swift || true
cp "$(cd "$ROOT/app" && swift build -c release --show-bin-path)/TodoWidget" "$ROOT/build/TodoWidget.app/Contents/MacOS/TodoWidget"
codesign --force -s - "$ROOT/build/TodoWidget.app" 2>/dev/null
pkill -f "TodoWidget.app/Contents/MacOS/TodoWidget" 2>/dev/null || true
sleep 0.5
nohup "$ROOT/build/TodoWidget.app/Contents/MacOS/TodoWidget" > "${TMPDIR:-/tmp}/todowidget.log" 2>&1 &
echo "launched (pid $!)"
