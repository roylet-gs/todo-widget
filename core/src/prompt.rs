//! Prompts the app hands to agents. They are agent-agnostic: every prompt asks the agent to
//! pass its own name, which is stored only as the actor on the changes it makes.

use crate::model::{ScheduleConfig, Source};

/// The run prompt every agent receives through `get_instructions` on each scheduled run.
pub const DEFAULT_PROMPT: &str = r#"You maintain my todo list using the "todo" MCP tools. Work in this order:

1. Call start_run with agent set to your own name (for example "Claude Desktop" or
   "Hermes"), and keep the run_id for every write below.
2. Check each source below for anything new since {{last_run}} that needs
   action from me: direct asks, review requests, deadlines, meeting prep.
{{sources}}
3. Call get_changes_since({{last_run}}) and respect my edits. Never reopen
   a task I completed and never re-add one I deleted.
4. For each actionable item, call upsert_task with a stable source_ref, the
   permalink as source_url, a short excerpt, who it came from, and a
   2-sentence summary.
5. Call complete_task for tasks the source shows are resolved, with a reason.
6. Rank all open tasks with reorder_tasks, using these rules:
   - Anything blocking another person comes first.
   - Then hard deadlines in the next 48 hours.
   - Then requests from my manager or customers.
   - Then quick wins (under 15 minutes).
   - Everything else last, oldest first.
   Tasks marked user_ranked were placed by me: keep them where they are
   unless something new happened on that task, and say why if you move one.
   Give a one-line rationale for each position.
7. finish_run with a one-line summary of what changed.

It is now {{now}}."#;

/// Run once, interactively, to work out with the user which sources the scheduled sync should check.
pub const DEFAULT_DISCOVERY_PROMPT: &str = r#"Help me set up the sources for my todo list. You'll use the "todo" MCP tools.

1. Call start_run with agent set to your own name (for example "Claude Desktop"
   or "Hermes"), then call list_sources to see what is already configured.
2. Look at the connectors and tools you actually have access to (for example
   Slack, Gmail, Outlook, Linear, Jira, GitHub, Google Calendar, Notion). Only
   suggest sources you can really read.
3. Ask me, one source at a time, whether to include it and what counts as
   something I need to act on there: who or which channels, projects, repos,
   labels or calendars matter, and what to ignore. Keep the questions short.
4. For each source I want, call save_source with a short name, a kind
   (Messages, Email, Issues, Code review, Calendar, Docs or Other) and plain
   English instructions that a future scheduled run can follow on its own.
   Saving an existing name updates it. Call remove_source for any source I
   no longer want.
5. When we're done, call finish_run with a one-line summary, then show me the
   final list of sources.

Don't add or change any tasks during this conversation."#;

/// Pasted into an agent's scheduler to create the recurring sync.
pub const DEFAULT_SETUP_PROMPT: &str = r#"Create a recurring scheduled task named "Todo sync".

Schedule: {{schedule}}

Each time it runs, the task should do this:
  1. Use the "todo" MCP server. Call get_instructions with agent set to your
     own name (for example "Claude Desktop" or "Hermes").
  2. Follow the prompt it returns exactly. Fetch it fresh on every run and
     never reuse an earlier copy: the sources and ranking rules are managed
     in the Todo Widget app and change over time.
  3. Always call finish_run at the end, even if a source fails, and mention
     any failure in the summary."#;

/// Human-readable cadence for the schedule prompt, e.g.
/// "every hour, on the hour, Monday to Friday from 09:00 to 17:00 local time. Skip runs outside these hours."
pub fn schedule_text(c: &ScheduleConfig) -> String {
    let every = match c.interval_minutes {
        60 => "every hour, on the hour".to_string(),
        m if m % 60 == 0 => format!("every {} hours, on the hour", m / 60),
        m => format!("every {m} minutes"),
    };
    let days = if c.weekdays_only { "Monday to Friday" } else { "every day" };
    format!(
        "{every}, {days} from {:02}:00 to {:02}:00 local time. Skip runs outside these hours.",
        c.start_hour, c.end_hour
    )
}

pub fn render_sources(sources: &[Source]) -> String {
    let enabled: Vec<_> = sources.iter().filter(|s| s.enabled).collect();
    if enabled.is_empty() {
        return "   (no sources configured yet: use whatever messaging and work tools you can access)".into();
    }
    enabled
        .iter()
        .map(|s| {
            let instr = s.instructions.trim();
            if instr.is_empty() {
                format!("   - {} ({})", s.name, s.kind)
            } else {
                format!("   - {} ({}): {}", s.name, s.kind, instr)
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn fill(template: &str, vars: &[(&str, &str)]) -> String {
    let mut out = template.to_string();
    for (k, v) in vars {
        out = out.replace(&format!("{{{{{k}}}}}"), v);
    }
    out
}
