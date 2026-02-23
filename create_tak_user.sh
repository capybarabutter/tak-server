#!/bin/bash

# Script to create a new TAK user, generate certs, register user, create data package ZIP, and place for sharing.
# Run this in the root of your tak-server wrapper directory (where docker-compose.yml is).
# Assumes Docker container is running and named 'tak' (check with docker compose ps).
# You will be prompted for inputs interactively.

# Exit on error
set -e

# ─────────────────────────────────────────────
# Default values (adjust if needed)
# ─────────────────────────────────────────────
CONTAINER_NAME="tak"
NEW_CERTS_DIR="./tak/certs/files/share"
TEMP_DIR="./temp_user_create"
CA_P12="truststore-root.p12"
CA_P12_DIR="./tak/certs/files/"
CA_PASS="atakatak"
COT_PORT="8089"
COT_PROTOCOL="ssl"

# ─────────────────────────────────────────────
# Sanity check
# ─────────────────────────────────────────────
if [ ! -f "docker-compose.yml" ]; then
  echo "Error: Run this script in the tak-server wrapper root directory (where docker-compose.yml is)."
  exit 1
fi

mkdir -p "$NEW_CERTS_DIR"

# ─────────────────────────────────────────────
# Prompts
# ─────────────────────────────────────────────
read -p "Enter the new username (e.g., fielduser1): " USERNAME
if [ -z "$USERNAME" ]; then
  echo "Error: Username required."
  exit 1
fi

read -p "Enter callsign for this user (press Enter to use username): " CALLSIGN
CALLSIGN=${CALLSIGN:-$USERNAME}

read -s -p "Enter a password for the client certificate and data package ZIP: " IMPORT_PASS
echo ""
if [ -z "$IMPORT_PASS" ]; then
  echo "Error: Password required."
  exit 1
fi
read -s -p "Confirm password: " IMPORT_PASS_CONFIRM
echo ""
if [ "$IMPORT_PASS" != "$IMPORT_PASS_CONFIRM" ]; then
  echo "Error: Passwords do not match."
  exit 1
fi
CLIENT_PASS="$IMPORT_PASS"

read -p "Password protect the ZIP file? (not supported by all ATAK versions) [y/N]: " PROTECT_ZIP
PROTECT_ZIP="${PROTECT_ZIP,,}"

read -p "Enter the server external IP or hostname (e.g., 192.168.1.100): " SERVER_IP
if [ -z "$SERVER_IP" ]; then
  echo "Error: Server IP required."
  exit 1
fi

read -p "Enter the CA truststore password (press Enter for default 'atakatak'): " INPUT_CA_PASS
CA_PASS=${INPUT_CA_PASS:-$CA_PASS}

read -p "Enter a group name to add user to (optional, press Enter to skip): " GROUP_NAME


# This section is not currently working. Feature not yet inmplemented.
# ─────────────────────────────────────────────
# Profile selection
# ─────────────────────────────────────────────
# echo ""
# echo "Select a user profile:"
# echo "  1) Basic User     — standard field operator, settings unlocked"
# echo "  2) Advanced User  — multiple stream support, coord/alt prefs, network settings visible"
# echo "  3) Admin          — admin cert flag, settings admin password set, full access"
# read -p "Enter profile number [1]: " PROFILE_NUM
PROFILE_NUM=2 #${PROFILE_NUM:-1}

case "$PROFILE_NUM" in
  1) PROFILE="basic" ;;
  2) PROFILE="advanced" ;;
  3) PROFILE="admin" ;;
  *)
    echo "Invalid selection. Defaulting to basic."
    PROFILE="basic"
    ;;
esac

# echo "Profile selected: $PROFILE"

# # Admin profile: prompt for settings lock PIN
# ADMIN_PIN=""
# if [ "$PROFILE" = "admin" ]; then
#   read -s -p "Enter an admin PIN to lock ATAK settings (leave blank to skip PIN lock): " ADMIN_PIN
#   echo ""
# fi

# ─────────────────────────────────────────────
# Step 1: Generate client cert inside container
# ─────────────────────────────────────────────
# Note: makeCert.sh ignores stdin and seals the p12 with the CA password
# ($CA_PASS) regardless of input. We re-encrypt the p12 afterward with
# CLIENT_PASS so each user gets a unique cert password.
echo ""
echo "Generating client certificate for $USERNAME..."
docker compose exec "$CONTAINER_NAME" bash -c \
  "cd /opt/tak/certs && ./makeCert.sh client \"$USERNAME\""

echo "Fixing permissions on cert files..."
sudo chown -R "$(whoami)":"$(whoami)" ./tak/certs/files

echo "Re-encrypting client p12 with provided password..."
ORIG_P12="./tak/certs/files/$USERNAME.p12"
REENC_P12="./tak/certs/files/$USERNAME-reenc.p12"
TEMP_PEM="./tak/certs/files/$USERNAME-temp.pem"

