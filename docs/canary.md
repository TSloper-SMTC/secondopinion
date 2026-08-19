# Canary install workflow (local development)

Goal: test a development build of the plugin through the real `codex plugin`
machinery without touching the stable install, the live store, or the plugin
registry by hand.

## What is and is not supported

- **Fully isolated test (safe, automated)** — `tests/test_plugin.sh` installs
  the checkout's plugin into a throwaway `HOME`/`CODEX_HOME` via real
  `codex plugin marketplace add` + `codex plugin add` and uninstalls again.
  This never touches the real registry or store and needs no authorization.
- **True side-by-side live install is NOT supported.** The plugin id, the skill
  names, the `secondopinion` CLI name and the store path are all identities the
  stable install already owns; a second live copy would collide on every one of
  them. Use the sequential swap below instead.

## Sequential canary swap (live Codex; run only when intended)

The canary is a git worktree of this repo (its own branch), acting as its own
marketplace root. Example with `~/tools/secondopinion-parity`:

```bash
# swap the live marketplace to the canary worktree
codex plugin marketplace remove secondopinion
codex plugin marketplace add ~/tools/secondopinion-parity
codex plugin remove secondopinion@secondopinion
codex plugin add secondopinion@secondopinion
codex plugin list --json     # expect: enabled, marketplaceSource.source = the canary root
```

Then start a **new Codex thread** (plugins load at thread start) and smoke-test
read-only: a small `secondopinion ask`, `secondopinion jobs`,
`secondopinion result <ID>`, `secondopinion archive <ID>`.

For local iteration on the canary, refresh with:

```bash
codex plugin marketplace upgrade secondopinion
```

## Rollback (exact)

```bash
codex plugin marketplace remove secondopinion
codex plugin marketplace add ~/tools/secondopinion
codex plugin add secondopinion@secondopinion
~/tools/secondopinion/plugins/secondopinion/scripts/install.sh --check   # expect installed=yes
```

The store (`~/.secondopinion`) is shared and versioned by the exchange format,
not by the plugin build; the canary must not migrate or prune it. Never edit
`~/.codex/config.toml`'s plugin registry or the plugin cache by hand.
