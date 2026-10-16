//! todo-core: storage, event log, undo and prompt rendering shared by the
//! `todo` CLI / MCP server and the SwiftUI app (via UniFFI).

pub mod model;
pub mod notify;
pub mod prompt;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use chrono::{Local, TimeZone, Utc};
use rusqlite::{Connection, OptionalExtension, Row, params};

pub use model::*;

uniffi::setup_scaffolding!();

pub const USER: &str = "You";
const SYSTEM_CLEAR: &str = "Daily clear";

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum TodoError {
    #[error("database error: {0}")]
    Db(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("{0}")]
    Invalid(String),
}

impl From<rusqlite::Error> for TodoError {
    fn from(e: rusqlite::Error) -> Self {
        TodoError::Db(e.to_string())
    }
}

impl From<serde_json::Error> for TodoError {
    fn from(e: serde_json::Error) -> Self {
        TodoError::Db(e.to_string())
    }
}

type Result<T> = std::result::Result<T, TodoError>;

pub fn now_ms() -> i64 {
    Utc::now().timestamp_millis()
}

/// `$TODO_DB`, else `~/Library/Application Support/TodoWidget/todo.db`.
#[uniffi::export]
pub fn default_db_path() -> String {
    if let Some(p) = std::env::var_os("TODO_DB") {
        return p.to_string_lossy().into_owned();
    }
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    home.join("Library/Application Support/TodoWidget/todo.db").to_string_lossy().into_owned()
}

/// Epoch ms of the most recent local midnight.
#[uniffi::export]
pub fn local_midnight_ms() -> i64 {
    let today = Local::now().date_naive();
    let midnight = today.and_hms_opt(0, 0, 0).expect("valid midnight");
    Local
        .from_local_datetime(&midnight)
        .earliest()
        .map(|d| d.timestamp_millis())
        .unwrap_or_else(now_ms)
}

#[derive(uniffi::Object)]
pub struct TodoStore {
    conn: Mutex<Connection>,
    path: String,
}

const SCHEMA: &str = r#"
CREATE TABLE tasks (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  rank REAL NOT NULL,
  priority INTEGER NOT NULL DEFAULT 2,
  due TEXT,
  status TEXT NOT NULL DEFAULT 'open',
  summary TEXT,
  rationale TEXT,
  source TEXT,
  source_ref TEXT,
  source_url TEXT,
  excerpt TEXT,
  source_from TEXT,
  unread INTEGER NOT NULL DEFAULT 0,
  last_move INTEGER NOT NULL DEFAULT 0,
  added_by TEXT NOT NULL,
  updated_by TEXT NOT NULL,
  user_ranked_at INTEGER,
  done_at INTEGER,
  archived_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX tasks_source_ref ON tasks(source_ref) WHERE source_ref IS NOT NULL;
CREATE INDEX tasks_rank ON tasks(status, rank);

CREATE TABLE groups (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  actor TEXT NOT NULL,
  label TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  last_activity INTEGER NOT NULL,
  finished_at INTEGER,
  summary TEXT
);
CREATE INDEX groups_created ON groups(created_at);

CREATE TABLE events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  group_id TEXT NOT NULL REFERENCES groups(id),
  actor TEXT NOT NULL,
  op TEXT NOT NULL,
  task_id TEXT NOT NULL,
  task_title TEXT NOT NULL,
  before_json TEXT,
  after_json TEXT,
  reason TEXT,
  ts INTEGER NOT NULL,
  undone INTEGER NOT NULL DEFAULT 0,
  undone_at INTEGER
);
CREATE INDEX events_group ON events(group_id);
CREATE INDEX events_ts ON events(ts);

