#!/usr/bin/env bash
set -euo pipefail

DEFAULT_REPO_NAME="sharepoint-linux-sync"
DEFAULT_DESCRIPTION="Read-only incremental SharePoint/Teams document sync for Linux using Microsoft Graph"
PUBLISH_IMAGE="${SHAREPOINT_SYNC_PUBLISH_IMAGE:-localhost/sharepoint-linux-sync-publisher:fedora44}"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/publish-github.sh [repository-name]

Publishes this source tree to a NEW public GitHub repository using an ephemeral
Podman container. GitHub CLI authentication is performed only inside the
container; the host's gh configuration, credential helper, HOME, and account-
wide GitHub token are neither mounted nor modified.

Environment overrides:
  SHAREPOINT_SYNC_PUBLISH_IMAGE  Container image tag to build/use.

The host needs Podman. On Fedora, if Podman is missing the script can install it
with dnf after an explicit confirmation.
USAGE
}

repo_name="${1:-$DEFAULT_REPO_NAME}"
if [[ "$repo_name" == "-h" || "$repo_name" == "--help" ]]; then
  usage
  exit 0
fi

# ---------------------------------------------------------------------------
# Inner path: runs only in the disposable publisher container.
# ---------------------------------------------------------------------------
if [[ "${SHAREPOINT_SYNC_PUBLISH_IN_CONTAINER:-0}" == "1" ]]; then
  REPO_NAME="${PUBLISH_REPO_NAME:?PUBLISH_REPO_NAME is required in container mode}"
  DESCRIPTION="${PUBLISH_DESCRIPTION:-$DEFAULT_DESCRIPTION}"

  if [[ ! -f README.md || ! -f LICENSE || ! -f setup-fedora.sh || ! -d src ]]; then
    echo "Publisher container was not started from the copied project root." >&2
    exit 2
  fi

  # Keep all GitHub CLI state inside the ephemeral container. Do not fall back
  # to any inherited HOME/XDG location even if the image defaults change later.
  export HOME="/tmp/publisher-home"
  export XDG_CONFIG_HOME="/tmp/publisher-xdg"
  export GH_CONFIG_DIR="/tmp/publisher-gh"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$GH_CONFIG_DIR"
  chmod 700 "$HOME" "$XDG_CONFIG_HOME" "$GH_CONFIG_DIR"

  # Defensive: do not accept ambient host-style GitHub credential variables.
  unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN || true

  if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    echo "GitHub authentication is required inside the disposable container."
    echo "The token created by GitHub CLI will disappear when this container exits."
    echo "Follow the browser/device-code prompt below."
    gh auth login \
      --hostname github.com \
      --git-protocol https \
      --web \
      --skip-ssh-key
  fi

  # Configure git credential use only inside this container's temporary HOME.
  gh auth setup-git --hostname github.com

  LOGIN="$(gh api user --jq .login)"
  USER_ID="$(gh api user --jq .id)"
  FULL_REPO="${LOGIN}/${REPO_NAME}"

  if gh repo view "$FULL_REPO" >/dev/null 2>&1; then
    echo "Repository already exists: https://github.com/$FULL_REPO" >&2
    exit 3
  fi

  # Pre-publication checks. These intentionally look only for generic secret
  # shapes; private deployment configuration must never be added to this tree.
  python3 - <<'PY'
from pathlib import Path
import re, sys

root = Path('.')
patterns = {
    'GitHub token': re.compile(r'gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}'),
    'AWS access key': re.compile(r'AKIA[0-9A-Z]{16}'),
    'private key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'Bearer token': re.compile(r'Bearer\\s+[A-Za-z0-9._~+/-]{20,}'),
}
failures=[]
for p in root.rglob('*'):
    if not p.is_file() or '.git' in p.parts:
        continue
    try:
        text=p.read_text(encoding='utf-8')
    except UnicodeDecodeError:
        continue
    for label, rx in patterns.items():
        if rx.search(text):
            failures.append(f'{p}: possible {label}')
if failures:
    print('Publication blocked by generic secret scan:', file=sys.stderr)
    print('\\n'.join(failures), file=sys.stderr)
    sys.exit(1)
