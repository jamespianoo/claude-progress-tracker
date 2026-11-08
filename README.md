# Claude Session Tracker

Menu-bar macOS app (Swift/SwiftUI, no Dock icon). The icon is the Claude mark plus the number of sessions that are running.
The popover is deliberately simple: each active session (working, running background tasks/agents, or asking you
something) shows its name, elapsed time and one progress bar with ETA. Everything idle sits in a collapsed
"Idle (n)" dropdown at the bottom.

Read-only and offline: it only reads `~/.claude/sessions/*.json` (live-session registry) and
`~/.claude/projects/**.jsonl` (transcripts, tailed by byte offset, FSEvents + 10 s liveness poll).
Nothing is written to `~/.claude` and there is no network code. No hooks needed.

    ./install-hooks.sh                                        # optional: Claude Code hooks (see below)
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

## Popover sections
Each running session lists only the sections that apply: **Now** (its latest tool call), **Steps** (the unfinished items of its step list), **Workers** (processes, with bars where progress is known), **Background tasks** and **Agents**. Idle sessions are under a collapsible "Idle (n)" row at the bottom (state is remembered).
On first open only the last 24 MB of each transcript is read (some are hundreds of MB), then new lines are tailed, so start-up is quick and start time is approximate for very long sessions.

## States and ETA
- **working**: mid-turn. **running tasks**: background commands, agents or a progress feed with live processes behind them.
- **paused** (yellow pause icon): unfinished work (open background command or progress feed) but no live process doing it, e.g. workers were killed. Shown with how long it has been paused and its frozen progress.
- **needs you**: Claude is asking something (needs the hook). Everything else idle is under the "Idle" dropdown.
- **ETA** (top right, `time left (finish clock)`) appears only when a rate was measured: for progress feeds, the rate over the last ~30 min of observed progress (not since start, which would count paused time). Step-list and agent-count bars show percentage only, because steps are not equal in length. Without 3 min of observed progress there is no ETA rather than a guess.

## Sub-processes
Under each active session the app lists what it is running: processes whose working directory is inside the
session's folder (this catches detached `nohup`/`caffeinate` workers that are not children of Claude) plus
descendants of the session process, reduced to the top-level work (no wrapper shells, helpers or Chrome processes),
each with its elapsed time. If a progress feed's `now` lines look like `oxford-circus_x  frame 203/720`, the matching
process gets a bar. Found with `ps` + `lsof` every ~10 s, only while a session is active.

## Progress bars and ETA
A bar needs a source. The tracker reads two, both outside `~/.claude`:
1. **Task output**: a background Bash command whose own output contains `NN%` or `a / b`.
2. **Progress feed**: any script can write `~/.claude-progress/<name>.json` (refresh at least every 2 min; older is ignored):

       {"title":"RAILS RE-BAKE","cwd":"/path/of/the/claude/session","started":1794152240,"updated":1794156500,
        "stages":[{"name":"follow","done":61,"total":140},{"name":"cab","done":0,"total":279}]}

   It attaches to the session whose working directory equals `cwd`. ETA = remaining items / (items done since `started`).
   Without a source the row shows an indeterminate bar.

## Claude Code hooks (optional, more precise "needs you")
Transcripts cannot tell that Claude is blocked on a permission prompt. Hooks can: `./install-hooks.sh` copies
`hooks/claude-tracker-hook.sh` to `~/.claude-progress/hook.sh` and adds it to `~/.claude/settings.json` for
`SessionStart`, `UserPromptSubmit`, `Notification`, `Stop`, `SubagentStop` and `SessionEnd`. Each event writes
`~/.claude-progress/events/<session_id>.json`; a `Notification` after the last transcript activity shows the session
as "needs you". It backs up your settings first (`settings.json.tracker-backup`), prints the diff, is safe to re-run
and `./install-hooks.sh --uninstall` removes it. Restart running sessions to pick the hooks up.

### Prompt to set this up in any Claude Code session
Paste this into Claude Code to have it wire up the same thing (for example on another machine or after cloning):

> Set up the Claude Session Tracker integration from this repo. Run `./install-hooks.sh` and show me the diff of
> `~/.claude/settings.json` it prints. Then build and launch the app with `./build-app.sh && open build/ClaudeSessionTracker.app`.
> If I have a long-running script with its own progress display, add a few lines so each refresh writes
> `~/.claude-progress/<name>.json` in the format described in the README ("Progress bars and ETA"), with `cwd` set to
> this session's working directory, then tell me to restart the script. Do not write anything inside `~/.claude`
> other than the hook entries in `settings.json`, and do not send any data off this machine.
