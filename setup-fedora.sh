#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

APP_NAME="sharepoint-sync"
MIN_PWSH_MAJOR=7
MIN_PWSH_MINOR=6
DEFAULT_INTERVAL=15
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
INSTALL_DIR="$DATA_HOME/$APP_NAME"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$CONFIG_HOME/$APP_NAME"
SYSTEMD_DIR="$CONFIG_HOME/systemd/user"
CONFIG_SOURCE=""
INTERVAL_MINUTES="$DEFAULT_INTERVAL"
ASSUME_YES=0
DO_AUTH=1
DO_ENABLE=1
DO_LINGER=0

usage() {
  cat <<USAGE
Usage: ./setup-fedora.sh [options]

Options:
  --config PATH       Install a private projects.json from PATH.
  --interval MINUTES  Systemd sync interval (default: ${DEFAULT_INTERVAL}).
  --no-auth           Skip interactive Microsoft Graph authentication.
  --no-enable         Install systemd files but do not enable the timer.
  --enable-linger     Enable user lingering (requires sudo/polkit approval).
  -y, --yes           Accept installer prompts where safe.
  -h, --help          Show this help.

The installer is intentionally Fedora-only for the initial release.
USAGE
}

say() { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

ask_yes_no() {
  local prompt="$1" default="${2:-y}" answer
  if (( ASSUME_YES )); then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    [[ "$default" == "y" ]]
    return
  fi
  if [[ "$default" == "y" ]]; then
    read -r -p "$prompt [Y/n] " answer || true
    answer="${answer:-y}"
  else
    read -r -p "$prompt [y/N] " answer || true
    answer="${answer:-n}"
  fi
  [[ "$answer" =~ ^[Yy]$ ]]
}

while (($#)); do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || die "--config requires a path"
      CONFIG_SOURCE="$2"; shift 2 ;;
    --interval)
      [[ $# -ge 2 ]] || die "--interval requires minutes"
      INTERVAL_MINUTES="$2"; shift 2 ;;
    --no-auth) DO_AUTH=0; shift ;;
    --no-enable) DO_ENABLE=0; shift ;;
    --enable-linger) DO_LINGER=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ "$INTERVAL_MINUTES" =~ ^[1-9][0-9]*$ ]] || die "--interval must be a positive integer"
(( INTERVAL_MINUTES <= 1440 )) || die "--interval must be <= 1440 minutes"

[[ -r /etc/os-release ]] || die "/etc/os-release not found"
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "fedora" ]] || die "This installer currently supports Fedora only (detected: ${ID:-unknown})"
[[ "$(uname -m)" == "x86_64" ]] || die "Initial Fedora installer currently supports x86_64 only"
[[ "$EUID" -ne 0 ]] || die "Run this installer as your normal user, not as root"

command -v sudo >/dev/null 2>&1 || die "sudo is required to install system packages"

say "Installing base dependencies"
sudo dnf install -y curl ca-certificates python3 git

version_ge_76() {
  local version="$1" major minor
  major="${version%%.*}"
  minor="${version#*.}"; minor="${minor%%.*}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
  (( major > MIN_PWSH_MAJOR || (major == MIN_PWSH_MAJOR && minor >= MIN_PWSH_MINOR) ))
}

