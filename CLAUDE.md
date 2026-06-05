# Burnbar Development Notes

## Hook Output

Claude Code hooks communicate with the user through the JSON they write to stdout.

**`systemMessage`** — displays text directly to the user. Use this for any message the user must see (install notices, warnings). Does not go through Claude.

**`hookSpecificOutput.additionalContext`** — passes context to Claude, which may or may not relay it. Unreliable for critical messages.

Combine both when you need the user to see something and Claude to know about it:

```json
{
  "systemMessage": "Message shown directly to the user.",
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Context for Claude."
  }
}
```

## What Does Not Work

- **`stderr`** — suppressed by Claude Code, never reaches the user.
- **`/dev/tty`** — hooks run without a controlling terminal on macOS and Linux.

## Plugin vs. Cache

When launched with `--plugin-dir /path/to/plugin`, `CLAUDE_PLUGIN_ROOT` points to that directory and the hook there runs directly. Changes take effect immediately — no reinstall needed.

## Statusline

Claude Code reads `settings.json` at startup. There is no hot-reload. A restart is required after changing `statusLine`.
