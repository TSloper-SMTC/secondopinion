# Install or update to 1.2.1

Version 1.2.1 adds optional Claude worker hooks so task and message notifications
can arrive without a relay model call. It also adds structured diagnostics for
failed relay delivery. Workers still need model access to process notifications
and do their work.

From an existing clone of `https://github.com/TSloper-SMTC/secondopinion`:

```bash
git pull --ff-only
./plugins/secondopinion/scripts/install.sh --claude
./plugins/secondopinion/scripts/install.sh --check
```

Start a new Codex thread and restart/resume existing Claude workers to load their
mailbox hooks. Confirm the resumed worker UUIDs with `secondopinion workers`, then
retry any interrupted delegation with its original task ID. Pulling alone does
not refresh installed plugin caches. No separate watcher setup is required.

Keep `--claude` on subsequent updates: running the plain installer removes the
optional Claude plugin. Ordinary second-opinion requests and relay-only worker
delivery can still use the plain installer. Skill-only installs (`--skills`) and
Claude `--safe-mode` do not enable worker hooks.

## Shared archive alternative

Use the shared `secondopinion-1.2.1.tar.gz` and its `.sha256` sidecar.
From the directory containing both files:

```bash
sha256sum -c secondopinion-1.2.1.tar.gz.sha256
```

Extract the archive into a permanent tools directory. Keep its extracted
`secondopinion` directory there: the installed CLI and return service use it.
From that directory run the same `install.sh --claude` and `install.sh --check`
commands above, then start a new Codex thread and restart/resume the workers.

Your normal authenticated `codex` and `claude` CLIs are required. To start new
workers, use project terminals such as `claude --name bench` and
`claude --name reviewer`, then tell Codex what to assign to them. Existing tasks
remain bound to their original worker UUIDs; starting a replacement does not
retarget them.

On the qualified local Linux/user-systemd setup it reports `installed=yes` and
`automatic_worker_return: ready`. With the Claude plugin installed, it also
reports `worker_notifications=hook_available`; this checks the installation,
not whether a particular running worker has loaded its hook. Native worker
wakeup is validated on Claude Code 2.1.268. No manual UUID registration is needed.

Version 1.2.1 retains the schema-2 mailbox from 1.2.0; no further migration is
needed. If upgrading from 1.1.0, update all participating installations together:
opening the mailbox upgrades it to schema 2 while preserving tasks, messages and
acknowledgments, and 1.1.0 clients then refuse that store. Do not downgrade a
migrated store.

See [the repair, validation and remaining rollout checks](delivery-relay-1.2.1.md)
and the [worker guide](../plugins/secondopinion/skills/secondopinion-request/references/delegated-workers.md).
