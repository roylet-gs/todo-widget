//! `todo mcp`: a stdio MCP server agents launch as a local command.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use rmcp::{
    ServerHandler, ServiceExt,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{Implementation, ServerCapabilities, ServerConfig},
    tool, tool_handler, tool_router,
};
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::json;
use todo_core::{TodoItem, TaskInput, TaskPatch, TodoStore};

type ToolResult = Result<String, String>;

#[derive(Clone)]
pub struct TodoServer {
    store: Arc<TodoStore>,
    default_agent: String,
    /// Run started by this session; writes without an explicit run_id join it.
    run: Arc<Mutex<Option<String>>>,
    /// Agent name given to get_instructions/start_run, reused for later writes.
    run_agent: Arc<Mutex<Option<String>>>,
    tool_router: ToolRouter<Self>,
}

#[derive(Deserialize, JsonSchema)]
struct AgentArg {
    /// Your name as shown to the user, e.g. "Claude Desktop" or "Hermes".
    agent: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct FinishRunArgs {
    /// One-line summary of what changed, shown in the notification.
    summary: Option<String>,
    /// Defaults to the run started in this session.
    run_id: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct ListArgs {
    /// Also include tasks completed today (not yet cleared).
    include_done: Option<bool>,
}

#[derive(Deserialize, JsonSchema)]
struct IdArg {
    /// TodoItem id (or unique prefix).
    id: String,
}

#[derive(Deserialize, JsonSchema)]
struct SinceArg {
    /// RFC 3339 timestamp (e.g. the last_run value from get_instructions) or epoch milliseconds.
    since: String,
}

#[derive(Deserialize, JsonSchema)]
struct UpsertArgs {
    /// Stable id of the originating item (e.g. "slack:C123/1712345.678", "gmail:<message-id>").
    /// Re-sending the same source_ref updates the existing task instead of duplicating it.
    source_ref: Option<String>,
    /// Short imperative title, e.g. "Reply to Sam about the Q4 export format".
    title: String,
    /// 1 = highest, 3 = lowest. Defaults to 2.
    priority: Option<u8>,
    /// Due date or label, e.g. "2026-10-16", "Thu", "Today".
    due: Option<String>,
    /// Two-sentence summary of what is needed and why.
    summary: Option<String>,
    /// One line on why the task is ranked where it is.
    rationale: Option<String>,
    /// Source name, e.g. "Slack", "Gmail", "Linear".
    source: Option<String>,
    /// Permalink to the original message/thread/issue.
    source_url: Option<String>,
    /// Short quote from the original.
    excerpt: Option<String>,
    /// Who/where it came from, e.g. "Sam · #cde-ops · 8:40".
    source_from: Option<String>,
    run_id: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct UpdateArgs {
    id: String,
    title: Option<String>,
    priority: Option<u8>,
    /// Empty string clears it.
    due: Option<String>,
    summary: Option<String>,
    rationale: Option<String>,
    source: Option<String>,
    source_url: Option<String>,
    excerpt: Option<String>,
    source_from: Option<String>,
    run_id: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct ReasonArgs {
    id: String,
    /// Why, e.g. "Sam confirmed in thread".
    reason: Option<String>,
    run_id: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct ReorderArgs {
    /// Open task ids in priority order, most important first. Unlisted tasks keep their order after these.
    ordered_ids: Vec<String>,
    /// Map of task id to a one-line rationale for its position.
    rationales: Option<HashMap<String, String>>,
    run_id: Option<String>,
}

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

fn task_json(t: &TodoItem) -> serde_json::Value {
    json!({
        "id": t.id,
        "title": t.title,
        "status": t.status,
        "priority": t.priority,
        "due": t.due,
        "source": t.source,
        "source_ref": t.source_ref,
        "source_url": t.source_url,
        "summary": t.summary,
        "rationale": t.rationale,
        "added_by": t.added_by,
        "user_ranked": t.user_ranked_at.is_some(),
    })
}

fn parse_since(s: &str) -> Result<i64, String> {
    if let Ok(ms) = s.trim().parse::<i64>() {
        return Ok(ms);
    }
    chrono::DateTime::parse_from_rfc3339(s.trim())
        .map(|d| d.timestamp_millis())
        .map_err(|_| format!("could not parse '{s}' as RFC 3339 or epoch milliseconds"))
}

impl TodoServer {
    pub fn new(store: Arc<TodoStore>, default_agent: String) -> Self {
        Self { store, default_agent, run: Arc::new(Mutex::new(None)), run_agent: Arc::new(Mutex::new(None)), tool_router: Self::tool_router() }
    }

    fn agent(&self) -> String {
        self.run_agent.lock().unwrap().clone().unwrap_or_else(|| self.default_agent.clone())
    }

    /// Explicit run_id, else this session's run, else start one implicitly so
    /// every change an agent makes is grouped and undoable as a unit.
    fn run_for(&self, explicit: Option<String>) -> Result<String, String> {
        if let Some(r) = explicit.filter(|r| !r.is_empty()) {
            return Ok(r);
        }
        let mut cur = self.run.lock().unwrap();
        if let Some(r) = cur.as_ref() {
            return Ok(r.clone());
        }
        let r = self.store.start_run(self.agent()).map_err(err)?;
        *cur = Some(r.clone());
        Ok(r)
    }

    /// Called when the client disconnects: close any run left open.
    pub fn finish_open_run(&self) {
        if let Some(r) = self.run.lock().unwrap().take() {
            let _ = self.store.finish_run(r, None);
        }
    }
}

#[tool_router]
impl TodoServer {
    #[tool(description = "Start here. Returns the user's instructions for this sync (sources to check and ranking rules), the time of the last run, and all open tasks. Follow the returned prompt.")]
    async fn get_instructions(&self, Parameters(a): Parameters<AgentArg>) -> ToolResult {
        let agent = a.agent.filter(|s| !s.trim().is_empty()).unwrap_or_else(|| self.agent());
        *self.run_agent.lock().unwrap() = Some(agent.clone());
        let prompt = self.store.render_prompt(agent).map_err(err)?;
        let tasks: Vec<_> = self.store.list_tasks(false).map_err(err)?.iter().map(task_json).collect();
        let last_run = self.store.last_run_at().map_err(err)?.map(|ms| {
            chrono::DateTime::from_timestamp_millis(ms).map(|d| d.with_timezone(&chrono::Local).to_rfc3339()).unwrap_or_default()
        });
        Ok(format!(
            "{prompt}\n\n---\nlast_run: {}\nopen_tasks (in current order):\n{}",
            last_run.as_deref().unwrap_or("never"),
            serde_json::to_string_pretty(&tasks).map_err(err)?
        ))
    }

    #[tool(description = "Begin a sync run. All later writes in this session are grouped under it so the user can undo the whole run at once. Returns the run_id.")]
    async fn start_run(&self, Parameters(a): Parameters<AgentArg>) -> ToolResult {
        let agent = a.agent.filter(|s| !s.trim().is_empty()).unwrap_or_else(|| self.agent());
        *self.run_agent.lock().unwrap() = Some(agent.clone());
        let id = self.store.start_run(agent).map_err(err)?;
        *self.run.lock().unwrap() = Some(id.clone());
        Ok(json!({ "run_id": id }).to_string())
    }

    #[tool(description = "Finish the run with a one-line summary. Triggers a single notification to the user.")]
    async fn finish_run(&self, Parameters(a): Parameters<FinishRunArgs>) -> ToolResult {
        let id = match a.run_id.filter(|r| !r.is_empty()) {
            Some(r) => r,
            None => self.run.lock().unwrap().take().ok_or("no run in progress; call start_run first")?,
        };
        let g = self.store.finish_run(id, a.summary).map_err(err)?;
        Ok(json!({ "run_id": g.id, "added": g.stats.added, "updated": g.stats.updated, "done": g.stats.done, "reordered": g.stats.reordered, "deleted": g.stats.deleted }).to_string())
    }

    #[tool(description = "List open tasks in priority order (optionally with today's completed tasks).")]
    async fn list_tasks(&self, Parameters(a): Parameters<ListArgs>) -> ToolResult {
        let tasks: Vec<_> = self.store.list_tasks(a.include_done.unwrap_or(false)).map_err(err)?.iter().map(task_json).collect();
        serde_json::to_string_pretty(&tasks).map_err(err)
    }

    #[tool(description = "Get one task with all fields, including excerpt and source link.")]
    async fn get_task(&self, Parameters(a): Parameters<IdArg>) -> ToolResult {
        let t = self.store.get_task(a.id).map_err(err)?;
        serde_json::to_string_pretty(&t).map_err(err)
    }

    #[tool(description = "Changes made since a time, by the user or any agent: creates, edits, completions, deletions, moves (user drag = 'move'), and undos. Use it to respect the user's own edits.")]
    async fn get_changes_since(&self, Parameters(a): Parameters<SinceArg>) -> ToolResult {
        let since = parse_since(&a.since)?;
        let evs = self.store.changes_since(since).map_err(err)?;
        let out: Vec<_> = evs
            .iter()
            .map(|e| json!({ "actor": e.actor, "op": e.op, "task_id": e.task_id, "title": e.task_title, "reason": e.reason, "undone": e.undone,
                "at": chrono::DateTime::from_timestamp_millis(e.ts).map(|d| d.to_rfc3339()) }))
            .collect();
        serde_json::to_string_pretty(&out).map_err(err)
    }

    #[tool(description = "Create a task, or update the existing one with the same source_ref. Always pass source_ref for items from a source so repeated runs don't duplicate tasks. New/changed tasks are shown to the user as unread.")]
    async fn upsert_task(&self, Parameters(a): Parameters<UpsertArgs>) -> ToolResult {
        let run = self.run_for(a.run_id)?;
        let input = TaskInput {
            title: a.title,
            priority: a.priority,
            due: a.due,
            summary: a.summary,
            rationale: a.rationale,
            source: a.source,
            source_ref: a.source_ref,
            source_url: a.source_url,
            excerpt: a.excerpt,
            source_from: a.source_from,
        };
        let r = self.store.upsert_task(input, self.agent(), Some(run)).map_err(err)?;
        Ok(json!({ "created": r.created, "task": task_json(&r.task) }).to_string())
    }

    #[tool(description = "Edit fields of a task. Omitted fields are unchanged; an empty string clears a text field.")]
    async fn update_task(&self, Parameters(a): Parameters<UpdateArgs>) -> ToolResult {
        let run = self.run_for(a.run_id)?;
        let patch = TaskPatch {
            title: a.title,
            priority: a.priority,
            due: a.due,
            summary: a.summary,
            rationale: a.rationale,
            source: a.source,
            source_url: a.source_url,
            excerpt: a.excerpt,
            source_from: a.source_from,
        };
        let t = self.store.update_task(a.id, patch, self.agent(), Some(run)).map_err(err)?;
        Ok(task_json(&t).to_string())
    }

    #[tool(description = "Mark a task done because the source shows it is resolved. Give a short reason.")]
    async fn complete_task(&self, Parameters(a): Parameters<ReasonArgs>) -> ToolResult {
        let run = self.run_for(a.run_id)?;
        let t = self.store.set_done(a.id, true, self.agent(), Some(run), a.reason).map_err(err)?;
        Ok(task_json(&t).to_string())
    }

    #[tool(description = "Reopen a completed task. Do not reopen tasks the user completed themselves.")]
    async fn reopen_task(&self, Parameters(a): Parameters<ReasonArgs>) -> ToolResult {
        let run = self.run_for(a.run_id)?;
        let t = self.store.set_done(a.id, false, self.agent(), Some(run), a.reason).map_err(err)?;
        Ok(task_json(&t).to_string())
    }

    #[tool(description = "Delete a task that is no longer relevant (prefer complete_task when it was resolved). Give a short reason.")]
    async fn delete_task(&self, Parameters(a): Parameters<ReasonArgs>) -> ToolResult {
        let run = self.run_for(a.run_id)?;
        let t = self.store.delete_task(a.id, self.agent(), Some(run), a.reason).map_err(err)?;
        Ok(json!({ "deleted": t.id, "title": t.title }).to_string())
    }

    #[tool(description = "Set the priority order of open tasks, most important first, with an optional one-line rationale per task. Keep tasks with user_ranked=true where they are unless something new happened on them.")]
    async fn reorder_tasks(&self, Parameters(a): Parameters<ReorderArgs>) -> ToolResult {
        let run = self.run_for(a.run_id)?;
        let moved = self.store.reorder(a.ordered_ids, a.rationales.unwrap_or_default(), self.agent(), Some(run)).map_err(err)?;
        let order: Vec<_> = self.store.list_tasks(false).map_err(err)?.iter().map(|t| json!({ "id": t.id, "title": t.title })).collect();
        Ok(json!({ "moved": moved, "order": order }).to_string())
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for TodoServer {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("todo", env!("CARGO_PKG_VERSION")))
            .with_instructions(
                "The user's todo list, shown in a desktop widget. Call get_instructions first and follow the prompt it returns. \
                 Group your writes with start_run / finish_run so the user gets one notification and can undo the run.",
            )
    }
}

pub async fn serve(store: Arc<TodoStore>, agent: String) -> anyhow::Result<()> {
    let _ = store.close_stale_runs(5 * 60 * 1000);
    let server = TodoServer::new(store, agent);
    let handle = server.clone();
    let running = server.serve(rmcp::transport::stdio()).await?;
    let _ = running.waiting().await;
    handle.finish_open_run();
    Ok(())
}
