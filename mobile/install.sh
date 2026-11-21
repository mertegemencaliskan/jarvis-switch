#!/bin/bash
# Install or update the companion for the current macOS login.
set -euo pipefail
umask 077

if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "Usage: bash mobile/install.sh CRON_DB SESSION_DB [INTERFACE [PORT]]" >&2
  exit 2
fi
cron_db="$1"
session_db="$2"
interface="${3:-en0}"
port="${4:-8768}"
if [[ ! -r "$cron_db" || ! -r "$session_db" ]]; then
  echo "OpenClaw scheduler and session databases must be readable." >&2
  exit 2
fi

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
install_dir="$HOME/Library/Application Support/jarvis_switch_mobile"
label="com.jarvis.switch.mobile"
plist="$HOME/Library/LaunchAgents/$label.plist"
hostname="$(/usr/sbin/scutil --get LocalHostName).local"
started_from="gui/$(id -u)"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

bash "$repo_dir/scripts/build.sh" "$staging"
/usr/bin/swift "$repo_dir/mobile/make_icons.swift" "$staging/icons"
/bin/mkdir -p "$install_dir/web/icons" "$HOME/Library/LaunchAgents"
/usr/bin/install -m 600 "$repo_dir/mobile/server.py" "$install_dir/server.py"
/usr/bin/install -m 600 "$repo_dir"/mobile/web/* "$install_dir/web/"
/usr/bin/install -m 600 "$staging"/icons/*.png "$install_dir/web/icons/"
/usr/bin/ditto "$staging/JarvisSwitch.app" "$install_dir/JarvisSwitch.app"

/usr/bin/python3 - "$install_dir" "$plist" "$label" "$cron_db" "$session_db" "$interface" "$port" "$hostname" <<'PY'
import pathlib
import plistlib
import secrets
import sys

root, plist, label, cron_db, session_db, interface, port, hostname = sys.argv[1:]
root = pathlib.Path(root)
try:
    with (root / "viewer_key").open("x") as key:
        key.write(secrets.token_urlsafe(32) + "\n")
except FileExistsError:
    pass
(root / "viewer_key").chmod(0o600)
job = {
    "Label": label,
    "ProgramArguments": [
        "/usr/bin/python3", str(root / "server.py"),
        "--interface", interface, "--port", port, "--hostname", hostname,
        "--cron-db", cron_db, "--session-db", session_db,
    ],
    "RunAtLoad": True,
    "KeepAlive": True,
    "ThrottleInterval": 10,
    "StandardErrorPath": str(root / "service.log"),
}
plist = pathlib.Path(plist)
temporary = plist.with_suffix(".tmp")
temporary.write_bytes(plistlib.dumps(job))
temporary.replace(plist)
PY

if /bin/launchctl print "$started_from/$label" >/dev/null 2>&1; then
  /bin/launchctl bootout "$started_from/$label"
fi
/bin/launchctl bootstrap "$started_from" "$plist"
echo "Jarvis Switch companion is listening on http://$hostname:$port/"
