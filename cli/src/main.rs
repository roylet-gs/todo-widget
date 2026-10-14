mod mcp;

use std::sync::Arc;

use anyhow::{Result, bail};
use clap::{Parser, Subcommand};
use todo_core::{TodoItem, TaskInput, TaskPatch, TodoStore, USER};

#[derive(Parser)]
#[command(name = "todo", version, about = "Agent-managed todo list (CLI + MCP server for the Todo Widget app)")]
struct Cli {
    /// Database path (default: $TODO_DB or ~/Library/Application Support/TodoWidget/todo.db).
    #[arg(long, global = true)]
    db: Option<String>,
    /// Act as this actor instead of the user (e.g. an agent name).
    #[arg(long = "as", global = true, value_name = "ACTOR")]
    actor: Option<String>,
    /// Print JSON.
    #[arg(long, global = true)]
    json: bool,
    #[command(subcommand)]
    cmd: Option<Cmd>,
}

#[derive(Subcommand)]
enum Cmd {
    /// List open tasks (default command).
    List {
        /// Include today's completed tasks.
        #[arg(short, long)]
        all: bool,
    },
    /// Add a task.
    Add {
        title: Vec<String>,
        #[arg(short, long)]
        priority: Option<u8>,
        #[arg(long)]
        due: Option<String>,
        #[arg(long)]
        source: Option<String>,
        #[arg(long)]
        url: Option<String>,
    },
    /// Show one task. IDs accept a position (1, 2, …) or a unique id prefix.
    Show { id: String },
    /// Edit a task.
    Edit {
        id: String,
        #[arg(long)]
        title: Option<String>,
        #[arg(short, long)]
        priority: Option<u8>,
        #[arg(long)]
        due: Option<String>,
    },
    /// Mark done.
    Done { id: String },
    /// Reopen a done task.
    Reopen { id: String },
    /// Delete a task.
    Rm { id: String },
    /// Move a task to a 1-based position.
    Mv { id: String, position: u32 },
    /// Undo the most recent change (a whole agent run counts as one change).
    Undo,
    /// Redo the most recently undone change.
    Redo,
    /// Recent change groups.
    History {
        #[arg(short = 'n', long, default_value_t = 15)]
        limit: u32,
    },
    /// Clear done tasks completed before today.
    Clear,
    /// Print the prompt template, or the rendered run / discovery / schedule prompt.
    Prompt {
        /// The run prompt with sources, last run and time filled in.
        #[arg(long)]
        render: bool,
        /// The prompt that sets up a recurring schedule in your agent.
        #[arg(long)]
        setup: bool,
        /// The prompt that discovers sources with you, interactively.
        #[arg(long)]
        discovery: bool,
    },
    /// List, add or remove sources.
    Sources {
        #[command(subcommand)]
        cmd: Option<SourceCmd>,
    },
    /// Run the MCP server over stdio (this is what agents launch).
    Mcp {
        /// Default agent name for changes when the agent doesn't give one.
        #[arg(long, env = "TODO_AGENT", default_value = "Agent")]
        agent: String,
    },
    /// Print the database path.
    Path,
}

#[derive(Subcommand)]
enum SourceCmd {
    Add {
        name: String,
        #[arg(long, default_value = "Other")]
        kind: String,
        #[arg(long, default_value = "")]
        instructions: String,
    },
    Rm { name: String },
}

fn priority_label(p: u8) -> &'static str {
    match p {
        1 => "P1",
        2 => "P2",
        _ => "P3",
    }
}

