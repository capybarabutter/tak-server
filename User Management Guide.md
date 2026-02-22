# TAK Server User Management Guide

> **Two-part guide:** Jump to [Quick Reference](#quick-reference) if you just need to remember the commands. Read [Full Guide](#full-guide) if it's been a while or you need to understand what's happening under the hood.

---

# Quick Reference

## Prerequisites (both scripts)
- Be in the tak-server wrapper root (directory containing `docker-compose.yml`)
- TAK container must be running: `docker compose ps`
- Scripts must be executable: `chmod +x create_tak_user.sh revoke_user.sh`

---

## Create a User

```bash
./create_tak_user.sh
```

**Prompts you'll answer:**
| Prompt | Notes |
|---|---|
| Username | Short, no spaces — becomes the cert CN and TAK login |
| Callsign | Displayed in ATAK; defaults to username if blank |
| Password (x2) | Protects the `.p12` and (optionally) the ZIP |
| ZIP password protect? | `y/N` — not supported by all ATAK versions; usually skip |
| Server IP/hostname | Must be reachable from the client's network |
| CA truststore password | Press Enter for default `atakatak` |
| Group name | Optional; group must already exist in Web UI |
| Profile (1/2/3) | Basic / Advanced / Admin |
| Admin PIN | Admin profile only; locks ATAK settings |
| Start sharing now? | Launches HTTP server on port 12345 |

**Output:** `./tak/certs/files/share/<username>.zip`

**If you answered `y` to "Start sharing now?":**
The script starts its own HTTP server on port 12345 and waits. Once the user has downloaded their ZIP, **press any key** to stop the server. The script then asks whether to move the ZIP to `./tak/certs/files/Active_Users/` — answer `y`.

**If you answered `n` (or skipped) — share and move manually later:**
```bash
./scripts/shareCerts.sh                        # HTTP server on :12345 — Ctrl+C to stop when done
mkdir -p ./tak/certs/files/Active_Users
mv ./tak/certs/files/share/<username>.zip ./tak/certs/files/Active_Users/
```

**Grant admin rights after the fact:**
```bash
docker compose exec tak java -jar /opt/tak/utils/UserManager.jar certmod -A /opt/tak/certs/files/<username>.pem
```

---

## Revoke a User

> ⚠️ **SERVICE DISRUPTION WARNING**
> `revoke_user.sh` calls `configureInDocker.sh` at the end, which **restarts internal TAK services**. Marti will be **offline for 1–4 minutes**. All connected clients will drop and reconnect. **Do not run this during an active mission if loss of situational awareness is unacceptable.**

```bash
./revoke_user.sh
```

**Prompts you'll answer:**
| Prompt | Notes |
|---|---|
| Username to revoke | Must match the original username exactly |
| CA password | Press Enter for default `atakatak` |
| Confirm with `yes` | Irreversible — deletes certs, DB entry, and all files |

**The script will:**
1. Revoke the certificate (CRL)
2. Remove the user from the TAK database
3. Delete all associated files from certs/share/active directories
4. Apply the CRL via `configureInDocker.sh` (triggers service restart)
5. Wait and confirm Marti comes back up on port 8443

---

### During-Mission Alternatives to Full Revocation

If you need to block a user without the service restart, use one of these instead:

**Option A — Disable the account in the Web UI (no restart needed):**
Web UI → Administrative → Manage Users → find user → Disable

**Option B — Remove from groups only (limits access, no restart):**
Web UI → Administrative → Manage Groups → remove user from relevant groups

**Option C — Manual DB removal only (no CRL, no restart):**
```bash
docker compose exec tak java -jar /opt/tak/utils/UserManager.jar usermod -D <username>
```
> Note: Without CRL application, the certificate itself remains technically valid. Run `revoke_user.sh` after the mission to fully purge.

---

# Full Guide

## Overview

| Script | Purpose |
|---|---|
| `create_tak_user.sh` | Generates a cert, registers the user in TAK's DB, and packages everything into a ready-to-import ZIP |
| `revoke_user.sh` | Revokes the cert, removes the DB entry, deletes all files, and pushes the CRL to TAK |

Both scripts must be run from the **tak-server wrapper root** — the directory containing `docker-compose.yml` and the `./tak/` folder. The TAK Docker container must be running and healthy before either script will work.

---

## create_tak_user.sh — Full Walkthrough

### What It Does (Step by Step)

**Step 1 — Certificate generation**

The script calls `makeCert.sh` inside the container, which creates:
- `<username>.pem` — the user's certificate (public)
- `<username>.key` — the private key
- `<username>.p12` — the PKCS#12 bundle (cert + key, password-protected)

After generation, the script **re-encrypts the `.p12`** with the password you provided. This is necessary because `makeCert.sh` always seals the `.p12` with the CA password regardless of input. The re-encryption uses legacy-compatible ciphers (`PBE-SHA1-3DES`) and SHA1 MAC, which is required because ATAK's Java runtime rejects the OpenSSL 3 default (SHA-256 MAC).

> ⚠️ **Limitation:** If you skip the CA truststore password (accept default `atakatak`) but your setup was initialized with a different CA password, re-encryption will fail. Always use the actual CA password you set during initial server setup.

**Step 2 — Database registration**

`UserManager.jar certmod` registers the certificate's fingerprint in TAK's database. If a group was specified, the `-g` flag adds the user to that group. If the Admin profile was selected, the `-A` flag grants admin rights. The group must already exist — the script cannot create groups; do that first in the Web UI under Administrative → Manage Groups.

**Step 3 — Data package assembly**

The script creates a Mission Package ZIP containing:
- `truststore-root.p12` — the CA truststore so the client can verify the server's cert
- `<username>.p12` — the user's client certificate
- `prefs/atak.pref` — pre-configured preferences
- `MANIFEST/manifest.xml` — tells ATAK what to import and how

The `atak.pref` file is split into two separate preference blocks:
- `cot_streams` — configures the server connection string (`IP:port:ssl`)
- `com.atakmap.app_preferences` — sets callsign, cert paths, passwords, display units, and profile-specific settings

Cert paths in the pref file are absolute paths to ATAK's internal cert store (`/storage/emulated/0/atak/cert/`). ATAK places imported `.p12` files there automatically when the data package is imported via Import Manager.

> ⚠️ **Limitation:** These absolute paths are Android-specific. If the user is on **WinTAK or iTAK**, cert paths will differ. The current script targets Android/ATAK. WinTAK and iTAK users may need manual cert configuration after import.

**Step 4 — ZIP packaging and placement**

The ZIP is created from a temporary directory (`./temp_user_create/`) and placed into `./tak/certs/files/share/`. The temp directory is cleaned up automatically.

If ZIP password protection was selected (`y` at the prompt), the ZIP is encrypted with the same password as the `.p12`. **Note:** Not all ATAK versions support password-protected ZIPs in Import Manager. When in doubt, skip ZIP protection — the `.p12` itself is always password-protected regardless.

### Profiles

| Profile | What Changes |
|---|---|
| **Basic** | `allowNetworkSetting = false` — user cannot modify server connections in ATAK |
| **Advanced** | `allowNetworkSetting = true` — user can modify network/server settings |
| **Admin** | Same as Advanced + `-A` flag in UserManager (admin cert) + optional `atakAdminPassword` PIN to lock ATAK settings |

### Sharing the Data Package

After the script completes, it asks: **"Start sharing now? [y/N]"**

**If you answer `y`:**
The script launches its own HTTP server on port 12345 (`python3 -m http.server`), serving the `./tak/certs/files/share/` directory. It then waits — printing the server address and telling you to press any key when done. On the client device, open a browser, go to `http://<server-ip>:12345`, and download `<username>.zip`. Once the user has their file, **press any key** (not Ctrl+C) at the terminal to stop the server. The script then asks:

> **"Move `<username>.zip` out of share folder into `./tak/certs/files/Active_Users`? [y/N]"**

Answer `y`. The script creates the `Active_Users` directory if needed and moves the ZIP there, removing it from the share folder so it's no longer accessible over HTTP.

**If you answer `n` (or press Enter to skip):**
The script exits immediately with a reminder to run `./scripts/shareCerts.sh` manually. The ZIP stays in `./tak/certs/files/share/` until you move it yourself. When you're ready:

```bash
./scripts/shareCerts.sh   # Ctrl+C to stop when the user has downloaded their ZIP
mkdir -p ./tak/certs/files/Active_Users
mv ./tak/certs/files/share/<username>.zip ./tak/certs/files/Active_Users/
```

**Importing on the client — both paths:**
In ATAK: **Import Manager → Import File → select the ZIP**

> ⚠️ **Do NOT use** Settings → Network → Server List to import. The data package must go through Import Manager to correctly install certs, trust the CA, and apply preferences.

> ⚠️ **Security note:** The HTTP share server (whether launched by the script or `shareCerts.sh`) is unauthenticated plaintext. Only run it on a trusted LAN, and always move the ZIP out of the share folder after delivery.

### Known Limitations

- **Android/ATAK targeted** — cert paths in `atak.pref` are hardcoded to Android's filesystem. WinTAK/iTAK may need manual cert import.
- **ZIP password support** — inconsistent across ATAK versions. Prefer leaving ZIP unprotected; the `.p12` is always protected.
- **Groups must pre-exist** — the script cannot create groups. Create them first in Web UI → Administrative → Manage Groups.
- **One server connection configured** — the pref file writes a single `cot_streams` entry. For multi-server setups, additional connections must be added manually in ATAK after enrollment.
- **Re-encryption requires `openssl` on the host** — not inside the container. The host must have OpenSSL 3+ installed.
- **`makeCert.sh` ignores stdin** — the CA password prompt inside the container is always answered with the CA password, not the user's chosen password. Re-encryption is the mechanism that applies the user password to the `.p12`.

---

## revoke_user.sh — Full Walkthrough

### What It Does (Step by Step)

**Step 1 — Certificate revocation**

Calls `revokeCert.sh` inside the container, which adds the certificate's serial number to the Certificate Revocation List (CRL). The CA password is piped into `revokeCert.sh` stdin to avoid a hang. If the `.pem` file doesn't exist inside the container (e.g., already cleaned up), this step is skipped with a warning rather than failing.

**Step 2 — Database removal**

Runs `UserManager.jar usermod -D <username>` to remove the user's entry from TAK's database. If the user was already absent, this exits cleanly without error.

**Step 3 — File cleanup**

Searches for and deletes all files matching `<username>*` in three locations:
- `./tak/certs/files/` — cert files (`.pem`, `.p12`, `.key`, `.csr`, etc.)
- `./tak/certs/files/share/` — data package ZIP (if still in share folder)
- `./tak/certs/files/active_users/` — data package ZIP (if moved to active folder)

> ⚠️ This is permanent. There is no undo.

**Step 4 — CRL application**

Runs `configureInDocker.sh` inside the container. This pushes the updated CRL to Marti, which is what actually blocks the revoked certificate from connecting. **This step restarts Marti's internal services**, causing a 1–4 minute outage for all connected clients.

**Step 5 — Health check**

The script polls port 8443 every 5 seconds for up to 240 seconds, printing elapsed time until Marti responds. If Marti hasn't recovered after ~110 seconds it prints a warning. If it hasn't recovered after 240 seconds, it provides manual recovery steps:

```bash
docker compose restart tak
docker compose logs -f tak
docker compose down && docker compose up -d   # Full cycle if needed
```

### Why the Service Disruption Happens

`configureInDocker.sh` is TAK's mechanism for applying configuration changes — including CRL updates — to a running instance. It is not possible to push a CRL update to TAK without restarting Marti's services in the current wrapper setup. This is a TAK Server architecture constraint, not a script limitation.

### During-Mission Alternatives (Detailed)

If you need to block access without the restart, these options are available in order of increasing permanence:

**Web UI Disable (Recommended for during mission)**
Web UI → Administrative → Manage Users → locate the user → click Disable. This immediately prevents authentication without touching services or certificates. Reversible. Run full revocation after the mission.

**Group removal only**
Removes the user from all groups, which may limit what data/layers they can see depending on your TAK server configuration. Does not prevent connection. Useful if you want to isolate rather than fully block.

**Manual DB delete (no CRL)**
```bash
docker compose exec tak java -jar /opt/tak/utils/UserManager.jar usermod -D <username>
```
Removes the TAK user account but does **not** revoke the certificate. The user's ATAK client may still be able to establish a TLS connection (cert is valid) even if the account doesn't exist in the DB — behavior depends on your TAK server's authentication policy. Treat this as partial and always follow up with full revocation post-mission.

> **Bottom line:** For during-mission, disable via Web UI. Run `revoke_user.sh` afterward for full cryptographic revocation and file cleanup.

### Known Limitations

- **Service disruption is unavoidable** for full CRL-based revocation — TAK requires a Marti restart to apply CRL changes.
- **Timeout handling** — all `docker exec` calls have a 30-second timeout with a 5-second kill-after. If the container is slow or stalled, steps may be logged as warnings and skipped rather than causing the script to abort. Check the output carefully.
- **`revokeCert.sh` path assumptions** — the script assumes cert files use the standard naming convention (`<username>.pem`, etc.) and are located at `/opt/tak/certs/files/` inside the container. Custom setups may need path edits in the config block at the top of the script.
- **File cleanup scope** — cleanup only searches `./tak/certs/files/`, `./tak/certs/files/share/`, and `./tak/certs/files/active_users/`. If you manually moved files elsewhere, you'll need to clean them up manually.
- **The `active_users` directory name** — the script uses `active_users` (lowercase). If your directory is named differently (e.g., `Active_Users`), edit the `ACTIVE_DIR` variable at the top of the script.

---

## Configurable Variables

Both scripts have a config block near the top. Adjust these if your setup differs from defaults:

### create_tak_user.sh
| Variable | Default | Notes |
|---|---|---|
| `CONTAINER_NAME` | `tak` | Docker container name — check with `docker compose ps` |
| `NEW_CERTS_DIR` | `./tak/certs/files/share` | Where the output ZIP goes |
| `CA_P12` | `truststore-root.p12` | CA truststore filename |
| `CA_P12_DIR` | `./tak/certs/files/` | Host path to CA truststore |
| `CA_PASS` | `atakatak` | Default CA password (overridden at prompt) |
| `COT_PORT` | `8089` | Server port written into `atak.pref` |
| `COT_PROTOCOL` | `ssl` | Protocol written into `atak.pref` |

### revoke_user.sh
| Variable | Default | Notes |
|---|---|---|
| `CONTAINER_NAME` | `tak` | Docker container name |
| `CERTS_DIR` | `./tak/certs/files` | Main cert directory on host |
| `SHARE_DIR` | `./tak/certs/files/share` | Share directory for cleanup |
| `ACTIVE_DIR` | `./tak/certs/files/active_users` | Active users directory for cleanup |
| `CA_PASS` | `atakatak` | Default CA password (overridden at prompt) |
| `CA_KEY` | `ca-do-not-share` | CA key basename (no extension) |
| `CA_CERT` | `root-ca` | CA cert basename (no extension) |
| `DOCKER_EXEC_TIMEOUT` | `30` | Seconds before a container command times out |
| `MARTI_PORT` | `8443` | Port polled to confirm Marti recovery |
| `HEALTHY_TIMEOUT` | `240` | Max seconds to wait for Marti recovery |

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `command not found` when running script | `chmod +x <script>.sh` |
| `No such container` error | Check container name: `docker compose ps`. Edit `CONTAINER_NAME` in script if needed. |
| Cert generation hangs | Container not running or unhealthy. `docker compose ps` and `docker compose logs tak`. |
| User connects but can't see data | Group assignment issue. Check Web UI → Administrative → Manage Groups. |
| User can't connect after enrollment | Check `docker compose logs tak | grep -i cert`. Verify cert paths in ATAK Import Manager. |
| Re-encryption fails | Mismatch between CA password and what you entered. Also ensure `openssl` 3+ is installed on the host. |
| Marti doesn't recover after revoke | `docker compose restart tak` → wait 2 min → check `docker compose logs -f tak` |
| Files not cleaned up after revoke | Manually check `./tak/certs/files/` and subdirectories. `active_users` directory name may differ — edit `ACTIVE_DIR` in script. |
| ATAK shows "certificate not trusted" | CA truststore not imported correctly. Re-import the data package via Import Manager (not via server settings). |