# Step 1: Decrypt to intermediate PEM using legacy provider (TAK certs use RC2-40-CBC)
openssl pkcs12 \
  -in "$ORIG_P12" \
  -passin "pass:$CA_PASS" \
  -passout "pass:temp" \
  -legacy \
  -out "$TEMP_PEM"

# Step 2: Re-export with legacy-compatible ciphers, SHA1 MAC, and user's chosen password
# -keypbe and -certpbe: use 3DES (compatible with ATAK's Java runtime)
# -macalg SHA1: ATAK rejects SHA-256 MAC which is the OpenSSL 3 default
openssl pkcs12 \
  -export \
  -in "$TEMP_PEM" \
  -passin "pass:temp" \
  -passout "pass:$CLIENT_PASS" \
  -keypbe PBE-SHA1-3DES \
  -certpbe PBE-SHA1-3DES \
  -macalg SHA1 \
  -out "$REENC_P12"

rm -f "$TEMP_PEM"
mv "$REENC_P12" "$ORIG_P12"
echo "Re-encryption complete."

# ─────────────────────────────────────────────
# Step 2: Register user in TAK database
# ─────────────────────────────────────────────
echo "Registering user in TAK database..."
PEM_PATH="/opt/tak/certs/files/$USERNAME.pem"

CERTMOD_ARGS=""
if [ -n "$GROUP_NAME" ]; then
  CERTMOD_ARGS="-g \"$GROUP_NAME\""
fi
if [ "$PROFILE" = "admin" ]; then
  CERTMOD_ARGS="$CERTMOD_ARGS -A"
fi

docker compose exec "$CONTAINER_NAME" bash -c \
  "java -jar /opt/tak/utils/UserManager.jar certmod $CERTMOD_ARGS $PEM_PATH"

# ─────────────────────────────────────────────
# Step 3: Build data package
# ─────────────────────────────────────────────
echo "Creating data package ZIP..."
mkdir -p "$TEMP_DIR/MANIFEST"
mkdir -p "$TEMP_DIR/prefs"

cp "$CA_P12_DIR/$CA_P12"       "$TEMP_DIR/truststore-root.p12"
cp "$CA_P12_DIR/$USERNAME.p12" "$TEMP_DIR/$USERNAME.p12"

# ── manifest.xml ────────────────────────────
# NOTE: The File entries use just the filename — ATAK resolves them relative
# to the ZIP root. The Preference package path must match the actual file path
# inside the ZIP (prefs/atak.pref here).
cat << EOF > "$TEMP_DIR/MANIFEST/manifest.xml"
<?xml version='1.0' encoding='ASCII' standalone='yes'?>
<MissionPackageManifest version="2">
  <Configuration>
    <Parameter name="uid" value="${USERNAME}-$(date +%s)"/>
    <Parameter name="name" value="${USERNAME} TAK Enrollment"/>
    <Parameter name="onReceiveImport" value="true"/>
    <Parameter name="onReceiveDelete" value="false"/>
  </Configuration>
  <Contents>
    <Content ignore="false" zipEntry="truststore-root.p12"/>
    <Content ignore="false" zipEntry="${USERNAME}.p12"/>
    <Content ignore="false" zipEntry="prefs/atak.pref"/>
  </Contents>
</MissionPackageManifest>
EOF

# ── atak.pref ────────────────────────────────
# ATAK reads the cert files from its internal cert store after import.
# certificateLocation and caLocation must be just the filename — ATAK will
# resolve these against its cert directory (atak/cert/) automatically when
# the data package is imported via Import Manager.
#
# The preference element name for network streams must be exactly
# "com.atakmap.app_preferences" (note: no trailing 's').

# ── atak.pref ────────────────────────────────
# Two separate preference blocks:
#   cot_streams      — connection string only, keys use index-as-SUFFIX (connectString0, not 0_connectString)
#   com.atakmap.app_preferences — cert paths (absolute), callsign, display, profile keys
# Cert paths must be absolute to the ATAK cert store on the device.
# ATAK places imported p12 files into /storage/emulated/0/atak/cert/
ATAK_CERT_DIR="/storage/emulated/0/atak/cert"