fn print_task_line(i: usize, t: &TodoItem) {
    let dot = if t.unread && t.status == "open" { "●" } else { " " };
    let check = if t.status == "done" { "✓" } else { " " };
    let mut meta = Vec::new();
    if let Some(s) = &t.source {
        meta.push(s.clone());
    }
    if let Some(d) = &t.due {
        meta.push(d.clone());
    }
    let meta = if meta.is_empty() { String::new() } else { format!("  ({})", meta.join(" · ")) };
    println!("{:>3}. {dot}{check} [{}] {}{meta}  {}", i + 1, priority_label(t.priority), t.title, &t.id[..8.min(t.id.len())]);
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let store = TodoStore::open(cli.db.clone())?;
    let actor = cli.actor.clone().unwrap_or_else(|| USER.to_string());
    let json = cli.json;
    let out = |v: &dyn erased::Json| -> Result<()> {
        println!("{}", v.to_json()?);
        Ok(())
    };

    match cli.cmd.unwrap_or(Cmd::List { all: false }) {
        Cmd::List { all } => {
            let tasks = store.list_tasks(all)?;
            if json {
                return out(&tasks);
            }
            if tasks.is_empty() {
                println!("Nothing to do.");
            }
            for (i, t) in tasks.iter().enumerate() {
                print_task_line(i, t);
            }
        }
        Cmd::Add { title, priority, due, source, url } => {
            let title = title.join(" ");
            if title.trim().is_empty() {
                bail!("title is required");
            }
            let t = store.add_task(
                TaskInput { title, priority, due, source, source_url: url, ..Default::default() },
                actor,
                None,
            )?;
            if json {
                return out(&t);
            }
            println!("Added {} {}", &t.id[..8], t.title);
        }
        Cmd::Show { id } => {
            let t = store.get_task(id)?;
            if json {
                return out(&t);
            }
            println!("{}\n  id: {}\n  {} · {} · added by {}", t.title, t.id, priority_label(t.priority), t.status, t.added_by);
            for (k, v) in [
                ("due", &t.due),
                ("source", &t.source),
                ("from", &t.source_from),
                ("link", &t.source_url),
                ("summary", &t.summary),
                ("why", &t.rationale),
                ("excerpt", &t.excerpt),
            ] {
                if let Some(v) = v {
                    println!("  {k}: {v}");
                }
            }
        }
        Cmd::Edit { id, title, priority, due } => {
            let t = store.update_task(id, TaskPatch { title, priority, due, ..Default::default() }, actor, None)?;
            println!("Edited {}", t.title);
        }
        Cmd::Done { id } => {
            let t = store.set_done(id, true, actor, None, None)?;
            println!("Done: {}", t.title);
        }
        Cmd::Reopen { id } => {
            let t = store.set_done(id, false, actor, None, None)?;
            println!("Reopened: {}", t.title);
        }
        Cmd::Rm { id } => {
            let t = store.delete_task(id, actor, None, None)?;
            println!("Deleted: {}", t.title);
        }
        Cmd::Mv { id, position } => {
            let t = store.move_task(id, position.saturating_sub(1))?;
            println!("Moved: {}", t.title);
        }
        Cmd::Undo => match store.undo_last()? {
            Some(l) => println!("Undid: {l}"),
            None => println!("Nothing to undo."),
        },
        Cmd::Redo => match store.redo_last()? {
            Some(l) => println!("Redid: {l}"),
            None => println!("Nothing to redo."),
        },
        Cmd::History { limit } => {
            let h = store.history(limit)?;
            if json {
                return out(&h);
            }
            for g in h {
                let when = chrono::DateTime::from_timestamp_millis(g.created_at)
                    .map(|d| d.with_timezone(&chrono::Local).format("%a %H:%M").to_string())
                    .unwrap_or_default();
                let s = &g.stats;
                println!(
                    "{when}  {:<16} {}  [+{} ~{} ✓{} ↕{} −{}]{}",
                    g.actor,
                    g.summary.as_deref().unwrap_or(&g.label),
                    s.added,
                    s.updated,
                    s.done,
                    s.reordered,
                    s.deleted,
                    if g.undone { " (undone)" } else { "" }
                );
            }
        }
        Cmd::Clear => {
            let n = store.archive_done(todo_core::local_midnight_ms())?;
            println!("Cleared {n} done tasks.");
        }
        Cmd::Prompt { render, setup, discovery } => {
            let text = if discovery {
                store.render_discovery_prompt()
            } else if setup {
                store.render_setup_prompt()?
            } else if render {
                store.render_prompt()?
            } else {
                store.get_prompt()?
            };
            println!("{text}");
        }
        Cmd::Sources { cmd } => match cmd {
            None => {
                let s = store.list_sources()?;
                if json {
                    return out(&s);
                }
                for s in s {
                    println!("{} {} ({}) {}  {}", if s.enabled { "●" } else { "○" }, s.name, s.kind, s.instructions, s.id);
                }
            }
            Some(SourceCmd::Add { name, kind, instructions }) => {
                let s = store.upsert_source_by_name(name, kind, instructions, true)?;
                println!("Saved source {}", s.name);
            }
            Some(SourceCmd::Rm { name }) => {
                if store.remove_source_by_name(name.clone())? {
                    println!("Removed {name}.");
                } else {
                    bail!("no source named '{name}'");
                }
            }
        },
        Cmd::Mcp { agent } => {
            let rt = tokio::runtime::Runtime::new()?;
            rt.block_on(mcp::serve(Arc::clone(&store), agent))?;
        }
        Cmd::Path => println!("{}", store.path()),
    }
    Ok(())
}

mod erased {
    pub trait Json {
        fn to_json(&self) -> anyhow::Result<String>;
    }
    impl<T: serde::Serialize> Json for T {
        fn to_json(&self) -> anyhow::Result<String> {
            Ok(serde_json::to_string_pretty(self)?)
        }
    }
}
