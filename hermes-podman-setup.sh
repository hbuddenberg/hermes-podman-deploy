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

# --host-control: configure the agent's terminal backend to run commands on
# the HOST over SSH (the agent stays sandboxed in the container, but its
# hands work on the machine). Requires a running sshd on the host.
HOST_CONTROL=0
UNINSTALL=0
RESET_DASH_PASS=0
for arg in "$@"; do
  case "$arg" in
    --host-control) HOST_CONTROL=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --reset-dashboard-password) RESET_DASH_PASS=1 ;;
    *) echo "Unknown option: $arg (supported: --host-control, --uninstall, --reset-dashboard-password)" >&2; exit 2 ;;
  esac
done

IMAGE="docker.io/nousresearch/hermes-agent:latest"
QUADLET_DIR="$HOME/.config/containers/systemd"
QUADLET_FILE="$QUADLET_DIR/hermes.container"
HERMES_DATA="$HOME/.hermes"
HEALTH_URL="http://127.0.0.1:8642/health"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ✔\033[0m %s\n' "$*"; }
skip()  { printf '\033[1;33m ↷\033[0m %s (skipped)\n' "$*"; }
fail()  { printf '\033[1;31m ✘\033[0m %s\n' "$*" >&2; exit 1; }

STEP=0
TOTAL_STEPS=7
if [ "$HOST_CONTROL" = 1 ]; then TOTAL_STEPS=8; fi
step() {
  STEP=$((STEP + 1))
  printf '\n\033[1;36m━━━ [%d/%d] %s\033[0m\n' "$STEP" "$TOTAL_STEPS" "$*"
}

# spin <label> <cmd...> — run a command with a unicode spinner (TTY only).
# Output is captured; shown only on failure.
SPIN_LOG=$(mktemp)
trap 'rm -f "$SPIN_LOG"' EXIT
spin() {
  local label=$1; shift
  if [ ! -t 1 ]; then "$@" >"$SPIN_LOG" 2>&1 || { cat "$SPIN_LOG" >&2; return 1; }; return 0; fi
  "$@" >"$SPIN_LOG" 2>&1 &
  local pid=$! frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r\033[1;35m%s\033[0m %s' "${frames:$((i % 10)):1}" "$label"
    i=$((i + 1))
    sleep 0.1
  done
  local rc=0; wait "$pid" || rc=$?
  printf '\r\033[K'
  [ "$rc" -eq 0 ] || { cat "$SPIN_LOG" >&2; return "$rc"; }
}

# --- Reset dashboard password ------------------------------------------------
if [ "$RESET_DASH_PASS" = 1 ]; then
  info "Resetting dashboard password"
  podman container exists hermes 2>/dev/null || fail "hermes container is not running"
  DASH_USER="$USER"
  DASH_PASS=$(openssl rand -base64 15)
  DASH_HASH=$(podman exec hermes python -c "from plugins.dashboard_auth.basic import hash_password; print(hash_password('$DASH_PASS'))")
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
  ok "dashboard password reset"
  echo ""
  echo "  user:     $DASH_USER"
  echo "  password: $DASH_PASS"
  echo ""
  exit 0
fi

# --- Uninstall --------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
  info "Uninstalling hermes deployment"
  systemctl --user stop hermes 2>/dev/null || true
  rm -f "$QUADLET_FILE" && ok "Quadlet removed"
  systemctl --user daemon-reload
  podman rm -f hermes >/dev/null 2>&1 || true
  if podman rmi "$IMAGE" >/dev/null 2>&1; then ok "image removed"; else skip "image already absent"; fi
  rm -f "$HOME/.local/bin/hermes" && ok "hermes wrapper removed"
  rm -f "$HOME/.ssh/authorized_keys.hermes-bak"
  # Remove only the host-control key from authorized_keys, if present.
  if [ -f "$HERMES_DATA/ssh/hermes_host_key.pub" ] && [ -f "$HOME/.ssh/authorized_keys" ]; then
    grep -vF "$(cat "$HERMES_DATA/ssh/hermes_host_key.pub")" "$HOME/.ssh/authorized_keys" \
      > "$HOME/.ssh/authorized_keys.tmp" && mv "$HOME/.ssh/authorized_keys.tmp" "$HOME/.ssh/authorized_keys"
    ok "host-control key removed from authorized_keys"
  fi
  sudo rm -f /etc/sudoers.d/hermes 2>/dev/null && ok "sudoers rule removed" || true
  echo ""
  echo "NOT removed (your data): $HERMES_DATA"
  echo "  Full wipe (API keys, memory, skills — irreversible):"
  echo "    podman unshare rm -rf $HERMES_DATA 2>/dev/null || rm -rf $HERMES_DATA"
  echo "  podman-auto-update.timer left enabled (harmless; disable with:"
  echo "    systemctl --user disable --now podman-auto-update.timer)"
  exit 0
fi

# --- 1. Prerequisites ------------------------------------------------------
step "Prerequisites"

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
step "Data directory & initial config"
mkdir -p "$HERMES_DATA"

# Repair ownership from earlier runs without keep-id: files created by the
# container may belong to subuids, making them unreadable on the host.
if [ -n "$(find "$HERMES_DATA" ! -user "$USER" -print -quit 2>/dev/null)" ] \
   || ! find "$HERMES_DATA" >/dev/null 2>&1; then
  info "Repairing ownership of $HERMES_DATA (subuid leftovers)"
  podman unshare chown -R 0:0 "$HERMES_DATA"
  ok "ownership repaired"
fi

if [ -s "$HERMES_DATA/.env" ] || [ -s "$HERMES_DATA/config.yaml" ]; then
  skip "hermes config already present in $HERMES_DATA"
else
  if [ -t 0 ]; then
    info "No config found — running the interactive setup wizard"
    podman run -it --rm --userns=keep-id:uid=10000,gid=10000 --user 0 \
      -v "$HERMES_DATA":/opt/data:Z "$IMAGE" setup
    ok "setup wizard finished"
  else
    fail "No TTY and no config in $HERMES_DATA. Run this script from a terminal so the setup wizard can prompt for API keys."
  fi
fi

# --- 3. Quadlet unit --------------------------------------------------------
step "Quadlet unit"
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
# Dashboard on all interfaces (LAN / tailscale): protected by basic auth,
# which this script configures — hermes refuses non-loopback binds without it.
PublishPort=9119:9119
Environment=HERMES_DASHBOARD=1
# Map the host user directly onto the image's internal hermes uid (10000):
# no HERMES_UID remap needed (the image already ships a uid-1000 user, so
# usermod-based remapping collides on typical hosts). User=0 lets the s6
# bootstrap run as container root before dropping to hermes. Files written
# to /opt/data land owned by the host user on the host side.
UserNS=keep-id:uid=10000,gid=10000
User=0
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
step "Service & auto-update timer"
systemctl --user daemon-reload

if systemctl --user is-active --quiet hermes && [ "$QUADLET_CHANGED" = 0 ]; then
  skip "hermes service already running"
elif systemctl --user is-active --quiet hermes; then
  spin "Quadlet changed — restarting hermes to apply it" systemctl --user restart hermes
  ok "hermes restarted"
else
  spin "Starting hermes (first start pulls the image — may take a while)" systemctl --user start hermes
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
step "Dashboard auth"

# config.yaml inside the container belongs to the remapped hermes user, and
# the default exec user may not be able to write it — exec as the file owner.
CFG_OWNER=$(podman exec hermes stat -c '%u:%g' /opt/data/config.yaml)

HAS_AUTH=$(podman exec -u "$CFG_OWNER" hermes python -c 'import yaml
cfg = yaml.safe_load(open("/opt/data/config.yaml", encoding="utf-8")) or {}
print("yes" if cfg.get("dashboard", {}).get("basic_auth", {}).get("password_hash") else "no")' 2>/dev/null || echo "no")

if [ "$HAS_AUTH" = "yes" ]; then
  skip "dashboard basic auth already configured"
else
  DASH_USER="$USER"
  DASH_PASS=$(openssl rand -base64 15)
  DASH_HASH=$(podman exec hermes python -c "from plugins.dashboard_auth.basic import hash_password; print(hash_password('$DASH_PASS'))")
  # NOTE: podman exec needs -i for stdin (heredoc) to reach the process.
  podman exec -i -u "$CFG_OWNER" -e DASH_USER="$DASH_USER" -e DASH_HASH="$DASH_HASH" hermes python - <<'PYEOF'
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
step "Host CLI wrapper"
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
  mkdir -p "$(dirname "$WRAPPER")"
  printf '%s\n' "$DESIRED_WRAPPER" > "$WRAPPER"
  chmod +x "$WRAPPER"
  ok "hermes wrapper installed: $WRAPPER"
fi

# --- 7. Host control over SSH (opt-in: --host-control) ----------------------
if [ "$HOST_CONTROL" = 1 ]; then
  step "Host control (SSH backend + sudo)"

  systemctl is-active --quiet sshd || systemctl is-active --quiet ssh 2>/dev/null \
    || fail "sshd is not running on the host. Enable it first (e.g. sudo systemctl enable --now sshd)."

  SSH_KEY_DIR="$HERMES_DATA/ssh"
  SSH_KEY="$SSH_KEY_DIR/hermes_host_key"
  # Key lives under ~/.hermes so it persists across container updates and is
  # visible inside the container at /opt/data/ssh/.
  if [ -f "$SSH_KEY" ]; then
    skip "host-control SSH key already exists"
  else
    mkdir -p "$SSH_KEY_DIR"
    ssh-keygen -t ed25519 -N "" -C "hermes-container-host-control" -f "$SSH_KEY" -q
    ok "SSH keypair generated: $SSH_KEY"
  fi

  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  touch "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys"
  if grep -qf "$SSH_KEY.pub" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
    skip "public key already authorized on host"
  else
    cat "$SSH_KEY.pub" >> "$HOME/.ssh/authorized_keys"
    ok "public key added to ~/.ssh/authorized_keys"
  fi

  # host.containers.internal resolves to the host from inside podman containers.
  CFG_OWNER=${CFG_OWNER:-$(podman exec hermes stat -c '%u:%g' /opt/data/config.yaml)}
  podman exec -i -u "$CFG_OWNER" -e SSH_USER="$USER" hermes python - <<'PYEOF'
import os, yaml
p = "/opt/data/config.yaml"
with open(p, encoding="utf-8") as f:
    cfg = yaml.safe_load(f) or {}
cfg["terminal"] = {
    "backend": "ssh",
    "cwd": "~",
    "timeout": 180,
    "lifetime_seconds": 300,
    "ssh_host": "host.containers.internal",
    "ssh_user": os.environ["SSH_USER"],
    "ssh_port": 22,
    "ssh_key": "/opt/data/ssh/hermes_host_key",
}
with open(p, "w", encoding="utf-8") as f:
    yaml.safe_dump(cfg, f, sort_keys=False, allow_unicode=True)
PYEOF
  systemctl --user restart hermes
  ok "terminal backend set to ssh -> $USER@host (restarted)"

  # Connection test from inside the container (accept-new primes known_hosts).
  sleep 3
  if podman exec hermes ssh -i /opt/data/ssh/hermes_host_key \
       -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
       "$USER@host.containers.internal" true 2>/dev/null; then
    ok "container -> host SSH connection verified"
  else
    echo "WARN: SSH test from container to host failed. Check sshd config" >&2
    echo "      (PubkeyAuthentication, AllowUsers) and firewall on port 22." >&2
  fi

  # Sudo check: hermes operates over SSH as $USER, so root tasks
  # (rpm-ostree, systemctl) need passwordless sudo. On uCore/CoreOS the
  # `core` user already has NOPASSWD by default.
  info "Checking passwordless sudo for $USER"
  if sudo -n true 2>/dev/null; then
    ok "passwordless sudo available — hermes can run root tasks on the host"
  elif [ -t 0 ]; then
    echo "Passwordless sudo is NOT configured for $USER."
    echo "Without it, hermes cannot run root tasks (rpm-ostree, systemctl, ...)."
    printf "Create /etc/sudoers.d/hermes with 'NOPASSWD: ALL' for %s? [y/N] " "$USER"
    read -r REPLY
    if [ "$REPLY" = "y" ] || [ "$REPLY" = "Y" ]; then
      SUDOERS_RULE="$USER ALL=(ALL) NOPASSWD: ALL"
      TMP_SUDOERS=$(mktemp)
      printf '%s\n' "$SUDOERS_RULE" > "$TMP_SUDOERS"
      if visudo -c -f "$TMP_SUDOERS" >/dev/null 2>&1; then
        sudo install -m 0440 "$TMP_SUDOERS" /etc/sudoers.d/hermes
        rm -f "$TMP_SUDOERS"
        sudo -n true 2>/dev/null && ok "sudoers rule installed and verified" \
          || echo "WARN: rule installed but 'sudo -n' still fails — check sudoers order" >&2
      else
        rm -f "$TMP_SUDOERS"
        fail "generated sudoers rule failed visudo validation — aborting for safety"
      fi
    else
      skip "sudo left as-is — hermes will be limited to non-root tasks on the host"
    fi
  else
    echo "WARN: no passwordless sudo and no TTY to ask. Root tasks won't work" >&2
    echo "      until you add a sudoers rule, e.g.:" >&2
    echo "        echo '$USER ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/hermes" >&2
  fi
fi

# --- 8. Verification --------------------------------------------------------
step "Verification"

systemctl --user is-active --quiet hermes || fail "hermes service is not active. Check: podman logs hermes"

HEALTH_OK=0
HEALTH_TRIES=30
for i in $(seq 1 "$HEALTH_TRIES"); do
  if curl -sf "$HEALTH_URL" >/dev/null 2>&1; then HEALTH_OK=1; break; fi
  if [ -t 1 ]; then
    filled=$((i * 20 / HEALTH_TRIES))
    bar=$(printf '█%.0s' $(seq 1 "$filled") 2>/dev/null)
    pad=$(printf '░%.0s' $(seq 1 $((20 - filled))) 2>/dev/null)
    printf '\r\033[1;35m⏳\033[0m waiting for health endpoint [%s%s] %d/%ds' "$bar" "$pad" $((i * 2)) $((HEALTH_TRIES * 2))
  fi
  sleep 2
done
if [ -t 1 ]; then printf '\r\033[K'; fi
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

# Dashboard is published on all interfaces — open the firewall if one is active.
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
  if sudo firewall-cmd --query-port=9119/tcp >/dev/null 2>&1; then
    skip "firewalld already allows 9119/tcp"
  else
    sudo firewall-cmd --add-port=9119/tcp --permanent >/dev/null && sudo firewall-cmd --reload >/dev/null
    ok "firewalld: opened 9119/tcp for the dashboard"
  fi
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
# Point at /login directly: with a single basic-auth provider the root URL
# auto-redirects into the OAuth flow and 500s (upstream bug — basic is
# password-only). /login renders the password form and works.
echo "  Dashboard (local):     http://127.0.0.1:9119/login"
LAN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' || true)
if [ -n "$LAN_IP" ]; then
  echo "  Dashboard (LAN):       http://$LAN_IP:9119/login"
fi
if command -v tailscale >/dev/null 2>&1; then
  TS_IP=$(tailscale ip -4 2>/dev/null | head -1 || true)
  if [ -n "$TS_IP" ]; then
    echo "  Dashboard (tailscale): http://$TS_IP:9119/login"
  fi
fi
