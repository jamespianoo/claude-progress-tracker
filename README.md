# Claude Session Tracker

Menu-bar macOS app (Swift/SwiftUI, no Dock icon) showing every live Claude Code session: state, time in state,
total duration, time actually worked, and its subagents. Menu-bar title: `3 running  1h12`.

Read-only and offline: it only reads `~/.claude/sessions/*.json` (live-session registry) and
`~/.claude/projects/**.jsonl` (transcripts, tailed by byte offset, FSEvents + 10 s liveness poll).
Nothing is written to `~/.claude` and there is no network code. No hooks needed.

    ./build-app.sh && open build/ClaudeSessionTracker.app     # build and run
    swift test                                                # state-machine tests
    .build/debug/ClaudeSessionTracker --dump                  # print the current picture and exit

## How state is derived (verified against Claude Code 2.1.x transcripts)
- Session list: `~/.claude/sessions/<pid>.json` (sessionId, cwd, startedAt, name) filtered to live pids (start time checked against the record to avoid pid reuse). Same folder or worktree = separate rows (keyed by session id).
- Transcript: `projects/<cwd with non-alphanumerics → "-">/<sessionId>.jsonl`.
- Busy: a real user prompt or `tool_result` arrives, or an assistant record has `stop_reason` `tool_use`/null. Idle: assistant `stop_reason` other than `tool_use` (normally `end_turn`) or a `[Request interrupted…` user record. Working time = sum of busy intervals.
- Mid-turn with no writes for 15 min is shown as waiting (blocked on a permission prompt, say). Waiting for 10 min becomes idle.
- Subagents: `<sessionId>/subagents/agent-<id>.jsonl` plus `.meta.json` (description). Running = mid-turn and written in the last 5 min.

## Known limits
- A permission prompt shorter than 15 min still looks like "working" (the transcript has no explicit marker); hooks (`Notification`) would fix this.
- Subagent "failed" is not detectable from transcripts; shown as "stopped" if it went silent mid-turn.
- Background shell tasks and progress bars are not shown (no source in transcripts).
- A session that exits is shown as finished until the app restarts (or 1 h), then disappears.