install_latest_powershell_rpm() {
  local tmp release_json rpm_url hashes_url rpm_file hashes_file expected_line
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  release_json="$tmp/release.json"
  rpm_file="$tmp/powershell.rpm"
  hashes_file="$tmp/hashes.sha256"

  say "Discovering latest stable PowerShell RPM from the official PowerShell GitHub release"
  curl -fsSL --retry 3 --retry-delay 2 \
    https://api.github.com/repos/PowerShell/PowerShell/releases/latest \
    -o "$release_json"

  readarray -t urls < <(python3 - "$release_json" <<'PY'
import json, re, sys
release = json.load(open(sys.argv[1], encoding="utf-8"))
rpm = None
rpm_digest = None
hashes = None
for asset in release.get("assets", []):
    name = asset.get("name", "")
    url = asset.get("browser_download_url")
    if re.fullmatch(r"powershell-[0-9][^-]*-[0-9]+\.rh\.x86_64\.rpm", name):
        rpm = url
    elif name == "hashes.sha256":
        hashes = url
if not rpm or (not rpm_digest and not hashes):
    raise SystemExit("required PowerShell release assets not found")
print(rpm)
print(hashes or "")
print(rpm_digest or "")
PY
  )

  rpm_url="${urls[0]:-}"
  hashes_url="${urls[1]:-}"
  expected_hash="${urls[2]:-}"
  [[ -n "$rpm_url" ]] || die "Could not determine PowerShell RPM release asset"

  curl -fsSL --retry 3 --retry-delay 2 "$rpm_url" -o "$rpm_file"

  if [[ -z "$expected_hash" ]]; then
    [[ -n "$hashes_url" ]] || die "No SHA-256 digest or hashes.sha256 asset was published for the PowerShell RPM"
    curl -fsSL --retry 3 --retry-delay 2 "$hashes_url" -o "$hashes_file"
    expected_line="$(grep -F "$(basename "$rpm_url")" "$hashes_file" | head -n1 || true)"
    [[ -n "$expected_line" ]] || die "No checksum found for downloaded PowerShell RPM"
    expected_hash="$(awk '{print $1}' <<<"$expected_line")"
  fi

  [[ "$expected_hash" =~ ^[0-9A-Fa-f]{64}$ ]] || die "Invalid SHA-256 checksum for downloaded PowerShell RPM"
  printf '%s  %s\n' "${expected_hash,,}" "$rpm_file" | sha256sum -c -
  sudo dnf install -y "$rpm_file"
  rm -rf "$tmp"
  trap - RETURN
}

pwsh_version=""
if command -v pwsh >/dev/null 2>&1; then
  pwsh_version="$(pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null | tr -d '\r' | tail -n1)"
fi

if [[ -z "$pwsh_version" ]] || ! version_ge_76 "$pwsh_version"; then
  say "PowerShell 7.6+ is required (found: ${pwsh_version:-none})"
  if ! sudo dnf install -y powershell; then
    warn "Fedora repositories did not provide PowerShell; using the official universal RPM release"
    install_latest_powershell_rpm
  fi
  pwsh_version="$(pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' | tr -d '\r' | tail -n1)"
  if ! version_ge_76 "$pwsh_version"; then
    warn "Installed PowerShell is still $pwsh_version; upgrading from the official release RPM"
    install_latest_powershell_rpm
    pwsh_version="$(pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' | tr -d '\r' | tail -n1)"
  fi
fi
version_ge_76 "$pwsh_version" || die "PowerShell 7.6+ is required; found $pwsh_version"
say "PowerShell $pwsh_version is available"

say "Installing Microsoft.Graph.Authentication for the current user"
pwsh -NoLogo -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "Stop"
$repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
if (-not $repo) { Register-PSRepository -Default; $repo = Get-PSRepository -Name PSGallery }
$originalPolicy = $repo.InstallationPolicy
try {
    if ($originalPolicy -ne "Trusted") { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted }
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
}
finally {
    if ($originalPolicy -ne "Trusted") { Set-PSRepository -Name PSGallery -InstallationPolicy $originalPolicy }
}
Import-Module Microsoft.Graph.Authentication
$module = Get-Module Microsoft.Graph.Authentication
Write-Host "Microsoft.Graph.Authentication" $module.Version
'