CREATE TABLE sources (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  kind TEXT NOT NULL,
  instructions TEXT NOT NULL DEFAULT '',
  enabled INTEGER NOT NULL DEFAULT 1,
  position INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE prompt_versions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  body TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
"#;

/// Version 2: feedback on agent tasks and the learning notes agents curate from it.
const SCHEMA_V2: &str = r#"
CREATE TABLE feedback (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id INTEGER NOT NULL,
  task_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  title TEXT NOT NULL,
  source TEXT,
  source_from TEXT,
  excerpt TEXT,
  added_by TEXT NOT NULL,
  reason TEXT,
  task_created_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX feedback_task ON feedback(task_id);

CREATE TABLE learnings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  text TEXT NOT NULL,
  author TEXT NOT NULL,
  position INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
"#;

/// Version 3: a short display name for a task's source link.
const SCHEMA_V3: &str = "ALTER TABLE tasks ADD COLUMN source_label TEXT;";

/// Settings keys for the two list behaviours the user can switch.
const ORDER_BY_PRIORITY: &str = "order_by_priority";
const PROTECT_TASKS: &str = "protect_tasks";

/// Caps on what an agent may save, so the notes stay small enough to send on every run.
pub const MAX_LEARNINGS: usize = 25;
pub const MAX_LEARNING_CHARS: usize = 300;
const EXCERPT_CHARS: usize = 200;

/// Feedback whose change is still in effect: a rejected task is still gone, a completed one still done.
const LIVE_FEEDBACK: &str = "SELECT f.id, f.task_id, f.kind, f.title, f.source, f.source_from, f.excerpt, f.added_by, f.reason, f.task_created_at, f.created_at
  FROM feedback f JOIN events e ON e.id = f.event_id LEFT JOIN tasks t ON t.id = f.task_id
  WHERE e.undone = 0 AND (f.kind = 'rejected' OR t.status = 'done')
  ORDER BY f.created_at DESC, f.id DESC";

const TASK_COLS: &str = "id, title, rank, priority, due, status, summary, rationale, source, source_ref, source_url, excerpt, source_from, unread, last_move, added_by, updated_by, user_ranked_at, done_at, archived_at, created_at, updated_at, source_label";

fn row_to_task(r: &Row) -> rusqlite::Result<TodoItem> {
    Ok(TodoItem {
        id: r.get(0)?,
        title: r.get(1)?,
        rank: r.get(2)?,
        priority: r.get::<_, i64>(3)? as u8,
        due: r.get(4)?,
        status: r.get(5)?,
        summary: r.get(6)?,
        rationale: r.get(7)?,
        source: r.get(8)?,
        source_ref: r.get(9)?,
        source_url: r.get(10)?,
        excerpt: r.get(11)?,
        source_from: r.get(12)?,
        unread: r.get::<_, i64>(13)? != 0,
        last_move: r.get(14)?,
        added_by: r.get(15)?,
        updated_by: r.get(16)?,
        user_ranked_at: r.get(17)?,
        done_at: r.get(18)?,
        archived_at: r.get(19)?,
        created_at: r.get(20)?,
        updated_at: r.get(21)?,
        source_label: r.get(22)?,
    })
}

fn read_task(c: &Connection, id: &str) -> Result<Option<TodoItem>> {
    Ok(c.query_row(&format!("SELECT {TASK_COLS} FROM tasks WHERE id = ?1"), [id], row_to_task)
        .optional()?)
}

fn write_task(c: &Connection, t: &TodoItem) -> Result<()> {
    c.execute(
        &format!("INSERT OR REPLACE INTO tasks ({TASK_COLS}) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23)"),
        params![
            t.id, t.title, t.rank, t.priority as i64, t.due, t.status, t.summary, t.rationale,
            t.source, t.source_ref, t.source_url, t.excerpt, t.source_from, t.unread as i64,
            t.last_move, t.added_by, t.updated_by, t.user_ranked_at, t.done_at, t.archived_at,
            t.created_at, t.updated_at, t.source_label
        ],
    )?;
    Ok(())
}

/// Open tasks in list order: by rank, or by priority then rank when the user orders by priority.
fn open_tasks(c: &Connection) -> Result<Vec<TodoItem>> {
    let order = if order_by_priority(c)? { "priority, rank, created_at" } else { "rank, created_at" };
    let mut st = c.prepare(&format!(
        "SELECT {TASK_COLS} FROM tasks WHERE status = 'open' AND archived_at IS NULL ORDER BY {order}"
    ))?;
    let rows = st.query_map([], row_to_task)?.collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

fn setting_in(c: &Connection, key: &str) -> Result<Option<String>> {
    Ok(c.query_row("SELECT value FROM settings WHERE key = ?1", [key], |r| r.get(0)).optional()?)
}

/// On unless the user turned it off.
fn order_by_priority(c: &Connection) -> Result<bool> {
    Ok(setting_in(c, ORDER_BY_PRIORITY)?.as_deref() != Some("0"))
}

fn clamp_priority(p: Option<u8>) -> u8 {
    p.unwrap_or(2).clamp(1, 3)
}

/// Empty string clears an optional text field.
fn patch_opt(target: &mut Option<String>, v: &Option<String>) {
    if let Some(v) = v {
        *target = if v.trim().is_empty() { None } else { Some(v.clone()) };
    }
}

fn new_id() -> String {
    uuid::Uuid::new_v4().simple().to_string()[..12].to_string()
}

fn is_user(actor: &str) -> bool {
    actor == USER
}

struct Ctx<'a> {
    c: &'a Connection,
    group: String,
    actor: String,
    now: i64,
}

impl Ctx<'_> {
    fn log(&self, op: &str, task_id: &str, before: Option<&TodoItem>, after: Option<&TodoItem>, reason: Option<&str>) -> Result<()> {
        let title = after.or(before).map(|t| t.title.clone()).unwrap_or_default();
        self.c.execute(
            "INSERT INTO events (group_id, actor, op, task_id, task_title, before_json, after_json, reason, ts) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
            params![
                self.group,
                self.actor,
                op,
                task_id,
                title,
                before.map(serde_json::to_string).transpose()?,
                after.map(serde_json::to_string).transpose()?,
                reason,
                self.now
            ],
        )?;
        self.c.execute("UPDATE groups SET last_activity = ?1 WHERE id = ?2", params![self.now, self.group])?;
        Ok(())
    }
}

#[uniffi::export]
impl TodoStore {
    /// Open (creating if needed) the database at `path`, or the default path when `None`.
    #[uniffi::constructor]
    pub fn open(path: Option<String>) -> Result<Arc<Self>> {
        let path = path.unwrap_or_else(default_db_path);
        if let Some(dir) = Path::new(&path).parent() {
            std::fs::create_dir_all(dir).map_err(|e| TodoError::Db(e.to_string()))?;
        }
        let conn = Connection::open(&path)?;
        conn.busy_timeout(std::time::Duration::from_millis(5000))?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        let version: i64 = conn.pragma_query_value(None, "user_version", |r| r.get(0))?;
        if version == 0 {
            conn.execute_batch(&format!("BEGIN; {SCHEMA} PRAGMA user_version = 1; COMMIT;"))?;
        }
        if version < 2 {
            conn.execute_batch(&format!("BEGIN; {SCHEMA_V2} PRAGMA user_version = 2; COMMIT;"))?;
        }
        if version < 3 {
            conn.execute_batch(&format!("BEGIN; {SCHEMA_V3} PRAGMA user_version = 3; COMMIT;"))?;
        }
        Ok(Arc::new(Self { conn: Mutex::new(conn), path }))
    }

    pub fn path(&self) -> String {
        self.path.clone()
    }

    // ---------- reads ----------

    /// Open tasks in rank order, then (if `include_done`) today's not-yet-cleared done tasks, newest first.
    pub fn list_tasks(&self, include_done: bool) -> Result<Vec<TodoItem>> {
        let c = self.conn.lock().unwrap();
        let mut out = open_tasks(&c)?;
        if include_done {
            let mut st = c.prepare(&format!(
                "SELECT {TASK_COLS} FROM tasks WHERE status = 'done' AND archived_at IS NULL ORDER BY done_at DESC"
            ))?;
            out.extend(st.query_map([], row_to_task)?.collect::<rusqlite::Result<Vec<_>>>()?);
        }
        Ok(out)
    }

    pub fn get_task(&self, id: String) -> Result<TodoItem> {
        let c = self.conn.lock().unwrap();
        let id = self.resolve(&c, &id)?;
        read_task(&c, &id)?.ok_or(TodoError::NotFound(id))
    }

    /// Accepts a full id, a unique id prefix, or a 1-based position in the open list.
    pub fn resolve_id(&self, id_or_prefix: String) -> Result<String> {
        let c = self.conn.lock().unwrap();
        self.resolve(&c, &id_or_prefix)
    }

    // ---------- task writes ----------

    /// Create a task. User-created tasks go to the top; agent-created ones to the bottom (until ranked).
    pub fn add_task(&self, input: TaskInput, actor: String, run_id: Option<String>) -> Result<TodoItem> {
        self.write(&actor, run_id, |cx| {
            let t = Self::insert_new(cx, &input)?;
            cx.log("create", &t.id, None, Some(&t), None)?;
            Ok(t)
        }, |t| format!("Added “{}”", t.title))
    }

    /// Create or update by `source_ref` (agents should always pass one).
    pub fn upsert_task(&self, input: TaskInput, actor: String, run_id: Option<String>) -> Result<UpsertResult> {
        if input.title.trim().is_empty() {
            return Err(TodoError::Invalid("title is required".into()));
        }
        self.write(&actor, run_id, |cx| {
            let existing = match &input.source_ref {
                Some(r) if !r.is_empty() => cx
                    .c
                    .query_row(&format!("SELECT {TASK_COLS} FROM tasks WHERE source_ref = ?1"), [r], row_to_task)
                    .optional()?,
                _ => None,
            };
            match existing {
                None => {
                    let t = Self::insert_new(cx, &input)?;
                    cx.log("create", &t.id, None, Some(&t), None)?;
                    Ok(UpsertResult { task: t, created: true })
                }
                Some(before) => {
                    let mut t = before.clone();
                    t.title = input.title.clone();
                    if input.priority.is_some() {
                        t.priority = clamp_priority(input.priority);
                    }
                    for (dst, src) in [
                        (&mut t.due, &input.due),
                        (&mut t.summary, &input.summary),
                        (&mut t.rationale, &input.rationale),
                        (&mut t.source, &input.source),
                        (&mut t.source_url, &input.source_url),
                        (&mut t.source_label, &input.source_label),
                        (&mut t.excerpt, &input.excerpt),
                        (&mut t.source_from, &input.source_from),
                    ] {
                        patch_opt(dst, src);
                    }
                    if t == before {
                        return Ok(UpsertResult { task: t, created: false });
                    }
                    t.updated_by = cx.actor.clone();
                    t.updated_at = cx.now;
                    if !is_user(&cx.actor) {
                        t.unread = true;
                    }
                    write_task(cx.c, &t)?;
                    cx.log("update", &t.id, Some(&before), Some(&t), None)?;
                    Ok(UpsertResult { task: t, created: false })
                }
            }
        }, |r| format!("{} “{}”", if r.created { "Added" } else { "Updated" }, r.task.title))
    }

    pub fn update_task(&self, id: String, patch: TaskPatch, actor: String, run_id: Option<String>) -> Result<TodoItem> {
        self.write(&actor, run_id, |cx| {
            let id = Self::resolve_in(cx.c, &id)?;
            let before = read_task(cx.c, &id)?.ok_or(TodoError::NotFound(id.clone()))?;
            let mut t = before.clone();
            if let Some(title) = &patch.title {
                if title.trim().is_empty() {
                    return Err(TodoError::Invalid("title cannot be empty".into()));
                }
                t.title = title.clone();
            }
            if patch.priority.is_some() {
                t.priority = clamp_priority(patch.priority);
            }
            for (dst, src) in [
                (&mut t.due, &patch.due),
                (&mut t.summary, &patch.summary),
                (&mut t.rationale, &patch.rationale),
                (&mut t.source, &patch.source),
                (&mut t.source_url, &patch.source_url),
                (&mut t.source_label, &patch.source_label),
                (&mut t.excerpt, &patch.excerpt),
                (&mut t.source_from, &patch.source_from),
            ] {
                patch_opt(dst, src);
            }
            t.updated_by = cx.actor.clone();
            t.updated_at = cx.now;
            t.unread = !is_user(&cx.actor);
            write_task(cx.c, &t)?;
            cx.log("update", &t.id, Some(&before), Some(&t), None)?;
            Ok(t)
        }, |t| format!("Edited “{}”", t.title))
    }

    pub fn set_done(&self, id: String, done: bool, actor: String, run_id: Option<String>, reason: Option<String>) -> Result<TodoItem> {
        if done {
            self.check_agent_may_remove(&actor)?;
        }
        self.write(&actor, run_id, |cx| {
            let id = Self::resolve_in(cx.c, &id)?;
            let before = read_task(cx.c, &id)?.ok_or(TodoError::NotFound(id.clone()))?;
            let mut t = before.clone();
            t.status = if done { "done" } else { "open" }.into();
            t.done_at = done.then_some(cx.now);
            t.archived_at = None;
            t.updated_by = cx.actor.clone();
            t.updated_at = cx.now;
            if is_user(&cx.actor) {
                t.unread = false;
            }
            if !done && before.status == "done" {
                // Reopened tasks go back to the top of the list.
                t.rank = Self::min_rank(cx.c)? - 1.0;
            }
            write_task(cx.c, &t)?;
            cx.log(if done { "done" } else { "reopen" }, &t.id, Some(&before), Some(&t), reason.as_deref())?;
            // The user finishing an agent's task tells the next run it was worth adding.
            if done && before.status != "done" && is_user(&cx.actor) && !is_user(&before.added_by) {
                Self::insert_feedback(cx, &before, "good", None)?;
            }
            Ok(t)
        }, |t| format!("{} “{}”", if t.status == "done" { "Completed" } else { "Reopened" }, t.title))
    }

    pub fn delete_task(&self, id: String, actor: String, run_id: Option<String>, reason: Option<String>) -> Result<TodoItem> {
        self.check_agent_may_remove(&actor)?;
        self.write(&actor, run_id, |cx| {
            let id = Self::resolve_in(cx.c, &id)?;
            let before = read_task(cx.c, &id)?.ok_or(TodoError::NotFound(id.clone()))?;
            cx.c.execute("DELETE FROM tasks WHERE id = ?1", [&id])?;
            cx.log("delete", &id, Some(&before), None, reason.as_deref())?;
            Ok(before)
        }, |t| format!("Deleted “{}”", t.title))
    }

    /// The user rejects a task an agent added: it is deleted (undoably) and recorded as feedback,
    /// with the optional reason, for the next run to learn from.
    pub fn reject_task(&self, id: String, reason: Option<String>) -> Result<TodoItem> {
        let reason = reason.map(|r| r.trim().to_string()).filter(|r| !r.is_empty());
        self.write(USER, None, |cx| {
            let id = Self::resolve_in(cx.c, &id)?;
            let before = read_task(cx.c, &id)?.ok_or(TodoError::NotFound(id.clone()))?;
            if is_user(&before.added_by) {
                return Err(TodoError::Invalid("only tasks added by an agent can be rejected".into()));
            }
            cx.c.execute("DELETE FROM tasks WHERE id = ?1", [&id])?;
            cx.log("delete", &id, Some(&before), None, Some(&match &reason {
                Some(r) => format!("Rejected: {r}"),
                None => "Rejected".to_string(),
            }))?;
            Self::insert_feedback(cx, &before, "rejected", reason.as_deref())?;
            Ok(before)
        }, |t| format!("Rejected “{}”", t.title))
    }

    /// Agent ranking: `ordered_ids` go first in that order; unlisted open tasks keep their
    /// relative order after them. `rationales` maps task id to its one-line reason.
    pub fn reorder(&self, ordered_ids: Vec<String>, rationales: HashMap<String, String>, actor: String, run_id: Option<String>) -> Result<u32> {
        self.write(&actor, run_id, |cx| {
            let current = open_tasks(cx.c)?;
            let mut listed: Vec<String> = Vec::new();
            for raw in &ordered_ids {
                let id = Self::resolve_in(cx.c, raw)?;
                if current.iter().any(|t| t.id == id) && !listed.contains(&id) {
                    listed.push(id);
                }
            }
            let mut order: Vec<&TodoItem> = listed.iter().filter_map(|id| current.iter().find(|t| &t.id == id)).collect();
            order.extend(current.iter().filter(|t| !listed.contains(&t.id)));
            let mut rationale_by_id: HashMap<String, String> = HashMap::new();
            for (k, v) in &rationales {
                rationale_by_id.insert(Self::resolve_in(cx.c, k)?, v.clone());
            }
            let mut moved = 0u32;
            for (new_idx, before) in order.iter().enumerate() {
                let old_idx = current.iter().position(|t| t.id == before.id).unwrap();
                let mut t = (*before).clone();
                t.rank = (new_idx + 1) as f64;
                let changed_pos = old_idx != new_idx;
                if changed_pos {
                    t.last_move = old_idx as i32 - new_idx as i32;
                    t.updated_by = cx.actor.clone();
                    t.updated_at = cx.now;
                    moved += 1;
                }
                if let Some(r) = rationale_by_id.get(&t.id) {
                    t.rationale = Some(r.clone());
                }
                if t == **before {
                    continue;
                }
                write_task(cx.c, &t)?;
                // "rerank" = rank renumbering only; kept for undo, hidden from history.
                let op = if changed_pos {
                    "reorder"
                } else if t.rationale != before.rationale {
                    "update"
                } else {
                    "rerank"
                };
                cx.log(op, &t.id, Some(before), Some(&t), None)?;
            }
            Ok(moved)
        }, |n| format!("Reordered {n} tasks"))
    }

    /// User drag: move a task to `new_index` (0-based) in the open list. When the list is ordered by
    /// priority, dropping a task among another priority's tasks gives it that priority: moving down it
    /// joins the task now above it, moving up the task now below it.
    pub fn move_task(&self, id: String, new_index: u32) -> Result<TodoItem> {
        self.write(USER, None, |cx| {
            let id = Self::resolve_in(cx.c, &id)?;
            let before = read_task(cx.c, &id)?.ok_or(TodoError::NotFound(id.clone()))?;
            let all = open_tasks(cx.c)?;
            let from = all.iter().position(|t| t.id == id);
            let others: Vec<TodoItem> = all.into_iter().filter(|t| t.id != id).collect();
            let i = (new_index as usize).min(others.len());
            let (prev, next) = (i.checked_sub(1).and_then(|p| others.get(p)), others.get(i));
            let by_priority = order_by_priority(cx.c)?;
            let mut t = before.clone();
            if by_priority && let Some(f) = from && i != f {
                let joined = if i > f { prev.or(next) } else { next.or(prev) };
                if let Some(n) = joined {
                    t.priority = n.priority;
                }
            }
            // Only neighbours in the task's (possibly new) priority group bound its rank.
            let p = t.priority;
            let in_group = |n: &&TodoItem| !by_priority || n.priority == p;
            t.rank = match (prev.filter(in_group), next.filter(in_group)) {
                (None, None) => 1.0,
                (None, Some(next)) => next.rank - 1.0,
                (Some(prev), None) => prev.rank + 1.0,
                (Some(prev), Some(next)) => (prev.rank + next.rank) / 2.0,
            };
            t.user_ranked_at = Some(cx.now);
            t.last_move = 0;
            t.unread = false;
            t.updated_by = USER.into();
            t.updated_at = cx.now;
            write_task(cx.c, &t)?;
            cx.log("move", &t.id, Some(&before), Some(&t), None)?;
            Ok((t, before.priority))
        }, |(t, old)| {
            if t.priority != *old { format!("Moved “{}” to P{}", t.title, t.priority) } else { format!("Moved “{}”", t.title) }
        })
        .map(|(t, _)| t)
    }

    /// Opening a task marks it read. Not undoable, not logged.
    pub fn mark_read(&self, id: String) -> Result<()> {
        let c = self.conn.lock().unwrap();
        let id = self.resolve(&c, &id)?;
        c.execute("UPDATE tasks SET unread = 0 WHERE id = ?1", [&id])?;
        drop(c);
        notify::post_changed();
        Ok(())
    }

    /// The user has looked at the "what changed" strip: clear move chips and record the time.
    pub fn mark_seen(&self) -> Result<()> {
        let c = self.conn.lock().unwrap();
        c.execute("UPDATE tasks SET last_move = 0 WHERE last_move != 0", [])?;
        c.execute(
            "INSERT INTO settings (key, value) VALUES ('last_seen_at', ?1) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [now_ms().to_string()],
        )?;
        drop(c);
        notify::post_changed();
        Ok(())
    }

    /// Archive done tasks completed before `cutoff_ms` (the app passes local midnight).
    pub fn archive_done(&self, cutoff_ms: i64) -> Result<u32> {
        let c = self.conn.lock().unwrap();
        let n: i64 = c.query_row(
            "SELECT COUNT(*) FROM tasks WHERE status = 'done' AND archived_at IS NULL AND done_at < ?1",
            [cutoff_ms],
            |r| r.get(0),
        )?;
        drop(c);
        if n == 0 {
            return Ok(0);
        }
        self.write_system(SYSTEM_CLEAR, |cx| {
            let mut st = cx.c.prepare(&format!(
                "SELECT {TASK_COLS} FROM tasks WHERE status = 'done' AND archived_at IS NULL AND done_at < ?1"
            ))?;
            let rows = st.query_map([cutoff_ms], row_to_task)?.collect::<rusqlite::Result<Vec<_>>>()?;
            for before in &rows {
                let mut t = before.clone();
                t.archived_at = Some(cx.now);
                write_task(cx.c, &t)?;
                cx.log("archive", &t.id, Some(before), Some(&t), None)?;
            }
            Ok(rows.len() as u32)
        }, |n| format!("{n} done tasks cleared"))
    }

    // ---------- runs & history ----------

    pub fn start_run(&self, agent: String) -> Result<String> {
        let agent = if agent.trim().is_empty() { "Agent".to_string() } else { agent };
        let c = self.conn.lock().unwrap();
        let id = format!("run-{}", new_id());
        let now = now_ms();
        c.execute(
            "INSERT INTO groups (id, kind, actor, label, created_at, last_activity) VALUES (?1, 'run', ?2, ?2, ?3, ?3)",
            params![id, agent, now],
        )?;
        Self::invalidate_redo(&c)?;
        Ok(id)
    }

    pub fn finish_run(&self, run_id: String, summary: Option<String>) -> Result<ChangeGroup> {
        let c = self.conn.lock().unwrap();
        let n = c.execute(
            "UPDATE groups SET finished_at = ?1, summary = COALESCE(?2, summary) WHERE id = ?3 AND kind = 'run'",
            params![now_ms(), summary, run_id],
        )?;
        if n == 0 {
            return Err(TodoError::NotFound(run_id));
        }
        let g = Self::load_group(&c, &run_id)?;
        drop(c);
        notify::post_changed();
        Ok(g)
    }

    /// Finish runs with no activity for `idle_ms` (agents that never called finish_run).
    pub fn close_stale_runs(&self, idle_ms: i64) -> Result<u32> {
        let c = self.conn.lock().unwrap();
        let cutoff = now_ms() - idle_ms;
        let n = c.execute(
            "UPDATE groups SET finished_at = last_activity WHERE kind = 'run' AND finished_at IS NULL AND last_activity < ?1",
            [cutoff],
        )?;
        if n > 0 {
            drop(c);
            notify::post_changed();
        }
        Ok(n as u32)
    }

    /// Agent runs started at or after `since_ms`, oldest first.
    pub fn runs_since(&self, since_ms: i64) -> Result<Vec<ChangeGroup>> {
        let c = self.conn.lock().unwrap();
        let ids: Vec<String> = c
            .prepare("SELECT id FROM groups WHERE kind = 'run' AND created_at >= ?1 ORDER BY created_at")?
            .query_map([since_ms], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        ids.iter().map(|id| Self::load_group(&c, id)).collect()
    }

    /// Most recent change groups first. Groups with no visible changes are skipped.
    pub fn history(&self, limit: u32) -> Result<Vec<ChangeGroup>> {
        let c = self.conn.lock().unwrap();
        let ids: Vec<String> = c
            .prepare(
                "SELECT g.id FROM groups g WHERE EXISTS (SELECT 1 FROM events e WHERE e.group_id = g.id AND e.op != 'rerank')
                 ORDER BY g.last_activity DESC, g.rowid DESC LIMIT ?1",
            )?
            .query_map([limit], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        ids.iter().map(|id| Self::load_group(&c, id)).collect()
    }

    pub fn get_group(&self, id: String) -> Result<ChangeGroup> {
        let c = self.conn.lock().unwrap();
        Self::load_group(&c, &id)
    }

    /// Visible changes (by anyone) since `since_ms`, oldest first.
    pub fn changes_since(&self, since_ms: i64) -> Result<Vec<ChangeEvent>> {
        let c = self.conn.lock().unwrap();
        let mut st = c.prepare(
            "SELECT id, group_id, actor, op, task_id, task_title, reason, ts, undone FROM events WHERE ts >= ?1 AND op != 'rerank' ORDER BY id",
        )?;
        let rows = st.query_map([since_ms], Self::row_to_event)?.collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    /// Visible changes to one task, oldest first.
    pub fn task_history(&self, id: String) -> Result<Vec<ChangeEvent>> {
        let c = self.conn.lock().unwrap();
        let mut st = c.prepare(
            "SELECT id, group_id, actor, op, task_id, task_title, reason, ts, undone FROM events WHERE task_id = ?1 AND op != 'rerank' ORDER BY id",
        )?;
        let rows = st.query_map([id], Self::row_to_event)?.collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    /// Finish time of the most recent agent run, if any.
    pub fn last_run_at(&self) -> Result<Option<i64>> {
        let c = self.conn.lock().unwrap();
        Ok(c.query_row("SELECT MAX(COALESCE(finished_at, last_activity)) FROM groups WHERE kind = 'run'", [], |r| r.get(0))?)
    }

    /// Undo the most recent group that still has live events. Returns its label.
    pub fn undo_last(&self) -> Result<Option<String>> {
        let c = self.conn.lock().unwrap();
        let gid: Option<String> = c
            .query_row("SELECT group_id FROM events WHERE undone = 0 ORDER BY id DESC LIMIT 1", [], |r| r.get(0))
            .optional()?;
        drop(c);
        match gid {
            Some(g) => self.undo_group(g).map(Some),
            None => Ok(None),
        }
    }

    pub fn undo_group(&self, group_id: String) -> Result<String> {
        let mut c = self.conn.lock().unwrap();
        let tx = c.transaction()?;
        let label = Self::group_label(&tx, &group_id)?;
        let evs: Vec<(i64, String, Option<String>)> = tx
            .prepare("SELECT id, task_id, before_json FROM events WHERE group_id = ?1 AND undone = 0 ORDER BY id DESC")?
            .query_map([&group_id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
            .collect::<rusqlite::Result<_>>()?;
        if evs.is_empty() {
            return Err(TodoError::Invalid("nothing to undo in that group".into()));
        }
        let now = now_ms();
        for (eid, task_id, before) in evs {
            Self::restore(&tx, &task_id, before.as_deref())?;
            tx.execute("UPDATE events SET undone = 1, undone_at = ?1 WHERE id = ?2", params![now, eid])?;
        }
        tx.commit()?;
        drop(c);
        notify::post_changed();
        Ok(label)
    }

    /// Redo the most recently undone group (only until a new change is made).
    pub fn redo_last(&self) -> Result<Option<String>> {
        let mut c = self.conn.lock().unwrap();
        let tx = c.transaction()?;
        let gid: Option<String> = tx
            .query_row("SELECT group_id FROM events WHERE undone = 1 AND undone_at IS NOT NULL ORDER BY undone_at DESC, id DESC LIMIT 1", [], |r| r.get(0))
            .optional()?;
        let Some(gid) = gid else { return Ok(None) };
        let label = Self::group_label(&tx, &gid)?;
        let evs: Vec<(i64, String, Option<String>)> = tx
            .prepare("SELECT id, task_id, after_json FROM events WHERE group_id = ?1 AND undone = 1 AND undone_at IS NOT NULL ORDER BY id")?
            .query_map([&gid], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
            .collect::<rusqlite::Result<_>>()?;
        for (eid, task_id, after) in evs {
            Self::restore(&tx, &task_id, after.as_deref())?;
            tx.execute("UPDATE events SET undone = 0, undone_at = NULL WHERE id = ?1", [eid])?;
        }
        tx.commit()?;
        drop(c);
        notify::post_changed();
        Ok(Some(label))
    }

    /// Reset for a fresh setup: clears sources, prompts and settings. With `erase_tasks`,
    /// also deletes every task and the whole change history.
    pub fn reset(&self, erase_tasks: bool) -> Result<()> {
        let mut c = self.conn.lock().unwrap();
        let tx = c.transaction()?;
        tx.execute_batch("DELETE FROM sources; DELETE FROM prompt_versions; DELETE FROM settings; DELETE FROM feedback; DELETE FROM learnings;")?;
        if erase_tasks {
            tx.execute_batch("DELETE FROM events; DELETE FROM groups; DELETE FROM tasks;")?;
        }
        tx.execute(
            "INSERT INTO settings (key, value) VALUES ('last_seen_at', ?1)",
            [now_ms().to_string()],
        )?;
        tx.commit()?;
        drop(c);
        notify::post_changed();
        Ok(())
    }

    // ---------- sources ----------

    pub fn list_sources(&self) -> Result<Vec<Source>> {
        let c = self.conn.lock().unwrap();
        Self::sources_in(&c)
    }

    /// Insert (empty id) or update a source. Returns the saved source. Names are unique ignoring
    /// case, since agents find sources by name.
    pub fn save_source(&self, source: Source) -> Result<Source> {
        let c = self.conn.lock().unwrap();
        let mut s = source;
        s.name = s.name.trim().to_string();
        if s.name.is_empty() {
            return Err(TodoError::Invalid("source name is required".into()));
        }
        if Self::sources_in(&c)?.iter().any(|o| o.id != s.id && o.name.eq_ignore_ascii_case(&s.name)) {
            return Err(TodoError::Invalid(format!("a source named {} already exists", s.name)));
        }
        if s.id.is_empty() {
            s.id = new_id();
            s.position = c.query_row("SELECT COALESCE(MAX(position), 0) + 1 FROM sources", [], |r| r.get(0))?;
        }
        c.execute(
            "INSERT INTO sources (id, name, kind, instructions, enabled, position) VALUES (?1,?2,?3,?4,?5,?6)
             ON CONFLICT(id) DO UPDATE SET name=excluded.name, kind=excluded.kind, instructions=excluded.instructions, enabled=excluded.enabled, position=excluded.position",
            params![s.id, s.name, s.kind, s.instructions, s.enabled as i64, s.position],
        )?;
        drop(c);
        notify::post_changed();
        Ok(s)
    }

    /// Create or update a source by name (case-insensitive). This is how agents manage sources.
    pub fn upsert_source_by_name(&self, name: String, kind: String, instructions: String, enabled: bool) -> Result<Source> {
        let name = name.trim().to_string();
        if name.is_empty() {
            return Err(TodoError::Invalid("source name is required".into()));
        }
        let existing = {
            let c = self.conn.lock().unwrap();
            Self::sources_in(&c)?.into_iter().find(|s| s.name.eq_ignore_ascii_case(&name))
        };
        let source = match existing {
            Some(s) => Source { name, kind, instructions, enabled, ..s },
            None => Source { id: String::new(), name, kind, instructions, enabled, position: 0 },
        };
        self.save_source(source)
    }

    /// Remove a source by name (case-insensitive). Returns whether one was removed.
    pub fn remove_source_by_name(&self, name: String) -> Result<bool> {
        let c = self.conn.lock().unwrap();
        let n = c.execute("DELETE FROM sources WHERE name = ?1 COLLATE NOCASE", [name.trim()])?;
        drop(c);
        if n > 0 {
            notify::post_changed();
        }
        Ok(n > 0)
    }

    pub fn delete_source(&self, id: String) -> Result<()> {
        let c = self.conn.lock().unwrap();
        c.execute("DELETE FROM sources WHERE id = ?1", [id])?;
        drop(c);
        notify::post_changed();
        Ok(())
    }

    // ---------- learning ----------

    /// Feedback not yet folded into the notes, newest first.
    pub fn list_feedback(&self) -> Result<Vec<Feedback>> {
        let c = self.conn.lock().unwrap();
        Self::feedback_in(&c)
    }

    pub fn delete_feedback(&self, id: i64) -> Result<()> {
        let c = self.conn.lock().unwrap();
        c.execute("DELETE FROM feedback WHERE id = ?1", [id])?;
        drop(c);
        notify::post_changed();
        Ok(())
    }

    pub fn clear_feedback(&self) -> Result<()> {
        let c = self.conn.lock().unwrap();
        c.execute("DELETE FROM feedback", [])?;
        drop(c);
        notify::post_changed();
        Ok(())
    }

    pub fn list_learnings(&self) -> Result<Vec<Learning>> {
        let c = self.conn.lock().unwrap();
        Self::learnings_in(&c)
    }

    /// An agent replaces the whole set of notes and drops the feedback it folded into them.
    /// Notes whose text is unchanged keep their author, so the user's own notes stay marked as theirs.
    pub fn save_learnings(&self, notes: Vec<String>, processed_feedback_ids: Vec<i64>, actor: String) -> Result<Vec<Learning>> {
        let notes: Vec<String> = notes.into_iter().map(|n| n.trim().to_string()).filter(|n| !n.is_empty()).collect();
        if notes.len() > MAX_LEARNINGS {
            return Err(TodoError::Invalid(format!(
                "{} notes is too many: merge them into at most {MAX_LEARNINGS} and save again",
                notes.len()
            )));
        }
        if let Some(long) = notes.iter().find(|n| n.chars().count() > MAX_LEARNING_CHARS) {
            return Err(TodoError::Invalid(format!(
                "notes must be at most {MAX_LEARNING_CHARS} characters; shorten: {long}"
            )));
        }
        let actor = if actor.trim().is_empty() { "Agent".to_string() } else { actor };
        let mut c = self.conn.lock().unwrap();
        let tx = c.transaction()?;
        let old = Self::learnings_in(&tx)?;
        let now = now_ms();
        tx.execute("DELETE FROM learnings", [])?;
        for (i, text) in notes.iter().enumerate() {
            let (author, updated_at) = match old.iter().find(|l| &l.text == text) {
                Some(l) => (l.author.clone(), l.updated_at),
                None => (actor.clone(), now),
            };
            tx.execute(
                "INSERT INTO learnings (text, author, position, updated_at) VALUES (?1, ?2, ?3, ?4)",
                params![text, author, i as i64, updated_at],
            )?;
        }
        for id in &processed_feedback_ids {
            tx.execute("DELETE FROM feedback WHERE id = ?1", [id])?;
        }
        let out = Self::learnings_in(&tx)?;
        tx.commit()?;
        drop(c);
        notify::post_changed();
        Ok(out)
    }

    /// The user adds a note at the end of the list.
    pub fn add_learning(&self, text: String) -> Result<Learning> {
        let text = Self::check_note(&text)?;
        let c = self.conn.lock().unwrap();
        let position: i64 = c.query_row("SELECT COALESCE(MAX(position), -1) + 1 FROM learnings", [], |r| r.get(0))?;
        c.execute(
            "INSERT INTO learnings (text, author, position, updated_at) VALUES (?1, ?2, ?3, ?4)",
            params![text, USER, position, now_ms()],
        )?;
        let id = c.last_insert_rowid();
        let l = Self::learnings_in(&c)?.into_iter().find(|l| l.id == id).ok_or(TodoError::NotFound(id.to_string()))?;
        drop(c);
        notify::post_changed();
        Ok(l)
    }

    /// The user edits a note; it becomes theirs.
    pub fn update_learning(&self, id: i64, text: String) -> Result<()> {
        let text = Self::check_note(&text)?;
        let c = self.conn.lock().unwrap();
        let n = c.execute(
            "UPDATE learnings SET text = ?1, author = ?2, updated_at = ?3 WHERE id = ?4 AND text != ?1",
            params![text, USER, now_ms(), id],
        )?;
        drop(c);
        if n > 0 {
            notify::post_changed();
        }
        Ok(())
    }

    pub fn delete_learning(&self, id: i64) -> Result<()> {
        let c = self.conn.lock().unwrap();
        c.execute("DELETE FROM learnings WHERE id = ?1", [id])?;
        drop(c);
        notify::post_changed();
        Ok(())
    }

    pub fn clear_learnings(&self) -> Result<()> {
        let c = self.conn.lock().unwrap();
        c.execute("DELETE FROM learnings", [])?;
        drop(c);
        notify::post_changed();
        Ok(())
    }

    // ---------- prompts & settings ----------

    pub fn get_prompt(&self) -> Result<String> {
        Ok(self.get_setting("prompt".into())?.unwrap_or_else(|| prompt::DEFAULT_PROMPT.to_string()))
    }

    pub fn default_prompt(&self) -> String {
        prompt::DEFAULT_PROMPT.to_string()
    }

    /// Save the prompt template and keep a version.
    pub fn set_prompt(&self, body: String) -> Result<()> {
        if self.get_prompt()? == body {
            return Ok(());
        }
        self.set_setting("prompt".into(), body.clone())?;
        let c = self.conn.lock().unwrap();
        c.execute("INSERT INTO prompt_versions (body, created_at) VALUES (?1, ?2)", params![body, now_ms()])?;
        Ok(())
    }

    /// Saved prompt versions, newest first: (version number, saved at).
    pub fn prompt_versions(&self) -> Result<Vec<PromptVersion>> {
        let c = self.conn.lock().unwrap();
        let mut st = c.prepare("SELECT id, body, created_at FROM prompt_versions ORDER BY id DESC")?;
        let rows = st
            .query_map([], |r| Ok(PromptVersion { version: r.get(0)?, body: r.get(1)?, created_at: r.get(2)? }))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    /// The run prompt with `{{sources}}`, `{{last_run}}` and `{{now}}` filled in, followed by the
    /// learning notes, pending feedback and the learn step (appended so custom prompts get them too).
    /// Agent-agnostic: the prompt itself asks the agent to pass its own name.
    pub fn render_prompt(&self) -> Result<String> {
        let template = self.get_prompt()?;
        let sources = prompt::render_sources(&self.list_sources()?);
        let last_run = match self.last_run_at()? {
            Some(ms) => Local.timestamp_millis_opt(ms).single().map(|d| d.to_rfc3339()).unwrap_or_default(),
            None => "the start of yesterday (first run)".into(),
        };
        let now = Local::now().format("%A %Y-%m-%d %H:%M").to_string();
        let filled = prompt::fill(&template, &[("sources", &sources), ("last_run", &last_run), ("now", &now)]);
        let settings = prompt::render_settings(self.get_order_by_priority()?, self.get_protect_tasks()?);
        let learning = prompt::render_learning(&self.list_learnings()?, &self.list_feedback()?);
        Ok(format!("{}\n\n{settings}{learning}", filled.trim_end()))
    }

    /// The prompt to run once in any agent to discover and save sources.
    pub fn render_discovery_prompt(&self) -> String {
        prompt::DEFAULT_DISCOVERY_PROMPT.to_string()
    }

    /// The prompt to paste into an agent's scheduler, with the cadence from `get_schedule`.
    pub fn render_setup_prompt(&self) -> Result<String> {
        let schedule = prompt::schedule_text(&self.get_schedule()?);
        Ok(prompt::fill(prompt::DEFAULT_SETUP_PROMPT, &[("schedule", &schedule)]))
    }

    pub fn get_schedule(&self) -> Result<ScheduleConfig> {
        Ok(self
            .get_setting("schedule".into())?
            .and_then(|j| serde_json::from_str(&j).ok())
            .unwrap_or_default())
    }

    pub fn set_schedule(&self, schedule: ScheduleConfig) -> Result<()> {
        if schedule.start_hour >= schedule.end_hour || schedule.end_hour > 24 || schedule.interval_minutes == 0 {
            return Err(TodoError::Invalid("schedule needs start < end <= 24 and a non-zero interval".into()));
        }
        self.set_setting("schedule".into(), serde_json::to_string(&schedule)?)?;
        notify::post_changed();
        Ok(())
    }

    /// Whether the open list is ordered by priority first (the default), so dragging a task into
    /// another priority's group changes its priority.
    pub fn get_order_by_priority(&self) -> Result<bool> {
        let c = self.conn.lock().unwrap();
        order_by_priority(&c)
    }

    pub fn set_order_by_priority(&self, on: bool) -> Result<()> {
        self.set_setting(ORDER_BY_PRIORITY.into(), if on { "1" } else { "0" }.into())?;
        notify::post_changed();
        Ok(())
    }

    /// When on, agents may not complete or delete tasks; only the user can. Off by default.
    pub fn get_protect_tasks(&self) -> Result<bool> {
        Ok(self.get_setting(PROTECT_TASKS.into())?.as_deref() == Some("1"))
    }

    pub fn set_protect_tasks(&self, on: bool) -> Result<()> {
        self.set_setting(PROTECT_TASKS.into(), if on { "1" } else { "0" }.into())?;
        notify::post_changed();
        Ok(())
    }

    pub fn get_setting(&self, key: String) -> Result<Option<String>> {
        let c = self.conn.lock().unwrap();
        setting_in(&c, &key)
    }

    pub fn set_setting(&self, key: String, value: String) -> Result<()> {
        let c = self.conn.lock().unwrap();
        c.execute(
            "INSERT INTO settings (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct PromptVersion {
    pub version: i64,
    pub body: String,
    pub created_at: i64,
}

use serde::{Deserialize, Serialize};

// ---------- internals ----------

impl TodoStore {
    /// Run `f` inside a transaction under a change group, then post the change notification.
    /// Agents pass `run_id` to group a whole run; otherwise each call is its own group.
    fn write<T>(
        &self,
        actor: &str,
        run_id: Option<String>,
        f: impl FnOnce(&Ctx) -> Result<T>,
        label: impl FnOnce(&T) -> String,
    ) -> Result<T> {
        let actor = if actor.trim().is_empty() { USER } else { actor };
        let mut c = self.conn.lock().unwrap();
        let tx = c.transaction()?;
        let now = now_ms();
        let (group, fresh) = match run_id.filter(|r| !r.is_empty()) {
            Some(r) => {
                let kind: Option<String> = tx.query_row("SELECT kind FROM groups WHERE id = ?1", [&r], |row| row.get(0)).optional()?;
                if kind.as_deref() != Some("run") {
                    return Err(TodoError::NotFound(format!("run {r}")));
                }
                (r, false)
            }
            None => {
                let id = format!("{}-{}", if is_user(actor) { "u" } else { "a" }, new_id());
                tx.execute(
                    "INSERT INTO groups (id, kind, actor, label, created_at, last_activity, finished_at) VALUES (?1, ?2, ?3, '', ?4, ?4, ?4)",
                    params![id, if is_user(actor) { "user" } else { "run" }, actor, now],
                )?;
                (id, true)
            }
        };
        Self::invalidate_redo(&tx)?;
        let cx = Ctx { c: &tx, group: group.clone(), actor: actor.to_string(), now };
        let out = f(&cx)?;
        if fresh {
            tx.execute("UPDATE groups SET label = ?1 WHERE id = ?2", params![label(&out), group])?;
        }
        tx.commit()?;
        drop(c);
        notify::post_changed();
        Ok(out)
    }

    fn write_system<T>(&self, actor: &str, f: impl FnOnce(&Ctx) -> Result<T>, label: impl FnOnce(&T) -> String) -> Result<T> {
        let mut c = self.conn.lock().unwrap();
        let tx = c.transaction()?;
        let now = now_ms();
        let id = format!("s-{}", new_id());
        tx.execute(
            "INSERT INTO groups (id, kind, actor, label, created_at, last_activity, finished_at) VALUES (?1, 'system', ?2, '', ?3, ?3, ?3)",
            params![id, actor, now],
        )?;
        let cx = Ctx { c: &tx, group: id.clone(), actor: actor.to_string(), now };
        let out = f(&cx)?;
        tx.execute("UPDATE groups SET label = ?1 WHERE id = ?2", params![label(&out), id])?;
        tx.commit()?;
        drop(c);
        notify::post_changed();
        Ok(out)
    }

    /// A new change makes earlier undone groups non-redoable.
    fn invalidate_redo(c: &Connection) -> Result<()> {
        c.execute("UPDATE events SET undone_at = NULL WHERE undone = 1 AND undone_at IS NOT NULL", [])?;
        // Feedback from changes that are undone and can no longer be redone is gone for good.
        c.execute("DELETE FROM feedback WHERE event_id IN (SELECT id FROM events WHERE undone = 1)", [])?;
        Ok(())
    }

    /// With protection on, only the user completes or deletes tasks.
    fn check_agent_may_remove(&self, actor: &str) -> Result<()> {
        if !actor.trim().is_empty() && !is_user(actor) && self.get_protect_tasks()? {
            return Err(TodoError::Invalid(
                "the user has turned off agents completing or deleting tasks: leave this task open and mention it in your finish_run summary".into(),
            ));
        }
        Ok(())
    }

    fn insert_new(cx: &Ctx, input: &TaskInput) -> Result<TodoItem> {
        if input.title.trim().is_empty() {
            return Err(TodoError::Invalid("title is required".into()));
        }
        let user = is_user(&cx.actor);
        let rank = if user { Self::min_rank(cx.c)? - 1.0 } else { Self::max_rank(cx.c)? + 1.0 };
        let t = TodoItem {
            id: new_id(),
            title: input.title.trim().to_string(),
            rank,
            priority: clamp_priority(input.priority),
            due: input.due.clone().filter(|s| !s.trim().is_empty()),
            status: "open".into(),
            summary: input.summary.clone().filter(|s| !s.trim().is_empty()),
            rationale: input.rationale.clone().filter(|s| !s.trim().is_empty()),
            source: input.source.clone().filter(|s| !s.trim().is_empty()),
            source_ref: input.source_ref.clone().filter(|s| !s.trim().is_empty()),
            source_url: input.source_url.clone().filter(|s| !s.trim().is_empty()),
            source_label: input.source_label.clone().filter(|s| !s.trim().is_empty()),
            excerpt: input.excerpt.clone().filter(|s| !s.trim().is_empty()),
            source_from: input.source_from.clone().filter(|s| !s.trim().is_empty()),
            unread: !user,
            last_move: 0,
            added_by: cx.actor.clone(),
            updated_by: cx.actor.clone(),
            user_ranked_at: None,
            done_at: None,
            archived_at: None,
            created_at: cx.now,
            updated_at: cx.now,
        };
        write_task(cx.c, &t)?;
        Ok(t)
    }

    /// Record feedback against the event just logged, so undo and redo carry it with the change.
    fn insert_feedback(cx: &Ctx, task: &TodoItem, kind: &str, reason: Option<&str>) -> Result<()> {
        let event_id = cx.c.last_insert_rowid();
        let excerpt = task.excerpt.as_ref().or(task.summary.as_ref()).map(|e| {
            let e = e.trim();
            if e.chars().count() > EXCERPT_CHARS {
                format!("{}…", e.chars().take(EXCERPT_CHARS).collect::<String>().trim_end())
            } else {
                e.to_string()
            }
        });
        // Completing a task again (after reopening it) replaces its earlier feedback.
        cx.c.execute("DELETE FROM feedback WHERE task_id = ?1 AND kind = ?2", params![task.id, kind])?;
        cx.c.execute(
            "INSERT INTO feedback (event_id, task_id, kind, title, source, source_from, excerpt, added_by, reason, task_created_at, created_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
            params![event_id, task.id, kind, task.title, task.source, task.source_from, excerpt, task.added_by, reason, task.created_at, cx.now],
        )?;
        Ok(())
    }

    fn feedback_in(c: &Connection) -> Result<Vec<Feedback>> {
        let mut st = c.prepare(LIVE_FEEDBACK)?;
        let rows = st
            .query_map([], |r| {
                Ok(Feedback {
                    id: r.get(0)?,
                    task_id: r.get(1)?,
                    kind: r.get(2)?,
                    title: r.get(3)?,
                    source: r.get(4)?,
                    source_from: r.get(5)?,
                    excerpt: r.get(6)?,
                    added_by: r.get(7)?,
                    reason: r.get(8)?,
                    task_created_at: r.get(9)?,
                    created_at: r.get(10)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    fn learnings_in(c: &Connection) -> Result<Vec<Learning>> {
        let mut st = c.prepare("SELECT id, text, author, position, updated_at FROM learnings ORDER BY position, id")?;
        let rows = st
            .query_map([], |r| Ok(Learning { id: r.get(0)?, text: r.get(1)?, author: r.get(2)?, position: r.get(3)?, updated_at: r.get(4)? }))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    fn check_note(text: &str) -> Result<String> {
        let text = text.trim();
        if text.is_empty() {
            return Err(TodoError::Invalid("a note can't be empty".into()));
        }
        if text.chars().count() > MAX_LEARNING_CHARS {
            return Err(TodoError::Invalid(format!("notes must be at most {MAX_LEARNING_CHARS} characters")));
        }
        Ok(text.to_string())
    }

    fn min_rank(c: &Connection) -> Result<f64> {
        Ok(c.query_row("SELECT COALESCE(MIN(rank), 1.0) FROM tasks WHERE status = 'open' AND archived_at IS NULL", [], |r| r.get(0))?)
    }

    fn max_rank(c: &Connection) -> Result<f64> {
        Ok(c.query_row("SELECT COALESCE(MAX(rank), 0.0) FROM tasks WHERE status = 'open' AND archived_at IS NULL", [], |r| r.get(0))?)
    }

    fn resolve(&self, c: &Connection, s: &str) -> Result<String> {
        Self::resolve_in(c, s)
    }

    fn resolve_in(c: &Connection, s: &str) -> Result<String> {
        let s = s.trim();
        if s.is_empty() {
            return Err(TodoError::Invalid("task id is required".into()));
        }
        if read_task(c, s)?.is_some() {
            return Ok(s.to_string());
        }
        if let Ok(pos) = s.parse::<usize>()
            && pos >= 1 && s.len() <= 3
                && let Some(t) = open_tasks(c)?.get(pos - 1) {
                    return Ok(t.id.clone());
                }
        let matches: Vec<String> = c
            .prepare("SELECT id FROM tasks WHERE id LIKE ?1 || '%' LIMIT 2")?
            .query_map([s], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        match matches.as_slice() {
            [one] => Ok(one.clone()),
            [] => Err(TodoError::NotFound(s.to_string())),
            _ => Err(TodoError::Invalid(format!("id prefix '{s}' is ambiguous"))),
        }
    }

    fn restore(c: &Connection, task_id: &str, json: Option<&str>) -> Result<()> {
        match json {
            None => {
                c.execute("DELETE FROM tasks WHERE id = ?1", [task_id])?;
            }
            Some(j) => {
                let t: TodoItem = serde_json::from_str(j)?;
                // A re-created task may collide on source_ref with a newer duplicate; drop the newer one.
                if let Some(r) = &t.source_ref {
                    c.execute("DELETE FROM tasks WHERE source_ref = ?1 AND id != ?2", params![r, t.id])?;
                }
                write_task(c, &t)?;
            }
        }
        Ok(())
    }

    fn group_label(c: &Connection, id: &str) -> Result<String> {
        let (kind, actor, label, created): (String, String, String, i64) = c
            .query_row("SELECT kind, actor, label, created_at FROM groups WHERE id = ?1", [id], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
            })
            .optional()?
            .ok_or_else(|| TodoError::NotFound(id.to_string()))?;
        Ok(if kind == "run" && label == actor {
            let t = Local.timestamp_millis_opt(created).single().map(|d| d.format("%H:%M").to_string()).unwrap_or_default();
            format!("{actor} run at {t}")
        } else {
            label
        })
    }

    fn row_to_event(r: &Row) -> rusqlite::Result<ChangeEvent> {
        Ok(ChangeEvent {
            id: r.get(0)?,
            group_id: r.get(1)?,
            actor: r.get(2)?,
            op: r.get(3)?,
            task_id: r.get(4)?,
            task_title: r.get(5)?,
            reason: r.get(6)?,
            ts: r.get(7)?,
            undone: r.get::<_, i64>(8)? != 0,
        })
    }

    fn load_group(c: &Connection, id: &str) -> Result<ChangeGroup> {
        let (kind, actor, label, created_at, finished_at, summary) = c
            .query_row(
                "SELECT kind, actor, label, created_at, finished_at, summary FROM groups WHERE id = ?1",
                [id],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get(3)?, r.get(4)?, r.get(5)?)),
            )
            .optional()?
            .ok_or_else(|| TodoError::NotFound(id.to_string()))?;
        let events = c
            .prepare("SELECT id, group_id, actor, op, task_id, task_title, reason, ts, undone FROM events WHERE group_id = ?1 AND op != 'rerank' ORDER BY id")?
            .query_map([id], Self::row_to_event)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let mut stats = RunStats { added: 0, updated: 0, done: 0, reordered: 0, deleted: 0 };
        for e in &events {
            match e.op.as_str() {
                "create" => stats.added += 1,
                "update" | "reopen" => stats.updated += 1,
                "done" => stats.done += 1,
                "reorder" | "move" => stats.reordered += 1,
                "delete" | "archive" => stats.deleted += 1,
                _ => {}
            }
        }
        let undone = !events.is_empty() && events.iter().all(|e| e.undone);
        Ok(ChangeGroup { id: id.to_string(), kind, actor, label, created_at, finished_at, summary, stats, undone, events })
    }

    fn sources_in(c: &Connection) -> Result<Vec<Source>> {
        let mut st = c.prepare("SELECT id, name, kind, instructions, enabled, position FROM sources ORDER BY position, name")?;
        let rows = st
            .query_map([], |r| {
                Ok(Source {
                    id: r.get(0)?,
                    name: r.get(1)?,
                    kind: r.get(2)?,
                    instructions: r.get(3)?,
                    enabled: r.get::<_, i64>(4)? != 0,
                    position: r.get(5)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }
}

#[cfg(test)]
mod tests;
