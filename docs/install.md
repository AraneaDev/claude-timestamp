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
claude plugin marketplace add https://aranea-development.nl/plugins/marketplace.json
claude plugin install claude-timestamp@aranea
```

Hooks are bound when a session starts, so start a new session before markers
appear. An already-running session will not pick the plugin up.

## If the install fails on port 22

Claude Code clones a plugin from its GitHub repository over SSH. On a machine
with no SSH key for GitHub, or with outbound port 22 blocked, the install stops
here:

```text
Failed to clone repository: ssh: connect to host github.com port 22: Connection timed out
fatal: Could not read from remote repository.
Please make sure you have the correct access rights and the repository exists.
```

The message points at access rights. This repository is public, so what failed
is the transport. Adding the marketplace succeeds either way, because that
clone uses HTTPS, which is why other plugins from the same marketplace install
on such a machine while this one does not.

Tell git to reach GitHub over HTTPS, then install again:

```bash
git config --global --add url."https://github.com/".insteadOf "git@github.com:"
git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/"
```

That rewrites outgoing GitHub SSH URLs and nothing else, so it takes nothing
away on a machine that could not use them in the first place. To undo it:

```bash
git config --global --unset-all url."https://github.com/".insteadOf
```

## Codex compatibility

The repository also carries the universal `plugin.json` and Codex
`.codex-plugin/plugin.json` manifests. When the plugin is installed in Codex,
its lifecycle hooks provide the prompt send time, slow-tool and heartbeat notes,
resumption context, and end-of-session totals. Codex may ask you to review and
trust the hooks in `/hooks` before they run; that is a Codex safety step, not a
plugin setting. See the official [Codex hooks
documentation](https://learn.chatgpt.com/docs/hooks).

### Install in Codex CLI

Codex CLI uses Codex-format marketplaces. In a Codex session, open `/plugins`,
choose a configured marketplace that contains `claude-timestamp`, install it,
and start a new session so the plugin is loaded. The equivalent CLI commands
are:

```bash
codex plugin marketplace list
codex plugin add claude-timestamp@aranea
```

The Claude marketplace URL in [Install](#claude-code) is a Claude Code feed and
cannot be passed directly to `codex plugin marketplace add` on current Codex
CLI versions. Codex accepts a local or Git marketplace root containing
`.agents/plugins/marketplace.json`; this repository currently provides the
plugin package and its Codex manifest, but is not itself a marketplace root.
If you maintain or receive a Codex marketplace entry for Aranea, add that
marketplace first and then use the commands above.

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
claude plugin marketplace add https://aranea-development.nl/plugins/marketplace.json
claude plugin install claude-timestamp@aranea
```

On Windows:

```powershell
winget install jqlang.jq
claude plugin marketplace add https://aranea-development.nl/plugins/marketplace.json
claude plugin install claude-timestamp@aranea
```

The desktop app's plugin browser lists what your configured marketplaces
already offer and cannot add one, so the marketplace step is what makes the
plugin appear there at all. The commands above need the standalone CLI, which
is a separate installation from the desktop app. Without it, type the same two
steps as slash commands in a **Local** session in the Code tab, which needs
nothing else installed:

```text
/plugin marketplace add https://aranea-development.nl/plugins/marketplace.json
/plugin install claude-timestamp@aranea
```

Restart the desktop app after installing `jq`. It reads Windows user and system
environment variables when it launches and never reads your PowerShell profile,
so a `PATH` that winget changed underneath a running app does not reach it.
Until it does, every hook exits without drawing anything.

Pick **Local** for the session environment. Plugins do not load in the desktop
app's WSL sessions, which is Anthropic's limitation rather than this plugin's.
`bash` itself comes from Git for Windows, which the Code tab already requires.
