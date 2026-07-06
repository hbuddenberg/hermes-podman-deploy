# hermes-podman-deploy

One-command deployment of [Hermes Agent](https://github.com/NousResearch/hermes-agent) as a rootless podman container with automatic periodic updates. Designed for Fedora Silverblue / uBlue uCore (SELinux-ready), works on any Linux with podman + systemd.

## Quick start

```bash
git clone https://github.com/hbuddenberg/hermes-podman-deploy.git
cd hermes-podman-deploy
chmod +x hermes-podman-setup.sh

# Sandboxed mode: the agent lives and executes inside the container
./hermes-podman-setup.sh

# Host-control mode: the agent stays sandboxed in the container but
# executes commands on the HOST over SSH (its "hands and eyes")
./hermes-podman-setup.sh --host-control
```

Run from a real terminal or SSH session (the first run launches the interactive setup wizard, and pasting API keys through web consoles corrupts them). The script is idempotent — safe to re-run anytime.

## What it sets up

| Step | Result |
|------|--------|
| Linger | Container survives logout, starts on boot |
| Setup wizard | Interactive first-run config (API keys → `~/.hermes/.env`) |
| Quadlet | `~/.config/containers/systemd/hermes.container` — gateway + dashboard, ports bound to 127.0.0.1, SELinux `:Z` labels |
| Auto-update | `podman-auto-update.timer`: daily image check, automatic recreate, rollback if the new image fails to start |
| Dashboard auth | Generates basic-auth credentials on fresh installs (shown once — save the password) |
| CLI wrapper | `~/.local/bin/hermes` — type `hermes` on the host to enter the container CLI |
| `--host-control` | Dedicated ed25519 key in `~/.hermes/ssh/`, authorized on the host, `terminal.backend: ssh` via `host.containers.internal`, connection test, passwordless-sudo check (offers a `visudo`-validated `/etc/sudoers.d/hermes` rule if missing) |

## Operations

```bash
hermes                          # interactive CLI (inside the container)
podman auto-update              # update image now
systemctl --user status hermes  # service status
podman logs -f hermes           # follow logs
```

Dashboard: `http://127.0.0.1:9119` — from another machine, tunnel it:

```bash
ssh -L 9119:127.0.0.1:9119 user@host
```

## Notes

- All state lives in `~/.hermes` on the host; container updates never lose config, memory, or skills.
- `config.yaml` inside `~/.hermes` may be owned by the container's mapped UID under rootless podman — edit it via `podman exec -i hermes python ...` or add `UserNS=keep-id` to the Quadlet if you prefer host ownership.
- Host-control mode gives the agent your user (and optionally root via sudoers) on the host. That is the point — but understand it before enabling.

## CI

`smoke-test.yml` runs on every push and weekly (Mondays): shellcheck + syntax check of the script, then boots the official image with podman and verifies the gateway stays running for 60s — catching upstream image regressions before your auto-update pulls them.
