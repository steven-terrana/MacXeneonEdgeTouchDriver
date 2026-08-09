#!/bin/sh
set -eu

label="com.ajvwhite.MacXeneonEdgeTouchDriver"
binary_name="MacXeneonEdgeTouchDriver"
package_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
app_support_dir="${HOME}/Library/Application Support/MacXeneonEdgeTouchDriver"
bin_dir="${app_support_dir}/bin"
log_dir="${HOME}/Library/Logs/MacXeneonEdgeTouchDriver"
launch_agents_dir="${HOME}/Library/LaunchAgents"
plist_template="${package_root}/Resources/com.ajvwhite.MacXeneonEdgeTouchDriver.plist.template"
plist_path="${launch_agents_dir}/${label}.plist"
installed_binary="${bin_dir}/${binary_name}"
config_path="${app_support_dir}/config.json"
driver_log_path="${log_dir}/driver.log"
uid="$(id -u)"

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[\/&]/\\&/g'
}

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift toolchain not found. Install Xcode or Command Line Tools, then rerun this script." >&2
  exit 1
fi

if [ ! -f "$plist_template" ]; then
  echo "LaunchAgent template not found: ${plist_template}" >&2
  exit 1
fi

echo "Building ${binary_name} in release mode..."
swift build -c release --package-path "$package_root"

mkdir -p "$bin_dir" "$log_dir" "$launch_agents_dir"

built_binary="${package_root}/.build/release/${binary_name}"

# Sign with a stable identity when available so macOS permission grants
# (Accessibility, Input Monitoring) survive rebuilds. Ad-hoc signatures change
# with every build, which invalidates prior grants.
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "Signing with identity: ${CODESIGN_IDENTITY}"
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$built_binary"
fi

# Skip replacing an identical binary so unchanged reinstalls keep the existing
# permission grants.
if [ -f "$installed_binary" ] && cmp -s "$built_binary" "$installed_binary"; then
  echo "Installed binary is already up to date; keeping existing binary and permission grants."
else
  install -m 755 "$built_binary" "$installed_binary"
  # New binary identity: allow exactly one fresh permission prompt.
  rm -f "${app_support_dir}/.permission-prompt-shown"
  if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    echo "NOTE: binary changed and is ad-hoc signed. macOS will treat it as a new app;"
    echo "      re-grant Accessibility and Input Monitoring (toggle off and on) for:"
    echo "      ${installed_binary}"
  fi
fi

touch "${log_dir}/stdout.log" "${log_dir}/stderr.log" "$driver_log_path"

if [ ! -f "$config_path" ]; then
  cat > "$config_path" <<EOF
{
  "logLevel": "info",
  "timing": {
    "warpToClickDelayMs": 10,
    "downToUpDelayMs": 20,
    "clickToWarpBackDelayMs": 10,
    "tapDebounceMs": 50,
    "stuckGestureTimeoutMs": 2000
  },
  "display": {
    "vendorNumber": 3672,
    "modelNumber": 60672,
    "serialNumber": null,
    "expectedWidth": 2560,
    "expectedHeight": 720
  },
  "gesture": {
    "multiTouchEnabled": false
  },
  "diagnostics": {
    "fileLogPath": "${driver_log_path}",
    "fileLogMaxBytes": 5242880
  }
}
EOF
fi

escaped_binary="$(escape_sed_replacement "$installed_binary")"
escaped_log_dir="$(escape_sed_replacement "$log_dir")"
sed \
  -e "s/__BIN_PATH__/${escaped_binary}/g" \
  -e "s/__LOG_DIR__/${escaped_log_dir}/g" \
  "$plist_template" > "$plist_path"

launchctl bootout "gui/${uid}/${label}" >/dev/null 2>&1 || true
launchctl bootstrap "gui/${uid}" "$plist_path"
launchctl enable "gui/${uid}/${label}" >/dev/null 2>&1 || true
launchctl kickstart -k "gui/${uid}/${label}" >/dev/null 2>&1 || true

cat <<EOF
Installed ${binary_name}.

LaunchAgent:
  ${plist_path}

Binary:
  ${installed_binary}

Logs:
  ${log_dir}
  ${driver_log_path}

LaunchAgent stdout/stderr:
  ${log_dir}/stdout.log
  ${log_dir}/stderr.log

Grant macOS permissions to the installed binary, or to the app that launches it if macOS attributes permissions there:
  - Input Monitoring
  - Accessibility

Config file location:
  ${config_path}
EOF
