use super::*;

fn store() -> (tempfile::TempDir, Arc<TodoStore>) {
    // SAFETY: tests run in one process; the variable only disables a side effect.
    unsafe { std::env::set_var("TODO_NO_NOTIFY", "1") };
    let dir = tempfile::tempdir().unwrap();
    let s = TodoStore::open(Some(dir.path().join("t.db").to_string_lossy().into())).unwrap();
    (dir, s)
}

fn input(title: &str, source_ref: Option<&str>) -> TaskInput {
    TaskInput { title: title.into(), source_ref: source_ref.map(Into::into), ..Default::default() }
}

fn titles(s: &TodoStore) -> Vec<String> {
    s.list_tasks(false).unwrap().into_iter().map(|t| t.title).collect()
}

#[test]
fn user_adds_go_to_top_agent_adds_to_bottom_and_unread() {
    let (_d, s) = store();
    s.add_task(input("a", None), USER.into(), None).unwrap();
    s.add_task(input("b", None), USER.into(), None).unwrap();
    let c = s.add_task(input("c", None), "Claude".into(), None).unwrap();
    assert_eq!(titles(&s), ["b", "a", "c"]);
    assert!(c.unread);
    assert!(!s.list_tasks(false).unwrap()[0].unread);
}

#[test]
fn upsert_dedupes_on_source_ref() {
    let (_d, s) = store();
    let run = s.start_run("Claude".into()).unwrap();
    let r1 = s.upsert_task(input("Reply to Sam", Some("slack:1")), "Claude".into(), Some(run.clone())).unwrap();
    assert!(r1.created);
    let mut again = input("Reply to Sam today", Some("slack:1"));
    again.summary = Some("needs answer".into());
    let r2 = s.upsert_task(again, "Claude".into(), Some(run.clone())).unwrap();
    assert!(!r2.created);
    assert_eq!(r2.task.id, r1.task.id);
    assert_eq!(s.list_tasks(false).unwrap().len(), 1);
    let g = s.finish_run(run, Some("done".into())).unwrap();
    assert_eq!(g.stats.added, 1);
    assert_eq!(g.stats.updated, 1);
}

#[test]
fn undo_whole_run_and_redo() {
    let (_d, s) = store();
    s.add_task(input("mine", None), USER.into(), None).unwrap();
    let run = s.start_run("Hermes".into()).unwrap();
    s.upsert_task(input("x", Some("r:x")), "Hermes".into(), Some(run.clone())).unwrap();
    s.upsert_task(input("y", Some("r:y")), "Hermes".into(), Some(run.clone())).unwrap();
    let mine = s.list_tasks(false).unwrap()[0].id.clone();
    s.set_done(mine.clone(), true, "Hermes".into(), Some(run.clone()), Some("resolved".into())).unwrap();
    s.finish_run(run.clone(), None).unwrap();
    assert_eq!(titles(&s), ["x", "y"]);

    s.undo_group(run.clone()).unwrap();
    assert_eq!(titles(&s), ["mine"]);
    assert!(s.get_group(run.clone()).unwrap().undone);

    assert!(s.redo_last().unwrap().is_some());
    assert_eq!(titles(&s), ["x", "y"]);
}

#[test]
fn undo_last_is_per_user_action_and_new_change_blocks_redo() {
    let (_d, s) = store();
    let a = s.add_task(input("a", None), USER.into(), None).unwrap();
    s.set_done(a.id.clone(), true, USER.into(), None, None).unwrap();
    assert_eq!(s.undo_last().unwrap().unwrap(), "Completed “a”");
    assert_eq!(titles(&s), ["a"]);
    s.add_task(input("b", None), USER.into(), None).unwrap();
    assert!(s.redo_last().unwrap().is_none());
}

#[test]
fn reorder_sets_moves_rationales_and_keeps_unlisted_after() {
    let (_d, s) = store();
    for t in ["a", "b", "c", "d"] {
        s.add_task(input(t, None), "Claude".into(), None).unwrap();
    }
    let ids: Vec<String> = s.list_tasks(false).unwrap().into_iter().map(|t| t.id).collect();
    let mut why = HashMap::new();
    why.insert(ids[2].clone(), "blocks Sam".to_string());
    let moved = s.reorder(vec![ids[2].clone(), ids[0].clone()], why, "Claude".into(), None).unwrap();
    assert_eq!(titles(&s), ["c", "a", "b", "d"]);
    assert_eq!(moved, 3);
    let c = s.get_task(ids[2].clone()).unwrap();
    assert_eq!(c.last_move, 2);
    assert_eq!(c.rationale.as_deref(), Some("blocks Sam"));
    s.undo_last().unwrap();
    assert_eq!(titles(&s), ["a", "b", "c", "d"]);
}

#[test]
fn user_move_marks_user_ranked() {
    let (_d, s) = store();
    for t in ["a", "b", "c"] {
        s.add_task(input(t, None), "Claude".into(), None).unwrap();
    }
    let c = s.list_tasks(false).unwrap()[2].id.clone();
    let t = s.move_task(c.clone(), 0).unwrap();
    assert!(t.user_ranked_at.is_some());
    assert_eq!(titles(&s), ["c", "a", "b"]);
    s.move_task(c, 1).unwrap();
    assert_eq!(titles(&s), ["a", "c", "b"]);
}

#[test]
fn positions_and_prefixes_resolve() {
    let (_d, s) = store();
    let a = s.add_task(input("a", None), USER.into(), None).unwrap();
    assert_eq!(s.resolve_id("1".into()).unwrap(), a.id);
    assert_eq!(s.resolve_id(a.id[..6].into()).unwrap(), a.id);
    assert!(s.resolve_id("zzzzzz".into()).is_err());
}

