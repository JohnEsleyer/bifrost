# Agent Prompt: Bifrost (Remote VPS Bridge)

Paste the block below into your agent's system prompt, `AGENTS.md`, `CLAUDE.md`,
or `.opencode/` instructions.

---

## Prompt text

> You have access to a remote VPS ("Asgard") through a local CLI tool called
> `bifrost`, which wraps SSH with connection multiplexing so commands return in
> milliseconds. To inspect, debug, or change the remote server, run commands
> locally in this exact form:
>
> ```
> bifrost "<remote command>"
> ```
>
> Rules:
>
> 1. **Always quote the whole remote command** in double quotes. That preserves
>    pipes, redirections, and `&&` for the remote shell.
> 2. `bifrost` is **non-interactive**: it never prompts. Never run commands that
>    require TTY input. Use `apt-get install -y`, `systemctl enable --now x`,
>    `docker rm -f x` — never the bare, prompting variants.
> 3. The **exit code is the remote exit code**. Check `$?` (or `$output` /
>    `$exit_code` in your tool call) before assuming a command succeeded.
> 4. `bifrost doctor` prints full diagnostics, `bifrost status` shows whether the
>    bridge is warm, `bifrost ping` measures latency.
> 5. If a remote command is a **single word** that collides with a bifrost
>    subcommand (`status`, `ping`, `open`, `reset`, `doctor`), prefix it with
>    `--`: `bifrost -- status`.
> 6. Prefer one composed command over many round trips:
>    `bifrost "systemctl is-active nginx && docker ps --format '{{.Names}}'"`.
>
> Examples:
>
> ```bash
> bifrost "cat /var/log/syslog | tail -n 50"
> bifrost "systemctl status nginx"
> bifrost "docker ps -a"
> bifrost "df -h && free -h"
> bifrost "grep -R 'api_key' /srv/app --include='*.py'"
> ```

---

## Compact one-liner variant

> You can run commands on the remote VPS with `bifrost "<cmd>"`. It is
> non-interactive (no prompts, use `-y`/`--now` flags), returns the remote exit
> code, and is safe to call repeatedly. Wrap complex commands in double quotes.

---

## Why this works for agents

| Agent pain point                | Bifrost answer                                          |
| ------------------------------- | ------------------------------------------------------- |
| 1–2 s handshake per command     | `ControlMaster` multiplexes over one socket → ~50 ms    |
| Tool hangs forever on a prompt  | `BatchMode yes` → immediate error, never a hang         |
| Can't tell if a command worked  | Exit code is propagated verbatim                        |
| Connection dies mid-session     | `ServerAliveInterval 15` / `CountMax 3` → detected in ~45 s |
| Host key prompt blocks the agent| `StrictHostKeyChecking accept-new` (trust on first use)  |
| Bridge goes cold between calls  | `ControlPersist 10m` keeps the socket warm              |

---

## Operational notes

- The bridge socket lives at `~/.ssh/bifrost-<user>@<host>:<port>` and is shared
  with plain `ssh asgard`, so manual terminal use and agent use share one
  connection.
- The socket dies after 10 idle minutes; the next `bifrost` call transparently
  re-opens it (paying the one-time handshake).
- `bifrost reset` closes the bridge deliberately (useful after changing
  firewall rules or SSH daemon config on the VPS).
