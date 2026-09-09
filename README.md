# secondopinion

Ask Claude Code for a second opinion directly from Codex, and get the answer back.

## Installation

Requires Linux, Bash, Git, Python 3.8+, GNU command-line tools, and working `codex`
and `claude` CLIs. Claude Code must support `--safe-mode`.

```bash
git clone https://github.com/TSloper-SMTC/secondopinion ~/tools/secondopinion
cd ~/tools/secondopinion
./plugins/secondopinion/scripts/install.sh
./plugins/secondopinion/scripts/install.sh --check
```

Start a new Codex thread after installation. The installer adds the plugin and
CLI, configures access to `~/.secondopinion`, and enables Codex sandbox network
access unless you explicitly disabled it. No Claude-side plugin is required.
On Linux with user systemd, it also configures the local Codex server and
automatic worker-result delivery. Existing Codex conversations must be restarted.

To update, run `git pull --ff-only`, rerun the installer, and start a new Codex thread.

## Usage

In Codex, ask naturally:

> Ask Claude to review this change.
>
> Get a second opinion on this design.
>
> Have Claude verify that this fix addresses the bug.

Codex sends the request, waits for Claude, and returns the answer. Keep the
command running until it finishes.

For direct CLI use, run from the project you want reviewed:

```bash
secondopinion ask --topic "Design review" --file request.md
secondopinion review --adversarial
secondopinion status EXCHANGE_ID
secondopinion result EXCHANGE_ID
secondopinion ask --attach EXCHANGE_ID  # retry an interrupted request
```

### Existing Claude workers

Start named Claude sessions in your project, for example `claude --name bench`
and `claude --name reviewer`. Then ask Codex:

> Have bench run the tests and reviewer independently review the results.

Codex handles delivery, tracking, and collecting results. In the configured local
Codex CLI, results wake the conversation automatically; no watcher commands are
needed. Workers can ask questions and send updates; Codex can answer or send
direction to the same worker while the task continues. Each task keeps its
conversation history. Other hosts keep waiting in the active call. The [worker guide](plugins/secondopinion/skills/secondopinion-request/references/delegated-workers.md)
covers advanced usage and recovery.

Run `secondopinion --help` for all commands. Additional installation options
and technical details are in the [reference](docs/reference.md).
