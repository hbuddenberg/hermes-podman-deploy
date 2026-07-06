#!/usr/bin/env bash
# hermes-podman-setup.sh — idempotent setup for Hermes Agent as a rootless
# podman container with automatic periodic updates (Quadlet + podman-auto-update).
#
# Safe to re-run: every step checks current state and skips work already done.
#
# What it sets up:
#   - systemd user Quadlet: ~/.config/containers/systemd/hermes.container
#   - gateway container "hermes" (image docker.io/nousresearch/hermes-agent:latest)
#   - podman-auto-update.timer for daily image updates with automatic rollback
#
# Manual operations afterwards:
#   podman auto-update                      # update now
#   systemctl --user status hermes          # service status
#   podman logs -f hermes                   # follow logs
#   podman exec -it hermes hermes           # interactive CLI inside container

set -euo pipefail

IMAGE="docker.io/nousresearch/hermes-agent:latest"
QUADLET_DIR="$HOME/.config/containers/systemd"
QUADLET_FILE="$QUADLET_DIR/hermes.container"
HERMES_DATA="$HOME/.hermes"
HEALTH_URL="http://127.0.0.1:8642/health"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m OK\033[0m %s\n' "$*"; }
skip()  { printf '\033[1;33mSKIP\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. Prerequisites ------------------------------------------------------
info "Checking prerequisites"

command -v podman >/dev/null 2>&1 \
  || fail "podman is not installed. Install it first: sudo pacman -S podman"

systemctl --user show-environment >/dev/null 2>&1 \
  || fail "No systemd user session available."

if loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes'; then
  skip "linger already enabled"
else
  info "Enabling linger so the container survives logout/reboot"
  loginctl enable-linger "$USER"
  ok "linger enabled"
fi

# --- 2. Data dir + interactive setup wizard --------------------------------
mkdir -p "$HERMES_DATA"

if [ -s "$HERMES_DATA/.env" ] || [ -s "$HERMES_DATA/config.yaml" ]; then
  skip "hermes config already present in $HERMES_DATA"
else
  if [ -t 0 ]; then
    info "No config found — running the interactive setup wizard"
    podman run -it --rm -v "$HERMES_DATA":/opt/data:Z "$IMAGE" setup
    ok "setup wizard finished"
  else
    fail "No TTY and no config in $HERMES_DATA. Run this script from a terminal so the setup wizard can prompt for API keys."
  fi
fi

# --- 3. Quadlet unit --------------------------------------------------------
mkdir -p "$QUADLET_DIR"

DESIRED_QUADLET=$(cat <<'EOF'
[Unit]
Description=Hermes Agent gateway

[Container]
Image=docker.io/nousresearch/hermes-agent:latest
ContainerName=hermes
Exec=gateway run
Volume=%h/.hermes:/opt/data:Z
PublishPort=127.0.0.1:8642:8642
PublishPort=127.0.0.1:9119:9119
Environment=HERMES_DASHBOARD=1
AutoUpdate=registry

[Service]
Restart=on-failure
TimeoutStartSec=300

[Install]
WantedBy=default.target
EOF
)

QUADLET_CHANGED=0
if [ -f "$QUADLET_FILE" ] && [ "$(cat "$QUADLET_FILE")" = "$DESIRED_QUADLET" ]; then
  skip "Quadlet already up to date: $QUADLET_FILE"
else
  printf '%s\n' "$DESIRED_QUADLET" > "$QUADLET_FILE"
  QUADLET_CHANGED=1
  ok "Quadlet written: $QUADLET_FILE"
fi

# --- 4. Start service + enable auto-update timer ---------------------------
info "Reloading systemd user units"
systemctl --user daemon-reload

if systemctl --user is-active --quiet hermes && [ "$QUADLET_CHANGED" = 0 ]; then
  skip "hermes service already running"
elif systemctl --user is-active --quiet hermes; then
  info "Quadlet changed — restarting hermes to apply it"
  systemctl --user restart hermes
  ok "hermes restarted"
else
  info "Starting hermes (first start pulls the image — may take a while)"
  systemctl --user start hermes
  ok "hermes started"
fi

if systemctl --user is-enabled --quiet podman-auto-update.timer 2>/dev/null; then
  skip "podman-auto-update.timer already enabled"
else
  systemctl --user enable --now podman-auto-update.timer
  ok "podman-auto-update.timer enabled (daily image check with rollback)"
fi

# --- 5. Dashboard basic auth ------------------------------------------------
# Inside the container the dashboard must bind 0.0.0.0 for the port publish
# to work, and hermes refuses non-loopback binds without an auth provider —
# so without this step port 9119 never opens.
info "Checking dashboard auth"

HAS_AUTH=$(podman exec hermes python -c 'import yaml
cfg = yaml.safe_load(open("/opt/data/config.yaml", encoding="utf-8")) or {}
print("yes" if cfg.get("dashboard", {}).get("basic_auth", {}).get("password_hash") else "no")' 2>/dev/null || echo "no")

if [ "$HAS_AUTH" = "yes" ]; then
  skip "dashboard basic auth already configured"
else
  DASH_USER="$USER"
  DASH_PASS=$(openssl rand -base64 15)
  DASH_HASH=$(podman exec hermes python -c "from plugins.dashboard_auth.basic import hash_password; print(hash_password('$DASH_PASS'))")
  # NOTE: podman exec needs -i for stdin (heredoc) to reach the process.
  podman exec -i -e DASH_USER="$DASH_USER" -e DASH_HASH="$DASH_HASH" hermes python - <<'PYEOF'
import os, yaml
p = "/opt/data/config.yaml"
with open(p, encoding="utf-8") as f:
    cfg = yaml.safe_load(f) or {}
auth = cfg.setdefault("dashboard", {}).setdefault("basic_auth", {})
auth["username"] = os.environ["DASH_USER"]
auth["password_hash"] = os.environ["DASH_HASH"]
with open(p, "w", encoding="utf-8") as f:
    yaml.safe_dump(cfg, f, sort_keys=False, allow_unicode=True)
PYEOF
  systemctl --user restart hermes
  ok "dashboard basic auth configured (user: $DASH_USER)"
  echo ""
  echo "  ============================================================"
  echo "  Dashboard credentials — SAVE THIS PASSWORD NOW:"
  echo "    user:     $DASH_USER"
  echo "    password: $DASH_PASS"
  echo "  ============================================================"
  echo ""
fi

# --- 6. Host wrapper for the container CLI ----------------------------------
# Lets you type `hermes` on the host and get the CLI inside the container.
WRAPPER="$HOME/.local/bin/hermes"

DESIRED_WRAPPER=$(cat <<'EOF'
#!/usr/bin/env bash
# Wrapper: run the hermes CLI inside the podman container.
exec podman exec -it hermes hermes "$@"
EOF
)

if [ -f "$WRAPPER" ] && [ "$(cat "$WRAPPER")" = "$DESIRED_WRAPPER" ]; then
  skip "hermes wrapper already installed: $WRAPPER"
else
  printf '%s\n' "$DESIRED_WRAPPER" > "$WRAPPER"
  chmod +x "$WRAPPER"
  ok "hermes wrapper installed: $WRAPPER"
fi

# --- 7. Verification --------------------------------------------------------
info "Verifying deployment"

systemctl --user is-active --quiet hermes || fail "hermes service is not active. Check: podman logs hermes"

HEALTH_OK=0
for _ in $(seq 1 30); do
  if curl -sf "$HEALTH_URL" >/dev/null 2>&1; then HEALTH_OK=1; break; fi
  sleep 2
done
if [ "$HEALTH_OK" = 1 ]; then
  ok "health endpoint responding: $HEALTH_URL"
else
  echo "WARN: health endpoint not responding yet ($HEALTH_URL)." >&2
  echo "      The API server may be disabled in config; check: podman logs hermes" >&2
fi

if podman auto-update --dry-run 2>/dev/null | grep -q hermes; then
  ok "container is registered for auto-update"
else
  echo "WARN: container not listed by 'podman auto-update --dry-run'" >&2
fi

# Rootless UID mapping check: files created by the container should belong
# to the host user. If they show up as a high subuid, UserNS=keep-id plus
# HERMES_UID/HERMES_GID must be added to the Quadlet.
FOREIGN=$(find "$HERMES_DATA" -maxdepth 1 ! -user "$USER" 2>/dev/null | head -1 || true)
if [ -n "$FOREIGN" ]; then
  echo "WARN: files in $HERMES_DATA not owned by $USER (e.g. $FOREIGN)." >&2
  echo "      Add to [Container] in $QUADLET_FILE:" >&2
  echo "        UserNS=keep-id" >&2
  echo "        Environment=HERMES_UID=$(id -u) HERMES_GID=$(id -g)" >&2
  echo "      then: systemctl --user daemon-reload && systemctl --user restart hermes" >&2
else
  ok "file ownership in $HERMES_DATA looks correct"
fi

info "Done. Useful commands:"
echo "  hermes                          # interactive CLI (inside the container)"
echo "  podman auto-update              # update image now"
echo "  systemctl --user status hermes  # service status"
echo "  podman logs -f hermes           # follow logs"
echo "  Dashboard: http://127.0.0.1:9119"