PY

  python3 scripts/validate-config.py config/projects.example.json
  python3 -m unittest discover -s tests -p 'test_*.py'
  bash -n \
    setup-fedora.sh \
    scripts/doctor.sh \
    scripts/publish-github.sh \
    bin/sharepoint-sync \
    bin/sharepoint-sync-all \
    bin/sharepoint-sync-auth \
    bin/sharepoint-sync-doctor

  # This is a copy inside the container, not the host source tree, so .git and
  # git config written below disappear with the container after publication.
  rm -rf .git
  git init -b main
  git config user.name "$LOGIN"
  git config user.email "${USER_ID}+${LOGIN}@users.noreply.github.com"

  git add .
  if git diff --cached --quiet; then
    echo "Nothing to commit." >&2
    exit 4
  fi

  git commit -m "Initial public release"

  gh repo create "$FULL_REPO" \
    --public \
    --description "$DESCRIPTION" \
    --source . \
    --remote origin \
    --push

  gh repo edit "$FULL_REPO" \
    --add-topic sharepoint \
    --add-topic microsoft-graph \
    --add-topic linux \
    --add-topic powershell \
    --add-topic sync

  URL="$(gh repo view "$FULL_REPO" --json url --jq .url)"
  VIS="$(gh repo view "$FULL_REPO" --json visibility --jq .visibility)"

  echo
  echo "Published: $URL"
  echo "Visibility: $VIS"
  echo "GitHub CLI credentials existed only inside the disposable container."
  exit 0
fi

# ---------------------------------------------------------------------------
# Outer path: Fedora host bootstrap. It never invokes host gh or host git auth.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
CONTAINERFILE="$SCRIPT_DIR/Containerfile.publish"

if [[ ! -f "$PROJECT_ROOT/README.md" || ! -f "$PROJECT_ROOT/LICENSE" || ! -d "$PROJECT_ROOT/src" ]]; then
  echo "Could not resolve the project root." >&2
  exit 2
fi

if [[ ! -f /etc/fedora-release ]]; then
  echo "This publisher currently supports a Fedora host only." >&2
  exit 2
fi

if [[ ! -f "$CONTAINERFILE" ]]; then
  echo "Missing publisher container definition: $CONTAINERFILE" >&2
  exit 2
fi

if ! command -v podman >/dev/null 2>&1; then
  echo "Podman is required. It is not currently installed."
  read -r -p "Install Podman with sudo dnf now? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES)
      sudo dnf install -y podman
      ;;
    *)
      echo "Install Podman and rerun this script." >&2
      exit 2
      ;;
  esac
fi

# Build only the small publisher image. The project itself is NOT copied into
# the image; at runtime it is mounted read-only and copied into container-local
# writable storage. This prevents publication from creating .git or changing
# files in the host checkout.
echo "Building isolated publisher image: $PUBLISH_IMAGE"
podman build \
  --pull=newer \
  --file "$CONTAINERFILE" \
  --tag "$PUBLISH_IMAGE" \
  "$SCRIPT_DIR"

echo
echo "Starting disposable publisher container."
echo "Host GitHub CLI credentials/config are not mounted or inherited."
echo "Any GitHub authorization below is container-local and deleted on exit."
echo

# Do not pass HOME, XDG_CONFIG_HOME, GH_CONFIG_DIR, GH_TOKEN, GITHUB_TOKEN,
# SSH_AUTH_SOCK, or host git configuration into the container. The source tree
# is mounted read-only. SELinux :Z labeling is appropriate for Fedora/Podman.
podman run \
  --rm \
  --interactive \
  --tty \
  --volume "$PROJECT_ROOT:/source:ro,Z" \
  --env SHAREPOINT_SYNC_PUBLISH_IN_CONTAINER=1 \
  --env "PUBLISH_REPO_NAME=$repo_name" \
  --env "PUBLISH_DESCRIPTION=$DEFAULT_DESCRIPTION" \
  "$PUBLISH_IMAGE" \
  bash -lc '
    set -euo pipefail
    mkdir -p /work/repo
    cp -a /source/. /work/repo/
    cd /work/repo
    exec ./scripts/publish-github.sh
  '
