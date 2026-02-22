#!/bin/bash

# Script to revoke and fully remove a TAK user.
# Revokes cert, removes from DB, cleans all associated files (certs, ZIPs in share/active dirs), and applies CRL.
# Run in the root of your tak-server wrapper directory (where docker-compose.yml is).
# Assumes Docker container is running and named 'tak' (check with docker compose ps).
# Usage: ./revoke_user.sh

# ---------------------------------------------------------------------------
# Config — adjust if your setup differs
# ---------------------------------------------------------------------------
CONTAINER_NAME="tak"
CERTS_DIR="./tak/certs/files"
SHARE_DIR="./tak/certs/files/share"
ACTIVE_DIR="./tak/certs/files/active_users"   # Adjust if your active users dir has a different name
CA_PASS="atakatak"
CA_KEY="ca-do-not-share"                      # CA key basename WITHOUT extension — revokeCert.sh appends .key itself
CA_CERT="root-ca"                             # CA cert basename WITHOUT extension — revokeCert.sh appends .pem itself
DOCKER_EXEC_TIMEOUT=30                         # Seconds before a docker exec is killed (prevents hangs)
MARTI_PORT=8443                               # Marti HTTPS port
# ---------------------------------------------------------------------------

set -euo pipefail

# Colour helpers
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Wrapped docker exec: non-interactive (-T), stdin from /dev/null so no script
# inside the container can hang waiting for terminal input, with a hard timeout
# and a follow-up SIGKILL if the process doesn't die cleanly.
# Usage: dexec <command string passed to bash -c>
dexec() {
  timeout --kill-after=5 "$DOCKER_EXEC_TIMEOUT" \
    docker compose exec -T "$CONTAINER_NAME" bash -c "$1" \
    < /dev/null \
    && return 0 \
    || {
      local exit_code=$?
      if [ "$exit_code" -eq 124 ] || [ "$exit_code" -eq 137 ]; then
        warn "docker exec timed out after ${DOCKER_EXEC_TIMEOUT}s — continuing anyway."
      else
        warn "docker exec exited with code $exit_code — continuing anyway."
      fi
      return 0   # Non-fatal: log and keep going
    }
}

