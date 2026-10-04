# Install

Part of the claude-timestamp documentation. Start at the [README](../README.md).

## Requirements

`jq`, and `bash`. That is the whole list. If `jq` is missing the plugin says so
once and then does nothing, rather than failing quietly.

```text
macOS           brew install jq
Debian/Ubuntu   sudo apt-get install jq
Windows         winget install jqlang.jq
```

If you use Claude Code in WSL and the desktop app on Windows, those count as two
machines here and each needs its own copy. See [Windows: WSL and the desktop app
are separate installs](#windows-wsl-and-the-desktop-app-are-separate-installs).

## Claude Code

```bash
claude plugin marketplace add https://github.com/AraneaDev/aranea-marketplace
claude plugin install claude-timestamp@aranea
```

Hooks are bound when a session starts, so start a new session before markers
appear. An already-running session will not pick the plugin up.

## Codex compatibility

The repository is its own Codex marketplace, named `aranea`, and carries the
Codex manifest in `.codex-plugin/plugin.json`. Installed in Codex, the plugin's
lifecycle hooks provide the prompt send time, slow-tool and heartbeat notes,
resumption and compaction context, the turn timeline, command memory and
end-of-session totals. See the official [Codex hooks
documentation](https://learn.chatgpt.com/docs/hooks).

### Install in Codex CLI

```bash
codex plugin marketplace add AraneaDev/claude-timestamp
codex plugin add claude-timestamp@aranea
```

Start a new session afterwards. Codex asks you to review and trust the plugin's
hooks before they run, in the startup prompt or in `/hooks`; that is a Codex
safety step, not a plugin setting, and until you trust them nothing is
recorded. In a Codex session, `/plugins` does the same install from a menu.

The Claude marketplace URL under [Claude Code](#claude-code) above is a Claude
Code feed; Codex reads its own format, which this repository provides.

Codex tool timing is measured from `PreToolUse` to `PostToolUse`, because its
payload does not include Claude Code's `duration_ms`. Those measurements have
whole-second precision and include the local hook lifecycle.

The `time-awareness` and `timestamps` skills are bundled for Codex. When using
the repository directly, Codex also reads the root [AGENTS.md](../AGENTS.md), and
the CLI can show or change settings with the same validated configuration:

```bash
bash "$(git rev-parse --show-toplevel)/hooks/scripts/setup.sh" --show
bash "$(git rev-parse --show-toplevel)/hooks/scripts/setup.sh" --tz=Europe/Amsterdam
```

The `/timestamps` command remains the Claude Code interface. Both clients use
the same `~/.claude/claude-timestamp.conf` and history file, while active call
state stays isolated by session.

## Windows: WSL and the desktop app are separate installs

Claude Code in WSL and the desktop app on Windows do not share a home directory.
WSL has `~/.claude`, Windows has `C:\Users\<you>\.claude`. Install the plugin
on one side and the other side has nothing installed, and the same goes for `jq`
and for the settings you picked with `/timestamps`. On macOS and Linux there is
one home directory, so one install covers everything.

Install both, on each side you actually use.

In WSL, on Debian or Ubuntu:

```bash
sudo apt-get install jq
claude plugin marketplace add https://github.com/AraneaDev/aranea-marketplace
claude plugin install claude-timestamp@aranea
```

On Windows:

```powershell
winget install jqlang.jq
claude plugin marketplace add https://github.com/AraneaDev/aranea-marketplace
claude plugin install claude-timestamp@aranea
```

The desktop app's plugin browser lists what your configured marketplaces
already offer and cannot add one, so the marketplace step is what makes the
plugin appear there at all. The commands above need the standalone CLI, which
is a separate installation from the desktop app. Without it, type the same two
steps as slash commands in a **Local** session in the Code tab, which needs
nothing else installed:

```text
/plugin marketplace add https://github.com/AraneaDev/aranea-marketplace
/plugin install claude-timestamp@aranea
```

Restart the desktop app after installing `jq`. It reads Windows user and system
environment variables when it launches and never reads your PowerShell profile,
so a `PATH` that winget changed underneath a running app does not reach it.
Until it does, every hook exits without drawing anything.

Pick **Local** for the session environment. Plugins do not load in the desktop
app's WSL sessions, which is Anthropic's limitation rather than this plugin's.
`bash` itself comes from Git for Windows, which the Code tab already requires.
