#!/bin/bash
# Installs the tracker hook: copies the script to ~/.claude-progress/hook.sh and adds hook entries to
# ~/.claude/settings.json (backup written next to it, diff shown). Safe to re-run. Remove with --uninstall.
set -euo pipefail
cd "$(dirname "$0")"
S=$HOME/.claude/settings.json
HOOK=$HOME/.claude-progress/hook.sh
mkdir -p "$HOME/.claude-progress"
[ -f "$S" ] || echo '{}' > "$S"
[ -f "$S.tracker-backup" ] || cp "$S" "$S.tracker-backup"   # keep the ORIGINAL backup across re-runs
if [ "${1:-}" != "--uninstall" ]; then cp hooks/claude-tracker-hook.sh "$HOOK"; chmod +x "$HOOK"; fi
python3 - "$S" "$HOOK" "${1:-}" <<'PY'
import json, sys
path, hook, mode = sys.argv[1:4]
s = json.load(open(path))
hooks = s.setdefault("hooks", {})
events = ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "SubagentStop", "SessionEnd"]
for ev in events:
    groups = hooks.get(ev, [])
    groups = [g for g in groups if not any(h.get("command") == hook for h in g.get("hooks", []))]
    if mode != "--uninstall":
        groups.append({"hooks": [{"type": "command", "command": hook}]})
    if groups: hooks[ev] = groups
    else: hooks.pop(ev, None)
if not hooks: s.pop("hooks", None)
open(path, "w").write(json.dumps(s, indent=2, ensure_ascii=False) + "\n")
PY
diff "$S.tracker-backup" "$S" || true
echo "Done. Backup: $S.tracker-backup. Restart running Claude Code sessions to pick up the hooks."
