# Install or update to 1.1.0

From an existing clone of `https://github.com/TSloper-SMTC/secondopinion`:

```bash
git pull --ff-only
./plugins/secondopinion/scripts/install.sh
```

Then start a new Codex thread. Pulling alone does not refresh the installed plugin
cache or install the return service. No separate watcher setup is required.

## Shared archive alternative

Extract `secondopinion-1.1.0.tar.gz` into a permanent tools
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

The prior timestamped 1.0.2 archive was a development candidate; 1.1.0 is the
feature-release version. See [validation and platform boundaries](automatic-return-validation.md).
