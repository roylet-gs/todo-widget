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
    /// Short name for the source link, e.g. "PR #19141"; the app falls back to "Open in <source>".
    #[serde(default)]
    pub source_label: Option<String>,
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
    /// Who completed it: "You" or the agent's name. `None` while open.
    #[serde(default)]
    pub done_by: Option<String>,
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
    pub source_label: Option<String>,
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
    pub source_label: Option<String>,
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

/// When the scheduled sync should run. Stored in the database so the CLI, the MCP server and
/// the app's built-in runner all agree, and rendered into the schedule prompt.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct ScheduleConfig {
    pub weekdays_only: bool,
    /// Local hour the window opens (0–23).
    pub start_hour: u8,
    /// Local hour the window closes (1–24), exclusive.
    pub end_hour: u8,
    pub interval_minutes: u32,
}

impl Default for ScheduleConfig {
    fn default() -> Self {
        Self { weekdays_only: true, start_hour: 9, end_hour: 17, interval_minutes: 60 }
    }
}

/// A signal about an agent-added task that the next run folds into its learning notes:
/// the user completed it ("good") or rejected it ("rejected", with an optional reason).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct Feedback {
    pub id: i64,
    pub task_id: String,
    /// "good" or "rejected".
    pub kind: String,
    pub title: String,
    pub source: Option<String>,
    pub source_from: Option<String>,
    pub excerpt: Option<String>,
    /// The agent that added the task.
    pub added_by: String,
    pub reason: Option<String>,
    pub task_created_at: i64,
    pub created_at: i64,
}

/// A short note about the user's preferences, curated by agents from feedback and editable by the user.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct Learning {
    pub id: i64,
    pub text: String,
    /// Agent name, or "You" for notes the user wrote or edited.
    pub author: String,
    pub position: i64,
    pub updated_at: i64,
}
