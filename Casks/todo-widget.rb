# Template for Casks/todo-widget.rb, which publish.yml regenerates on every release
# (version and checksum filled in). The cask lives in this repo so it can be tapped directly:
#   brew tap roylet-gs/todo-widget https://github.com/roylet-gs/todo-widget
#   brew install --cask todo-widget
cask "todo-widget" do
  version "0.1.11"
  sha256 "42c9252dc47d4e5f3a3c3fedcbebaf2fa138baa4e80ad549d8b41320aaf5423c"

  url "https://github.com/roylet-gs/todo-widget/releases/download/v#{version}/TodoWidget-v#{version}.zip"
  name "Todo Widget"
  desc "Always-on todo list that AI agents keep up to date through a local MCP server"
  homepage "https://github.com/roylet-gs/todo-widget"

  depends_on macos: :tahoe

  app "TodoWidget.app"
  binary "#{appdir}/TodoWidget.app/Contents/MacOS/todo"

  # The app is ad-hoc signed (not notarized), so clear the download quarantine flag.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/TodoWidget.app"], must_succeed: false
  end

  uninstall quit: "com.todowidget.app"

  zap trash: [
    "~/Library/Application Support/TodoWidget",
    "~/Library/Preferences/com.todowidget.app.plist",
  ]

  caveats <<~EOS
    Open Todo Widget once to run setup. It can add the `todo` MCP server to
    Claude Code and Claude Desktop for you (Settings › Agents).
  EOS
end
