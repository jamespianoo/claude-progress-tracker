#!/bin/bash
# Claude Code hook -> Claude Session Tracker. Reads the hook JSON on stdin and records the latest
# event per session in ~/.claude-progress/events/<session_id>.json (the tracker app reads it).
# Writes only to ~/.claude-progress; never touches ~/.claude. Always exits 0 so it can't block Claude.
INPUT=$(cat)
HOOK_INPUT="$INPUT" python3 - <<'PY' 2>/dev/null
import json, sys, os, time
try:
    d = json.loads(os.environ["HOOK_INPUT"])
except Exception:
    sys.exit(0)
sid = d.get("session_id")
if not sid:
    sys.exit(0)
out = os.path.expanduser("~/.claude-progress/events")
os.makedirs(out, exist_ok=True)
rec = {"session_id": sid, "cwd": d.get("cwd", ""), "event": d.get("hook_event_name", ""),
       "message": d.get("message", ""), "updated": time.time()}
tmp = os.path.join(out, sid + ".tmp")
with open(tmp, "w") as f:
    json.dump(rec, f)
os.replace(tmp, os.path.join(out, sid + ".json"))
PY
exit 0
