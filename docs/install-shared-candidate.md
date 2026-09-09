# Install or update to 1.2.0

Version 1.2.0 adds ongoing questions and replies between the lead and its workers.
Use the Git update steps below or the shared 1.2.0 archive.

From an existing clone of `https://github.com/TSloper-SMTC/secondopinion`:

```bash
git pull --ff-only
./plugins/secondopinion/scripts/install.sh
```

Then start a new Codex thread. Pulling alone does not refresh the installed plugin
cache or install the return service. No separate watcher setup is required.

## Shared archive alternative

Extract `secondopinion-1.2.0.tar.gz` into a permanent tools
directory. Keep the extracted `secondopinion` directory there: the installed CLI
and return service use it. From that directory run:

```bash
./plugins/secondopinion/scripts/install.sh
```

Start a new Codex thread after installation. Your normal authenticated `codex`
and `claude` CLIs are required. No Claude-side plugin or worker environment flag
is needed. In project terminals, start workers such as `claude --name bench` and
`claude --name reviewer`, then tell Codex what to assign to those workers.

Optional verification: `./plugins/secondopinion/scripts/install.sh --check`.
On the qualified local Linux/user-systemd setup it reports `installed=yes` and
`automatic_worker_return: ready`. No manual watcher or UUID registration command
is needed. Ordinary second-opinion requests work as before.

Update all participating installations together. Opening the task mailbox with
1.2.0 upgrades it to schema 2 while preserving tasks, messages and acknowledgments;
1.1.0 clients then refuse that store. Restart older running sessions and services
with the installer/new-thread steps above; do not downgrade a migrated store.

Workers can now ask questions and receive replies on the same task. For model
selection, use `secondopinion ask --model sonnet --file request.md`, or start an
existing worker with its chosen model, such as `claude --name bench --model sonnet`.
See [validation and platform boundaries](robustness-validation.md).