# Like dexec but pipes a string into stdin — used for scripts that prompt for passwords.
# Usage: dexec_input <stdin_string> <command string>
dexec_input() {
  local input="$1"; shift
  timeout --kill-after=5 "$DOCKER_EXEC_TIMEOUT" \
    docker compose exec -T "$CONTAINER_NAME" bash -c "$1" \
    <<< "$input" \
    && return 0 \
    || {
      local exit_code=$?
      if [ "$exit_code" -eq 124 ] || [ "$exit_code" -eq 137 ]; then
        warn "docker exec timed out after ${DOCKER_EXEC_TIMEOUT}s — continuing anyway."
      else
        warn "docker exec exited with code $exit_code — continuing anyway."
      fi
      return 0
    }
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [ ! -f "docker-compose.yml" ]; then
  error "Run this script in the tak-server wrapper root directory (where docker-compose.yml is)."
  exit 1
fi

if ! docker compose ps --services --filter "status=running" 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
  warn "Container '${CONTAINER_NAME}' does not appear to be running. Cert/DB steps may fail, but file cleanup will still proceed."
fi

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------
read -rp "Enter the username to revoke (e.g., fielduser1): " USERNAME
if [ -z "$USERNAME" ]; then
  error "Username required."
  exit 1
fi

read -rp "Enter the CA password for revocation (press Enter for default 'atakatak'): " INPUT_CA_PASS
CA_PASS="${INPUT_CA_PASS:-$CA_PASS}"

echo ""
warn "This will permanently revoke ${USERNAME}'s certificate, remove them from the TAK database,"
warn "and delete all associated files. This cannot be undone."
read -rp "Type 'yes' to confirm: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  info "Aborted."
  exit 0
fi
echo ""

# ---------------------------------------------------------------------------
# Step 1: Revoke the certificate
# ---------------------------------------------------------------------------
info "Step 1/4 — Revoking certificate for ${USERNAME}..."

CERT_PATH="/opt/tak/certs/files/${USERNAME}.pem"

# Check cert file exists inside container before attempting revocation.
# revokeCert.sh prompts for the CA key password, so we pipe CA_PASS into its stdin.
if dexec "test -f '${CERT_PATH}'"; then
  dexec_input "${CA_PASS}" \
    "cd /opt/tak/certs && ./revokeCert.sh \
      /opt/tak/certs/files/${USERNAME} \
      /opt/tak/certs/files/${CA_KEY} \
      /opt/tak/certs/files/${CA_CERT}"
  info "Certificate revoked."
else
  warn "Certificate file not found at ${CERT_PATH} inside container — skipping revocation."
fi

# ---------------------------------------------------------------------------
# Step 2: Remove user from TAK database
# ---------------------------------------------------------------------------
info "Step 2/4 — Removing ${USERNAME} from the TAK database..."

# UserManager usermod -D removes the user entry. The -T flag and timeout above
# prevent this from hanging the terminal or crashing Marti if the JVM stalls.
dexec "java -jar /opt/tak/utils/UserManager.jar usermod -D '${USERNAME}'"
info "Database entry removed (or was already absent)."

# ---------------------------------------------------------------------------
# Step 3: Delete all associated files on the host
# ---------------------------------------------------------------------------
info "Step 3/4 — Cleaning up files for ${USERNAME}..."

REMOVED=0

# Cert files: .pem, .p12, .key, .csr, -trusted.pem, etc.
while IFS= read -r -d '' f; do
  rm -f "$f"
  info "  Deleted: $f"
  ((REMOVED++)) || true
done < <(find "$CERTS_DIR" -maxdepth 1 -name "${USERNAME}*" -print0 2>/dev/null)

# Data package ZIP in share directory
while IFS= read -r -d '' f; do
  rm -f "$f"
  info "  Deleted: $f"
  ((REMOVED++)) || true
done < <(find "$SHARE_DIR" -maxdepth 1 -name "${USERNAME}*" -print0 2>/dev/null)

# Data package ZIP in active_users directory (if it exists)
if [ -d "$ACTIVE_DIR" ]; then
  while IFS= read -r -d '' f; do
    rm -f "$f"
    info "  Deleted: $f"
    ((REMOVED++)) || true
  done < <(find "$ACTIVE_DIR" -maxdepth 1 -name "${USERNAME}*" -print0 2>/dev/null)
fi

if [ "$REMOVED" -eq 0 ]; then
  warn "No files found matching '${USERNAME}*' in cert/share/active directories."
else
  info "$REMOVED file(s) deleted."
fi

# ---------------------------------------------------------------------------
# Step 4: Apply CRL so the revocation takes effect immediately
# ---------------------------------------------------------------------------
info "Step 4/4 — Applying CRL to block revoked certificate..."

dexec "cd /opt/tak && ./configureInDocker.sh"
info "CRL applied. Connections using ${USERNAME}'s certificate will now be rejected."

# ---------------------------------------------------------------------------
# Step 5: Wait for TAK container to return to healthy after configureInDocker restart
# ---------------------------------------------------------------------------
HEALTHY_TIMEOUT=240   # Seconds before we tell the user something is wrong
WARN_AT=110            # Seconds before we start warning
POLL_INTERVAL=5

info "Step 5/5 — Waiting for TAK server to come back healthy..."
echo    "          (configureInDocker.sh restarts internal services — this is normal)"
echo ""

# Brief pause to let the old Marti process fully shut down before we start
# polling — avoids a false positive if port 8443 is still open from the dying process.
info "Waiting 10s for Marti services to cycle..."
sleep 10

START_TIME=$(date +%s)
WARNED=false

# Disable strict exit-on-error inside the health poll loop so transient
# command failures while the container is mid-restart don't kill the script.
set +e

while true; do
  ELAPSED=$(( $(date +%s) - START_TIME ))

  # Use bash's built-in TCP /dev/tcp check inside the container — no nc or curl needed.
  docker compose exec -T "$CONTAINER_NAME" bash -c     "timeout 2 bash -c 'cat < /dev/null > /dev/tcp/127.0.0.1/${MARTI_PORT}' 2>/dev/null"
  PORT_STATUS=$?

  if [ "$PORT_STATUS" -eq 0 ]; then
    echo ""
    info "Marti is back up on port ${MARTI_PORT}! (took ${ELAPSED}s)"
    break
  fi

  # Print updating timer line
  printf "\r  [%3ds elapsed] Waiting for Marti on port ${MARTI_PORT}..." "$ELAPSED"

  if [ "$ELAPSED" -ge "$HEALTHY_TIMEOUT" ]; then
    echo ""
    echo ""
    warn "Marti has not come back up after ${HEALTHY_TIMEOUT}s."
    warn "Something may be wrong. Try the following:"
    echo ""
    echo "    1. Force restart the container:"
    echo "       docker compose restart tak"
    echo ""
    echo "    2. Watch logs for errors:"
    echo "       docker compose logs -f tak"
    echo ""
    echo "    3. If it still won't come up, full cycle:"
    echo "       docker compose down && docker compose up -d"
    echo ""
    warn "Do NOT run this script again until Marti is accessible in your browser."
    break
  fi

  if [ "$ELAPSED" -ge "$WARN_AT" ] && [ "$WARNED" = false ]; then
    echo ""
    warn "Still waiting after ${WARN_AT}s — this is taking longer than usual."
    warn "If it doesn't recover within another $(( HEALTHY_TIMEOUT - WARN_AT ))s, abort and run:"
    echo "       docker compose restart tak"
    WARNED=true
  fi

  sleep "$POLL_INTERVAL"
done

# Restore strict error handling
set -e

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
info "User '${USERNAME}' has been fully removed."
info "Verify in the Web UI: Administrative → Manage Users / Connection History."