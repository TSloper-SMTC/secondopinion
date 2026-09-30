# Install or update to secondopinion 1.2.3

Version 1.2.3 lets Codex own and update its local app server. Earlier versions
installed `codex-local-app-server.service`, pinned to the Codex binary present at
install time. Codex never updates a server it did not start, so newer Codex
releases, and the models offered only to them, stayed hidden. The installer now
retires that unit and runs `codex app-server daemon start`. Restart any Codex
windows that were open during the update. Workers still need model access to
process notifications and do their work.

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

Use the shared `secondopinion-1.2.3.tar.gz` and its `.sha256` sidecar.
From the directory containing both files:

```bash
sha256sum -c secondopinion-1.2.3.tar.gz.sha256
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
`automatic_worker_return: ready` with `codex_runtime: codex_managed`. A
`warning` field means the Codex server will not update itself; follow its text.
With no Codex server running it reports `unavailable`; opening Codex starts the
server. With the Claude plugin installed, it also
reports `worker_notifications=hook_available`; this checks the installation,
not whether a particular running worker has loaded its hook. Native worker
wakeup is validated on Claude Code 2.1.274. No manual UUID registration is needed.

Version 1.2.2 upgraded the mailbox to schema 3 while preserving tasks, messages,
reports and acknowledgments; 1.2.3 keeps schema 3. Update every participating
installation and restart already-running services/sessions together: 1.2.1 and
older clients refuse a schema-3 store because they do not understand message
supersession. Do not downgrade a migrated store.

See [the recovery behavior and qualification](delivery-recovery-1.2.2.md),
[the 1.2.1 relay repair](delivery-relay-1.2.1.md),
and the [worker guide](../plugins/secondopinion/skills/secondopinion-request/references/delegated-workers.md).
