use crate::model::Source;

/// The run prompt every agent receives through `get_instructions`.
pub const DEFAULT_PROMPT: &str = r#"You maintain my todo list using the "todo" MCP tools. Work in this order:

1. Call start_run(agent="{{agent}}") and keep the run_id for every write below.
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

/// The short prompt pasted into an external agent's schedule builder.
pub const DEFAULT_SETUP_PROMPT: &str = r#"Create a scheduled task named "Todo sync".
Schedule: {{schedule}}.
Task prompt:
  Use the "todo" MCP server. Call get_instructions with agent="{{agent}}"
  and follow the prompt it returns exactly.
  If a source connector fails, still call finish_run and mention the failure."#;

pub const DEFAULT_SCHEDULE: &str = "weekdays, every 2 hours from 08:00 to 18:00";

pub fn render_sources(sources: &[Source]) -> String {
    let enabled: Vec<_> = sources.iter().filter(|s| s.enabled).collect();
    if enabled.is_empty() {
        return "   (no sources configured: use whatever messaging and work tools you can access)".into();
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