{
  echo "<?xml version='1.0' encoding='ASCII' standalone='yes'?>"
  echo "<preferences>"

  # ── cot_streams block ────────────────────────────────────────────────
  echo "  <preference version=\"1\" name=\"cot_streams\">"
  echo "    <entry key=\"count\" class=\"class java.lang.Integer\">1</entry>"
  echo "    <entry key=\"description0\" class=\"class java.lang.String\">Field Server</entry>"
  echo "    <entry key=\"enabled0\" class=\"class java.lang.Boolean\">true</entry>"
  echo "    <entry key=\"connectString0\" class=\"class java.lang.String\">$SERVER_IP:$COT_PORT:$COT_PROTOCOL</entry>"
  echo "  </preference>"

  # ── com.atakmap.app_preferences block ───────────────────────────────
  echo "  <preference version=\"1\" name=\"com.atakmap.app_preferences\">"
  echo "    <entry key=\"locationCallsign\" class=\"class java.lang.String\">$CALLSIGN</entry>"
  echo "    <entry key=\"coord_display_pref\" class=\"class java.lang.String\">MGRS</entry>"
  echo "    <entry key=\"alt_display_pref\" class=\"class java.lang.String\">MSL</entry>"
  echo "    <entry key=\"displayServerConnectionWidget\" class=\"class java.lang.Boolean\">true</entry>"
  echo "    <entry key=\"certificateLocation\" class=\"class java.lang.String\">$ATAK_CERT_DIR/${USERNAME}.p12</entry>"
  echo "    <entry key=\"clientPassword\" class=\"class java.lang.String\">$CLIENT_PASS</entry>"
  echo "    <entry key=\"caLocation\" class=\"class java.lang.String\">$ATAK_CERT_DIR/truststore-root.p12</entry>"
  echo "    <entry key=\"caPassword\" class=\"class java.lang.String\">$CA_PASS</entry>"

  # Profile-specific keys
  case "$PROFILE" in
    basic)
      echo "    <entry key=\"allowNetworkSetting\" class=\"class java.lang.Boolean\">false</entry>"
      ;;
    advanced)
      echo "    <entry key=\"allowNetworkSetting\" class=\"class java.lang.Boolean\">true</entry>"
      ;;
    admin)
      echo "    <entry key=\"allowNetworkSetting\" class=\"class java.lang.Boolean\">true</entry>"
      if [ -n "$ADMIN_PIN" ]; then
        echo "    <entry key=\"atakAdminPassword\" class=\"class java.lang.String\">$ADMIN_PIN</entry>"
      fi
      ;;
  esac

  echo "  </preference>"
  echo "</preferences>"
} > "$TEMP_DIR/prefs/atak.pref"

# ─────────────────────────────────────────────
# Step 4: Zip and place
# ─────────────────────────────────────────────
cd "$TEMP_DIR"
if [[ "$PROTECT_ZIP" == "y" ]]; then
  zip -r -P "$IMPORT_PASS" "../$USERNAME.zip" MANIFEST prefs "truststore-root.p12" "$USERNAME.p12"
else
  zip -r "../$USERNAME.zip" MANIFEST prefs "truststore-root.p12" "$USERNAME.p12"
fi
cd ..
rm -rf "$TEMP_DIR"

mv "$USERNAME.zip" "$NEW_CERTS_DIR/"

echo "─────────────────────────────────────────────"
echo " Data package created: $NEW_CERTS_DIR/$USERNAME.zip"
echo " Profile: $PROFILE | Callsign: $CALLSIGN | Server: $SERVER_IP:$COT_PORT"
echo " Cert/ZIP password: $IMPORT_PASS | ZIP protected: ${PROTECT_ZIP:-n}"
echo "─────────────────────────────────────────────"
echo " Next steps:"
echo "  1. Run ./scripts/shareCerts.sh to serve over HTTP"
echo "  2. On device: ATAK → Import Manager → Import from Network/File → select $USERNAME.zip"
echo "     (Use 'Import Manager', NOT Settings → Network → Server List — the ZIP handles everything)"
echo "  3. After user downloads: ./scripts/activate_or_archive_user.sh"
echo "─────────────────────────────────────────────"

read -p "Start sharing now? [y/N]: " START_SHARE
if [[ "${START_SHARE,,}" != "y" ]]; then
  echo "Done. Run ./scripts/shareCerts.sh manually when ready to share."
  exit 0
fi

echo ""
echo "WARNING: UNAUTHENTICATED USERS CAN NOW FETCH CERTIFICATES. THIS IS RISKY."
echo "Starting share server on port 12345..."
cd "$NEW_CERTS_DIR"
python3 -m http.server 12345 &
SHARE_PID=$!
cd - > /dev/null

echo ""
echo "Share server running. Press any key to stop sharing..."
read -n 1 -s -r < /dev/tty
kill "$SHARE_PID" 2>/dev/null || true
wait "$SHARE_PID" 2>/dev/null || true
echo "Share server stopped."

echo ""
read -p "Move $USERNAME.zip out of share folder into ./tak/certs/files/Active_Users? [y/N]: " MOVE_ZIP < /dev/tty
if [[ "${MOVE_ZIP,,}" == "y" ]]; then
  mkdir -p "./tak/certs/files/Active_Users"
  mv "$NEW_CERTS_DIR/$USERNAME.zip" "./tak/certs/files/Active_Users/$USERNAME.zip"
  echo "Moved to ./tak/certs/files/Active_Users/$USERNAME.zip"
fi

echo ""
echo "Done."