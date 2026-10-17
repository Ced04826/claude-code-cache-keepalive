---
name: off
description: Turn cache-keepalive off for THIS session only, leaving other open sessions and all future sessions running. Use when the user wants to disable, close, or stop the prompt-cache keepalive monitor for the current session/task.
disable-model-invocation: true
---

Turn the keepalive off for the current session only, then report the result.

Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/cache-keepalive-ctl.sh" off
```

Then say briefly that **this** session's keepalive waiter is stopped and this
session id will not arm it again, while other and new sessions are unaffected.
To re-arm, run the same script with `on` (it arms again at the end of the next
turn); it also takes `off-all` (every session)
and `on-all`. For a per-project opt-out create
`<project>/.claude/cache-keepalive-off`.
