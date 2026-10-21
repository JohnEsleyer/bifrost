# 🌈 Bifrost

> **The zero-lag bridge connecting local AI agents to remote cloud servers.**

`bifrost` is a lightweight, non-interactive CLI gateway designed specifically for
autonomous AI agents (OpenCode, Claude Code, Cursor, Cline, OpenHands, …) to
inspect and control a remote VPS **without** terminal lag, timeouts, or
interactive-session freezing.

Named after the glowing rainbow bridge of Norse myth — and of Marvel — that
carries anyone instantly between **Midgard** (your local machine) and **Asgard**
(your VPS).

---

## ⚡ The problem it solves

Standard SSH is designed for humans, not for agents:

| Agent pain point                     | What actually happens                                  | Bifrost's answer                          |
| ------------------------------------ | ------------------------------------------------------- | ----------------------------------------- |
| **Interactive sessions freeze**      | The agent pauses to "think", the TCP session idles out   | `ControlMaster` keeps one socket alive     |
| **Prompt deadlocks**                 | `apt install` hangs forever waiting for a `y/n`          | `BatchMode yes` → fail fast, never hang    |
| **1–2 s handshake per command**      | Every `bifrost "docker ps"` re-negotiates the handshake   | Multiplexed socket → **~50 ms** round trip |
| **Messy output**                     | A PTY injects ANSI colour and escape codes into context  | `-T` disables PTY → pure stdout/stderr      |
| **Can't tell if it worked**          | Ambiguous success/failure                               | Remote **exit code is propagated verbatim** |
| **Host key prompt blocks the agent** | Agent waits forever on `Are you sure?`                   | `StrictHostKeyChecking accept-new`         |

---

## 🚀 Installation

### 1. Configure the remote target (`~/.ssh/config`)

Add a block for your VPS using the alias `asgard`:

```ssh-config
Host asgard
    HostName YOUR_VPS_IP_OR_DOMAIN
    User root
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes

    # Agent safeguards: never ask for interactive passwords/prompts
    BatchMode yes
    StrictHostKeyChecking accept-new

    # High-performance multiplexing
    ControlMaster auto
    ControlPath ~/.ssh/bifrost-%r@%h:%p
    ControlPersist 10m

    # Anti-lag keepalives
    ServerAliveInterval 15
    ServerAliveCountMax 3
```

> **Passwordless auth is required.** Run `ssh-copy-id root@YOUR_VPS_IP` if you
> haven't copied your public key yet.
>
> 💡 Don't want to edit `~/.ssh/config` by hand? The installer writes this
> block for you, idempotently and clearly marked:
>
> ```bash
> ./install.sh --ip YOUR_VPS_IP --user root
> ```

### 2. Install the CLI

**One-liner** — installs the CLI *and* writes the `~/.ssh/config` block:

```bash
curl -fsSL https://raw.githubusercontent.com/JohnEsleyer/bifrost/main/install.sh \
  | bash -s -- --ip YOUR_VPS_IP --user root
```

**Or from a clone:**

```bash
git clone https://github.com/JohnEsleyer/bifrost.git
cd bifrost
./install.sh --ip YOUR_VPS_IP --user root
```

**Or just the binary:**

```bash
sudo install -m 0755 bin/bifrost /usr/local/bin/bifrost
```

The installer:

