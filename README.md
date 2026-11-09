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

## Bar source priority
Progress file, then counts the session reports ("N of M"), then **time** (elapsed out of elapsed + the time left the session itself stated, labelled `time`), then the step list, then agent counts, task output and worker bars. The time bar exists because some sessions have one long first step (e.g. an agent on a server) that leaves a step count at 0 for hours.

## States and ETA
- **working**: mid-turn. **running tasks**: background commands, agents or a progress feed with live processes behind them.
- **paused** (yellow pause icon): unfinished work (open background command or progress feed) but no live process doing it, e.g. workers were killed. Shown with how long it has been paused and its frozen progress.
- **needs you**: Claude is asking something (needs the hook). Everything else idle is under the "Idle" dropdown.
- **ETA** (top right, `time left (finish clock)`) works the same for every session, in this order:
  1. **What the session itself says.** The latest message that states an estimate is read ("about 5 to 6 hours from now", "ETA about 4½–5 hours", "finishing around 20:40", "roughly 01:00–01:30") and counted down from when it was said. Explicit "from now/left/remaining/in N hours" statements win over looser "about N hours", then the latest finish is taken, since an overall completion is later than its milestones. Clock times are only used for local sessions (a server's time zone is unknown). Quoted text and `>` quotes are ignored, estimates already in the past are dropped, and the estimate is kept even if later messages have none.
  2. **A measured rate** for progress feeds, counted only over time workers were alive, for the current stage only (later stages show "queued").
  3. **A step-pace guess, shown with `~`**, for sessions doing their own steps: how long the completed steps of the current plan took, applied to the steps left. Only when a completion was seen recently (last 3 h), the plan was not replaced, and no workers or background tasks are running (then the remaining step is usually the long one). Rough by nature, hence the `~`.
  4. **The pace of a count the session reports** ("4 of 11", then "9 of 11" in a later message): items per second between its messages, applied to what is left, shown with `~`. Needs two readings 5+ minutes apart with gaps under 3 h (longer gaps are mostly idle time).
  5. Otherwise **"no ETA"**. Bars from step lists and agent counts are percentages only.

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

## Getting an ETA out of every session
A session only gets an ETA if it says something the tracker can read. Sessions that just do short interactive tasks, or never state timings, will show "no ETA" whichever server they run on. To make any session report in a readable way, add this to its instructions (e.g. a `CLAUDE.md`), or paste it at the start of a long job:

> For any task that will take more than a few minutes, keep me posted in your status messages with (1) a count such as "9 of 40 pages done" and (2) a finish estimate in plain words such as "about 2 hours from now" or "finishing around 21:30". Update both whenever they change. Keep the same wording for the count each time.