say "Installing application files"
mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$CONFIG_DIR" "$SYSTEMD_DIR"
install -m 0644 "$ROOT_DIR/src/sharepoint-sync.ps1" "$INSTALL_DIR/sharepoint-sync.ps1"
install -m 0644 "$ROOT_DIR/src/sharepoint-sync-all.ps1" "$INSTALL_DIR/sharepoint-sync-all.ps1"
install -m 0755 "$ROOT_DIR/bin/sharepoint-sync" "$BIN_DIR/sharepoint-sync"
install -m 0755 "$ROOT_DIR/bin/sharepoint-sync-all" "$BIN_DIR/sharepoint-sync-all"
install -m 0755 "$ROOT_DIR/bin/sharepoint-sync-auth" "$BIN_DIR/sharepoint-sync-auth"
install -m 0755 "$ROOT_DIR/scripts/validate-config.py" "$INSTALL_DIR/validate-config.py"
install -m 0755 "$ROOT_DIR/scripts/doctor.sh" "$INSTALL_DIR/doctor.sh"
install -m 0755 "$ROOT_DIR/bin/sharepoint-sync-doctor" "$BIN_DIR/sharepoint-sync-doctor"
install -m 0644 "$ROOT_DIR/config/projects.example.json" "$CONFIG_DIR/projects.example.json"
install -m 0644 "$ROOT_DIR/config/projects.schema.json" "$CONFIG_DIR/projects.schema.json"

if [[ -n "$CONFIG_SOURCE" ]]; then
  CONFIG_SOURCE="$(realpath -e -- "$CONFIG_SOURCE")"
  python3 "$ROOT_DIR/scripts/validate-config.py" "$CONFIG_SOURCE"
  install -m 0600 "$CONFIG_SOURCE" "$CONFIG_DIR/projects.json"
  say "Installed private configuration at $CONFIG_DIR/projects.json"
elif [[ -f "$CONFIG_DIR/projects.json" ]]; then
  python3 "$ROOT_DIR/scripts/validate-config.py" "$CONFIG_DIR/projects.json"
  say "Preserving existing configuration at $CONFIG_DIR/projects.json"
else
  say "No private configuration supplied"
  printf 'Example: %s\n' "$CONFIG_DIR/projects.example.json"
  printf 'Create:  %s\n' "$CONFIG_DIR/projects.json"
fi

say "Installing user systemd service and timer"
install -m 0644 "$ROOT_DIR/systemd/sharepoint-sync.service" "$SYSTEMD_DIR/sharepoint-sync.service"
sed "s/@INTERVAL_MINUTES@/$INTERVAL_MINUTES/g" \
  "$ROOT_DIR/systemd/sharepoint-sync.timer.in" \
  > "$SYSTEMD_DIR/sharepoint-sync.timer"
chmod 0644 "$SYSTEMD_DIR/sharepoint-sync.timer"
systemctl --user daemon-reload

if (( DO_AUTH )); then
  if ask_yes_no "Authenticate to Microsoft Graph now?" y; then
    say "Starting delegated browser authentication for Files.Read.All"
    if "$BIN_DIR/sharepoint-sync-auth"; then
      say "Microsoft Graph authentication test passed"
    else
      warn "Authentication did not complete. You can retry later with: sharepoint-sync-auth"
    fi
  fi
fi

if (( DO_LINGER )); then
  say "Enabling user lingering so the timer can run without an active login session"
  sudo loginctl enable-linger "$USER"
fi

if (( DO_ENABLE )); then
  if [[ -f "$CONFIG_DIR/projects.json" ]]; then
    if ask_yes_no "Enable and start the user timer every ~${INTERVAL_MINUTES} minutes?" y; then
      systemctl --user enable --now sharepoint-sync.timer
      say "Timer enabled"
      systemctl --user list-timers sharepoint-sync.timer --no-pager || true
    fi
  else
    warn "Timer not enabled because projects.json does not exist yet"
  fi
fi

cat <<EOF2

Installation complete.

Commands:
  sharepoint-sync-auth
  sharepoint-sync-all
  sharepoint-sync-doctor
  systemctl --user start sharepoint-sync.service
  journalctl --user -u sharepoint-sync.service -f

Configuration:
  $CONFIG_DIR/projects.json

Example configuration:
  $CONFIG_DIR/projects.example.json

Local mirrors default to:
  ~/SharePoint/<project>/<remoteRoot>/

State is stored under:
  $STATE_HOME/sharepoint-sync/

Important: Files.Read.All is a broad delegated read permission. Your tenant may
require administrator approval or impose Conditional Access policies.
EOF2