#[test]
fn archive_done_and_restore_via_undo() {
    let (_d, s) = store();
    let a = s.add_task(input("a", None), USER.into(), None).unwrap();
    s.set_done(a.id.clone(), true, USER.into(), None, None).unwrap();
    assert_eq!(s.list_tasks(true).unwrap().len(), 1);
    assert_eq!(s.archive_done(now_ms() + 1).unwrap(), 1);
    assert!(s.list_tasks(true).unwrap().is_empty());
    let h = s.history(10).unwrap();
    assert_eq!(h[0].actor, "Daily clear");
    s.undo_group(h[0].id.clone()).unwrap();
    assert_eq!(s.list_tasks(true).unwrap().len(), 1);
}

#[test]
fn delete_then_undo_restores() {
    let (_d, s) = store();
    let a = s.add_task(input("a", Some("ref")), "Claude".into(), None).unwrap();
    s.delete_task(a.id.clone(), USER.into(), None, None).unwrap();
    assert!(titles(&s).is_empty());
    s.undo_last().unwrap();
    assert_eq!(titles(&s), ["a"]);
}

#[test]
fn prompt_renders_sources_and_versions() {
    let (_d, s) = store();
    s.save_source(Source { id: String::new(), name: "Slack".into(), kind: "Messages".into(), instructions: "DMs".into(), enabled: true, position: 0 }).unwrap();
    s.save_source(Source { id: String::new(), name: "Off".into(), kind: "Email".into(), instructions: String::new(), enabled: false, position: 0 }).unwrap();
    let p = s.render_prompt().unwrap();
    assert!(p.contains("- Slack (Messages): DMs"));
    assert!(!p.contains("Off"));
    assert!(p.contains("agent set to your own name"));
    assert!(!p.contains("{{"), "unfilled placeholder in: {p}");
    s.set_prompt("custom {{now}}".into()).unwrap();
    assert!(s.render_prompt().unwrap().starts_with("custom "));
    assert_eq!(s.prompt_versions().unwrap().len(), 1);
}

#[test]
fn agent_managed_sources_by_name() {
    let (_d, s) = store();
    let a = s.upsert_source_by_name("Slack".into(), "Messages".into(), "DMs".into(), true).unwrap();
    let b = s.upsert_source_by_name("slack".into(), "Messages".into(), "DMs and #team".into(), true).unwrap();
    assert_eq!(a.id, b.id, "same name in different case updates the existing source");
    s.upsert_source_by_name("Gmail".into(), "Email".into(), "".into(), true).unwrap();
    let names: Vec<String> = s.list_sources().unwrap().into_iter().map(|x| x.name).collect();
    assert_eq!(names, ["slack", "Gmail"]);
    assert!(s.remove_source_by_name("SLACK".into()).unwrap());
    assert!(!s.remove_source_by_name("nope".into()).unwrap());
    assert_eq!(s.list_sources().unwrap().len(), 1);
    assert!(s.upsert_source_by_name("  ".into(), "Other".into(), "".into(), true).is_err());
}

#[test]
fn schedule_and_discovery_prompts_are_agent_agnostic() {
    let (_d, s) = store();
    let p = s.render_setup_prompt().unwrap();
    assert!(p.contains("every hour, on the hour, Monday to Friday from 09:00 to 17:00"), "{p}");
    assert!(p.contains("get_instructions") && p.contains("own name") && p.contains("never reuse"));
    assert!(!p.contains("{{"), "unfilled placeholder in: {p}");
    s.set_schedule(ScheduleConfig { weekdays_only: false, start_hour: 8, end_hour: 18, interval_minutes: 120 }).unwrap();
    let p = s.render_setup_prompt().unwrap();
    assert!(p.contains("every 2 hours, on the hour, every day from 08:00 to 18:00"), "{p}");
    assert!(s.set_schedule(ScheduleConfig { weekdays_only: true, start_hour: 18, end_hour: 9, interval_minutes: 60 }).is_err());
    let d = s.render_discovery_prompt();
    assert!(d.contains("save_source") && d.contains("remove_source") && d.contains("your own name"));
    assert!(!d.contains("{{"));
}

#[test]
fn run_without_agent_name_is_recorded_as_agent() {
    let (_d, s) = store();
    let r = s.start_run("  ".into()).unwrap();
    assert_eq!(s.get_group(r).unwrap().actor, "Agent");
}

#[test]
fn runs_since_and_stale_close() {
    let (_d, s) = store();
    let r = s.start_run("Claude".into()).unwrap();
    s.add_task(input("a", None), "Claude".into(), Some(r.clone())).unwrap();
    assert_eq!(s.runs_since(0).unwrap().len(), 1);
    assert_eq!(s.close_stale_runs(-1).unwrap(), 1);
    assert!(s.get_group(r).unwrap().finished_at.is_some());
}

#[test]
fn reset_keeps_or_erases_tasks() {
    let (_d, s) = store();
    s.add_task(input("a", None), USER.into(), None).unwrap();
    s.save_source(Source { id: String::new(), name: "Slack".into(), kind: "Messages".into(), instructions: String::new(), enabled: true, position: 0 }).unwrap();
    s.set_prompt("custom".into()).unwrap();
    s.reset(false).unwrap();
    assert!(s.list_sources().unwrap().is_empty());
    assert_eq!(s.get_prompt().unwrap(), prompt::DEFAULT_PROMPT);
    assert_eq!(titles(&s), ["a"]);
    s.reset(true).unwrap();
    assert!(titles(&s).is_empty());
    assert!(s.history(10).unwrap().is_empty());
}
