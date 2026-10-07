#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -u

fail=0
config="${1:-${XDG_CONFIG_HOME:-$HOME/.config}/sharepoint-sync/projects.json}"

echo "SharePoint Linux Sync doctor"
echo

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  echo "OS: ${PRETTY_NAME:-unknown}"
  if [[ "${ID:-}" != "fedora" ]]; then
    echo "WARN: initial release supports Fedora only"
  fi
else
  echo "FAIL: /etc/os-release missing"; fail=1
fi

if command -v pwsh >/dev/null 2>&1; then
  version="$(pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null | tr -d '\r' | tail -n1)"
  echo "PowerShell: $version"
else
  echo "FAIL: pwsh not found"; fail=1
fi

if command -v pwsh >/dev/null 2>&1 && pwsh -NoLogo -NoProfile -NonInteractive -Command 'Import-Module Microsoft.Graph.Authentication -ErrorAction Stop' >/dev/null 2>&1; then
  echo "Microsoft.Graph.Authentication: OK"
else
  echo "FAIL: Microsoft.Graph.Authentication cannot be imported"; fail=1
fi

if [[ -f "$config" ]]; then
  echo "Config: $config"
  validator="${XDG_DATA_HOME:-$HOME/.local/share}/sharepoint-sync/validate-config.py"
  if [[ -x "$validator" ]]; then
    python3 "$validator" "$config" || fail=1
  else
    echo "WARN: installed config validator not found"
  fi
else
  echo "WARN: config not found: $config"
fi

if systemctl --user status sharepoint-sync.timer >/dev/null 2>&1; then
  echo "systemd timer: active"
else
  echo "systemd timer: inactive or not installed"
fi

exit "$fail"
