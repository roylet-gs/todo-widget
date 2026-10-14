use serde::{Deserialize, Serialize};

/// A task as stored and shown everywhere (app, CLI, MCP).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct TodoItem {
    pub id: String,
    pub title: String,
    /// Fractional sort key; lower comes first.
    pub rank: f64,
    /// 1 (highest) to 3.
    pub priority: u8,
    pub due: Option<String>,
    /// "open" or "done".
    pub status: String,
    pub summary: Option<String>,
    pub rationale: Option<String>,
    /// Human name of the source, e.g. "Slack".
    pub source: Option<String>,
    /// Stable external id used to de-duplicate agent upserts.
    pub source_ref: Option<String>,
    pub source_url: Option<String>,
    pub excerpt: Option<String>,
    /// Who/where the original came from, e.g. "Sam · #cde-ops · 8:40".
    pub source_from: Option<String>,
    pub unread: bool,
    /// Position change from the last agent reorder (+ = moved up). Cleared when seen.
    pub last_move: i32,
    pub added_by: String,
    pub updated_by: String,
    pub user_ranked_at: Option<i64>,
    pub done_at: Option<i64>,
    pub archived_at: Option<i64>,
    pub created_at: i64,
    pub updated_at: i64,
}

/// Fields an agent (or the user) supplies when creating or upserting a task.
#[derive(Debug, Clone, Default, Serialize, Deserialize, uniffi::Record)]
pub struct TaskInput {
    pub title: String,
    pub priority: Option<u8>,
    pub due: Option<String>,
    pub summary: Option<String>,
    pub rationale: Option<String>,
    pub source: Option<String>,
    pub source_ref: Option<String>,
    pub source_url: Option<String>,
    pub excerpt: Option<String>,
    pub source_from: Option<String>,
}

/// Partial update. `None` leaves a field unchanged; `Some("")` clears an optional text field.
#[derive(Debug, Clone, Default, Serialize, Deserialize, uniffi::Record)]
pub struct TaskPatch {
    pub title: Option<String>,
    pub priority: Option<u8>,
    pub due: Option<String>,
    pub summary: Option<String>,
    pub rationale: Option<String>,
    pub source: Option<String>,
    pub source_url: Option<String>,
    pub excerpt: Option<String>,
    pub source_from: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct Source {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub instructions: String,
    pub enabled: bool,
    pub position: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct RunStats {
    pub added: u32,
    pub updated: u32,
    pub done: u32,
    pub reordered: u32,
    pub deleted: u32,
}

/// A group of changes that undo treats as one unit: an agent run, a single user
/// action, or a system action such as the daily clear.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct ChangeGroup {
    pub id: String,
    /// "run", "user" or "system".
    pub kind: String,
    /// Agent name, "You", or "Daily clear".
    pub actor: String,
    pub label: String,
    pub created_at: i64,
    pub finished_at: Option<i64>,
    pub summary: Option<String>,
    pub stats: RunStats,
    /// True once every event in the group has been undone.
    pub undone: bool,
    pub events: Vec<ChangeEvent>,
}

#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct ChangeEvent {
    pub id: i64,
    pub group_id: String,
    pub actor: String,
    /// create, update, done, reopen, delete, reorder, move, archive, read
    pub op: String,
    pub task_id: String,
    pub task_title: String,
    pub reason: Option<String>,
    pub ts: i64,
    pub undone: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct UpsertResult {
    pub task: TodoItem,
    pub created: bool,
}
