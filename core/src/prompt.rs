//! Prompts the app hands to agents. They are agent-agnostic: every prompt asks the agent to
//! pass its own name, which is stored only as the actor on the changes it makes.

use crate::model::{Feedback, Learning, ScheduleConfig, Source};

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
   permalink as source_url, a short source_label naming the link (for example
   "PR #19141" or "Sam's thread"), a short excerpt, who it came from, and a
   2-sentence summary. Follow what you've learned about my preferences
   (below) when deciding what is worth adding.
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

/// Rules that come from the user's settings in the app, appended to every run prompt.
pub fn render_settings(order_by_priority: bool, protect_tasks: bool) -> String {
    let mut out = String::new();
    if order_by_priority {
        out.push_str(
            "My list is ordered by priority first (P1, then P2, then P3) and by rank within each\n\
             priority. When I change a task's priority, that was deliberate: keep it unless something\n\
             new happened on the task.\n\n",
        );
    }
    if protect_tasks {
        out.push_str(
            "I've turned off agents completing or deleting tasks: complete_task and delete_task will\n\
             fail. Leave resolved tasks open, update them with what changed, and mention them in your\n\
             finish_run summary instead.\n\n",
        );
    }
    out
}

/// Most feedback items sent in one prompt; older ones wait for a later run.
pub const MAX_FEEDBACK_IN_PROMPT: usize = 30;

/// The learning section appended to every run prompt: the notes so far, feedback not yet folded
/// into them, and the step that asks the agent to update the notes before finishing.
pub fn render_learning(learnings: &[Learning], feedback: &[Feedback]) -> String {
    let mut out = String::from("What you've learned about my preferences:\n");
    if learnings.is_empty() {
        out.push_str("   (nothing yet)\n");
    }
    for l in learnings {
        let mine = if l.author == crate::USER { " (written by me)" } else { "" };
        out.push_str(&format!("   - {}{mine}\n", l.text));
    }
    if feedback.is_empty() {
        out.push_str(&format!(
            "\nNo new feedback on your tasks. If any note above is stale or duplicated, tidy the list\n\
             with save_learnings before finish_run (at most {} short notes); otherwise leave it.",
            crate::MAX_LEARNINGS
        ));
        return out;
    }
    out.push_str("\nNew feedback on tasks agents added (id: task, source, from):\n");
    for f in feedback.iter().take(MAX_FEEDBACK_IN_PROMPT) {
        let mut line = format!("   #{} {}: \"{}\"", f.id, if f.kind == "good" { "COMPLETED" } else { "REJECTED" }, f.title);
        let origin: Vec<&str> = [f.source.as_deref(), f.source_from.as_deref()].into_iter().flatten().collect();
        if !origin.is_empty() {
            line.push_str(&format!(" ({})", origin.join(", ")));
        }
        if let Some(e) = &f.excerpt {
            line.push_str(&format!(" excerpt: {}", e.replace('\n', " ")));
        }
        if let Some(r) = &f.reason {
            line.push_str(&format!(" | my reason: {r}"));
        }
        out.push_str(&line);
        out.push('\n');
    }
    if feedback.len() > MAX_FEEDBACK_IN_PROMPT {
        out.push_str(&format!("   (and {} older items for a later run)\n", feedback.len() - MAX_FEEDBACK_IN_PROMPT));
    }
    out.push_str(&format!(
        "\nBefore finish_run, update your notes: call save_learnings with the complete new list of\n\
         notes and the ids of the feedback above that you folded in. Completed tasks show what I\n\
         want; rejected ones show what to stop adding. Write general, reusable rules (which\n\
         sources, senders, channels or kinds of request matter or don't), not one note per task.\n\
         Merge overlapping notes and drop ones the feedback contradicts. Keep notes written by me\n\
         unless my own feedback clearly contradicts them. At most {} notes of one sentence each.",
        crate::MAX_LEARNINGS
    ));
    out
}

pub fn fill(template: &str, vars: &[(&str, &str)]) -> String {
    let mut out = template.to_string();
    for (k, v) in vars {
        out = out.replace(&format!("{{{{{k}}}}}"), v);
    }
    out
}