- copies `bin/bifrost` into `/usr/local/bin` (falling back to `~/.local/bin`
  when you don't have passwordless sudo),
- writes the marked, re-runnable `Host asgard` block into `~/.ssh/config`,
- detects your private key and warns if the permissions are too open,
- tells you exactly what to do next.

> Re-running the installer is safe: it replaces its own block instead of
> stacking duplicates. Use `./uninstall.sh` to remove both the CLI and the
> config block.

### 3. Verify the connection

```bash
bifrost --ping
```

Expected output:

```text
Testing the Bifrost bridge to asgard...
Bridge active: asgard is reachable.
```

---

## 💻 Usage

```bash
# Check server state
bifrost "uname -a && uptime"

# Read application logs (bounded output!)
bifrost "docker logs backend --tail 50"

# Inspect files
bifrost "cat /etc/nginx/sites-available/default"

# Look for something specific
bifrost "grep -R 'api_key' /srv/app --include='*.py'"
```

### Commands

| Command                | Purpose                                                        |
| ---------------------- | -------------------------------------------------------------- |
| `bifrost "<cmd>"`     | Run a command on the VPS (the agent-facing interface)           |
| `bifrost -- "<cmd>"`  | Same, but escapes reserved words (`status`, `ping`, …)           |
| `bifrost --help`      | Full documentation + the agent operating rules                  |
| `bifrost --ping`      | One-shot reachability check                                     |
| `bifrost doctor`      | Full diagnostics: toolchain, auth, network, bridge, exit codes  |
| `bifrost status`      | Is the bridge warm? Where is the control socket?                |
| `bifrost ping [n]`    | Measure round-trip latency over the bridge                       |
| `bifrost open`        | Open the bridge and keep it warm                                |
| `bifrost reset`       | Close the bridge (drop the control socket)                      |

### Environment variables

| Variable                  | Default  | Meaning                                        |
| ------------------------- | -------- | ---------------------------------------------- |
| `BIFROST_HOST`            | `asgard` | Target ssh host alias                          |
| `BIFROST_TIMEOUT`         | `0`      | Hard timeout in seconds for remote commands    |
| `BIFROST_IDENTITY`        | auto     | Private key to use                             |
| `BIFROST_CONTROL_PERSIST` | `10m`    | How long the socket stays alive when idle      |
| `BIFROST_VERBOSE`         | `0`      | Verbose ssh logging                            |

---

## 🤖 Directives for AI agents

Paste this into your agent's system prompt, `AGENTS.md`, `CLAUDE.md`, or
`.cursorrules` — or just point the agent at [`AGENT_PROMPT.md`](AGENT_PROMPT.md):

```markdown
### Remote Server Operations (Bifrost)

You have access to a remote production VPS via a local CLI tool called `bifrost`.
You can use it via your bash/terminal execution tool.

**Command syntax:** `bifrost "<remote-shell-command>"`

**Rules of engagement:**
1. **Always wrap commands in double quotes:** `bifrost "systemctl status docker"`
2. **Strictly non-interactive:** you cannot answer prompts. Always supply
   auto-confirm flags (`apt-get install -y`, `docker rm -f`). Never run text
   editors (`vim`, `nano`) or pagers (`less`, `top`).
3. **Protect context size:** avoid dumping huge logs — limit with
   `head`, `tail`, `--tail 50`, `--no-pager`.
4. **Exit codes are preserved:** check the status before assuming success.
5. **Self-check tool:** run `bifrost --help` if you are unsure how to use it.
```

The same rules ship inside the binary itself, so an agent that runs
`bifrost --help` learns how to drive it without any extra documentation.

---

## 🧪 Tests

The suite is hermetic — it runs against a mock `ssh` binary, so it needs no
VPS and touches nothing in your real `~/.ssh/config`.

```bash
make test        # or: ./tests/test_bifrost.sh
make check       # bash -n syntax check
```

It verifies usage/exit codes, argument preservation (pipes, `&&`, quoting),
option injection, exit-code passthrough, config precedence, subcommand
escaping, the timeout guard and the doctor report.

---

## 🗂 Layout

```
bifrost/
├── bin/bifrost              # the CLI (single file, zero dependencies)
├── install.sh               # installs the CLI + writes the ssh config block
├── uninstall.sh             # removes both, idempotently
├── ssh/asgard.conf.template # the ssh config block, documented
├── tests/test_bifrost.sh    # hermetic test suite
├── AGENT_PROMPT.md          # ready-to-paste agent instructions
├── Makefile
└── README.md
```

---

## 🛡️ Design notes

- **Zero dependencies.** One POSIX-ish bash script and OpenSSH. No Python, no
  `jq`, no `tmux`.
- **Your config wins.** `bifrost` reads the *effective* ssh configuration
  (`ssh -G`) and only fills in options that are still at their weak OpenSSH
  default — it never overrides something you set deliberately.
- **Shared socket.** `bifrost` and plain `ssh asgard` use the same control
  path, so a human in a terminal and an agent in a loop share one connection.
- **Fail fast, never hang.** `BatchMode`, `ConnectTimeout` (15 s) and
  `ServerAlive*` (≈45 s to detect a dead peer) bound every failure mode.
  `BIFROST_TIMEOUT` adds an optional hard cap on top.
- **Trust on first use.** `StrictHostKeyChecking accept-new` records a new
  host key but still *refuses* a key that changed — no silent MITM downgrade.
- **No secrets in the repo.** The VPS IP, username and key path live in
  `~/.ssh/config`, never in this repository.

---

## 📄 License

MIT
