# Self-hosted runners

Four GitHub Actions runners live on the build Mac, registered to
`yipihey/impress-apps` as `impress-mac`, `impress-mac-2`, `impress-mac-3` and
`impress-mac-4`. Each is a plain runner install under `~/actions-runner-impress*`,
started by a per-runner LaunchAgent
(`~/Library/LaunchAgents/actions.runner.yipihey-impress-apps.impress-mac*.plist`).

| Runner | Directory | `RUSTUP_HOME` |
|---|---|---|
| impress-mac | `~/actions-runner-impress` | `~/.rustup-runner-1` |
| impress-mac-2 | `~/actions-runner-impress-2` | `~/.rustup-runner-2` |
| impress-mac-3 | `~/actions-runner-impress-3` | `~/.rustup-runner-3` |
| impress-mac-4 | `~/actions-runner-impress-4` | `~/.rustup-runner-4` |

## Why each runner has its own `RUSTUP_HOME`

Every Rust workflow begins with `dtolnay/rust-toolchain@stable`, which runs
`rustup toolchain install stable`. That is a no-op while `stable` is current —
and a multi-hundred-megabyte unpack the day a new stable ships, on every runner
at once, into the same directory. rustup does not lock that directory.

On 2026-09-07 the race left `~/.rustup/toolchains/stable-aarch64-apple-darwin`
present but without `bin/cargo` or `bin/rustc`. Every Rust lane on every runner
failed simultaneously and kept failing, because each new job "installed" a
toolchain rustup already believed it had. The repair was
`rustup toolchain uninstall stable && rustup toolchain install stable`.

Separate `RUSTUP_HOME`s remove the shared directory, so the race has nowhere to
happen. `CARGO_HOME` stays shared (`~/.cargo`): cargo takes a real file lock on
its package cache, and sharing the ~2 GB registry across four runners is worth
keeping.

The env var is set in each runner's `.env` file (the runner's own mechanism —
read by the listener at start, applied to every job process), so it survives
runner upgrades. It takes effect on the next **service restart**, not the next
job.

The four homes were seeded as APFS clones of the original `~/.rustup`
(`cp -Rc`), so they cost no disk until they diverge.

## Restarting a runner

`.env` changes need a listener restart. Restarting kills any job in flight —
GitHub re-queues it, but check first:

```bash
pgrep -fl Runner.Worker
```

Then, for the runner you want (label suffix `-2`, `-3`, `-4` as appropriate):

```bash
launchctl bootout gui/$UID/actions.runner.yipihey-impress-apps.impress-mac && launchctl bootstrap gui/$UID ~/Library/LaunchAgents/actions.runner.yipihey-impress-apps.impress-mac.plist
```

Confirm it came back:

```bash
gh api repos/:owner/:repo/actions/runners --jq '.runners[] | "\(.name) \(.status) \(.busy)"'
```

A runner that is registered locally but missing from that listing is not
serving jobs, however healthy its directory looks — check
`launchctl list | grep actions.runner` and the LaunchAgent's log under
`~/Library/Logs/actions.runner.*/`.
