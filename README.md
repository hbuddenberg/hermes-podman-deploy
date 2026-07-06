# hermes-podman-deploy

Deployment script for running [Hermes Agent](https://github.com/NousResearch/hermes-agent) as a rootless podman container with automatic periodic updates.

## Usage

```bash
./hermes-podman-setup.sh
```

Run it from a terminal (the first run launches the interactive setup wizard). It is idempotent — safe to re-run.

What it configures:

- Quadlet unit at `~/.config/containers/systemd/hermes.container` (gateway + dashboard, ports bound to 127.0.0.1)
- `podman-auto-update.timer` — daily image check, automatic recreate with rollback on failed start
- Linger, so the container survives logout and starts on boot

## Operations

```bash
podman auto-update              # update image now
systemctl --user status hermes  # service status
podman logs -f hermes           # follow logs
```

Dashboard: http://127.0.0.1:9119

## CI

`smoke-test.yml` lints the script (shellcheck) and boots the official image with podman on every push, plus a weekly scheduled run to catch upstream image regressions.
