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

## Login Items shows four identical rows

macOS lists every LaunchAgent under **Login Items & Extensions**, labelled with
its program's *file name*. All four runners ship a launcher called `runsvc.sh`,
one per runner directory, so the list reads:

```
runsvc.sh   Item from unidentified developer
runsvc.sh   Item from unidentified developer
runsvc.sh   Item from unidentified developer
runsvc.sh   Item from unidentified developer
```

Nothing there says which runner a row belongs to, so none of them can be
switched off on purpose, and each registration fires an "App Background
Activity" notification for a name that means nothing.

`scripts/name-runner-login-items.sh` fixes it: each runner gets a distinctly
named launcher (`GitHub Runner impress-mac-3`) beside its `runsvc.sh`, signed
with the development identity, and its LaunchAgent points at that instead. The
rows become nameable and attributed.

```bash
scripts/name-runner-login-items.sh
```

Two things to know:

- **Re-run it after `svc.sh install`.** Registering a runner service rewrites
  the LaunchAgent back to `runsvc.sh`, so a runner upgrade undoes this. The
  script is idempotent.
- **It skips a runner that is mid-job**, because re-registering the agent kills
  the job (GitHub re-queues it). Name a runner explicitly to interrupt it, or
  just re-run the script later.

The launcher is a separate file rather than a renamed or signed `runsvc.sh`
because the runner replaces its own files on upgrade, and a shell script's
signature lives in extended attributes that any rewrite drops.

### Why reloading a runner agent is delicate

Two traps, both of which took `impress-mac` offline before the script handled
them. Anything else that reloads these agents needs to know about both.

1. **`launchctl bootout` is asynchronous.** Bootstrapping a label that has not
   finished unloading fails with `Bootstrap failed: 5: Input/output error`.
   Poll `launchctl list` until the label is gone first.
2. **`runsvc.sh` stops its own service on a clean exit.** Its log says
   `Runner listener exit with 0 return code, stop the service, no retry
   needed` — it unloads its own launchd job, seconds *after* the bootout
   returns. A bootstrap issued in that gap is registered and then torn down by
   the previous incarnation's shutdown. Waiting for the label to disappear
   does not cover it: the label disappears, reappears on the bootstrap, and is
   removed again. The runner's plist has `RunAtLoad` but **no `KeepAlive`**, so
   nothing brings it back.

The script settles for 10s after the unload, and after bootstrapping confirms
the job is still loaded 10s later rather than merely present. If a reload does
fail it restores the original agent — a cosmetic change must never leave a
runner down.

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
