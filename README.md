# SharePoint Linux Sync

Read-only, incremental SharePoint document-library synchronization for Fedora, built on Microsoft Graph PowerShell.

The tool keeps selected SharePoint folders mirrored on a Linux workstation or server. It uses Microsoft Graph delta feeds for incremental updates, resumes large downloads, and can run periodically through a user-level systemd timer.

## Status

Initial public release. Fedora x86_64 is the supported installation target for now.

## Features

- read-only access to SharePoint through Microsoft Graph;
- multiple independent projects/document libraries from one JSON configuration;
- initial recursive mirror followed by incremental delta synchronization;
- resumable large-file downloads with retry and provider-version checks;
- local handling of remote creates, updates, moves and deletions;
- per-project state and locking;
- persistent delegated Microsoft Graph authentication through the PowerShell SDK;
- user-level systemd service and timer;
- installer/wizard for Fedora;
- no credentials in the project configuration.

SharePoint-backed files exposed through collaboration products such as Microsoft Teams can be synchronized by targeting their underlying SharePoint site/document library.

## Security model

This project is **read-only with respect to SharePoint**. It never uploads, edits or deletes remote files.

The delegated permission used by the default flow is:

```text
Files.Read.All
```

That permission is broad: it allows the application to read files that the signed-in user can already access. Microsoft Entra tenant policy can require administrator approval or enforce Conditional Access.

Authentication tokens are handled by `Microsoft.Graph.Authentication` and are not stored in `projects.json` by this project.

The local mirror can contain sensitive files. Protect the Linux account, local filesystem, backups and full-disk storage accordingly.

See [SECURITY.md](SECURITY.md), [docs/security.md](docs/security.md), and [docs/authentication.md](docs/authentication.md).

## Quick start on Fedora

Clone the repository, then run:

```bash
./setup-fedora.sh
```

The wizard:

1. verifies Fedora x86_64;
2. installs base packages;
3. ensures PowerShell 7.6+ is available;
4. installs `Microsoft.Graph.Authentication` from PowerShell Gallery;
5. installs the sync commands in `~/.local/bin`;
6. installs systemd user units;
7. optionally authenticates to Microsoft Graph;
8. optionally enables the timer.

The installer does not place private source configuration in the repository.

## Configure projects

Copy the example:

```bash
mkdir -p ~/.config/sharepoint-sync
cp config/projects.example.json ~/.config/sharepoint-sync/projects.json
chmod 600 ~/.config/sharepoint-sync/projects.json
$EDITOR ~/.config/sharepoint-sync/projects.json
```

Example:

```json
[
  {
    "enabled": true,
    "project": "ExampleProject",
    "siteHost": "contoso.sharepoint.com",
    "sitePath": "/sites/ExampleProject",
    "driveName": "Documents",
    "remoteRoot": "General",
    "localRoot": "~/SharePoint/ExampleProject/General"
  }
]
```

Validate it:

```bash
python3 scripts/validate-config.py ~/.config/sharepoint-sync/projects.json
```

Or give a private config directly to the installer:

```bash
./setup-fedora.sh --config ~/private-projects.json
```

The installer copies it to `~/.config/sharepoint-sync/projects.json` with mode `0600`.

## Authenticate

Run once interactively:

```bash
sharepoint-sync-auth
```

A browser login may be required the first time. The tool uses the current-user Microsoft Graph token cache, so later non-interactive runs can normally reuse the session until tenant policy requires reauthentication.

## Run a sync

All configured projects:

```bash
sharepoint-sync-all
```

One project manually:

```bash
sharepoint-sync \
  -Project ExampleProject \
  -SiteHost contoso.sharepoint.com \
  -SitePath /sites/ExampleProject \
  -DriveName Documents \
  -RemoteRoot General
```

## systemd timer

The installer can enable it automatically. Manual commands:

```bash
systemctl --user enable --now sharepoint-sync.timer
systemctl --user list-timers sharepoint-sync.timer
systemctl --user start sharepoint-sync.service
journalctl --user -u sharepoint-sync.service -f
```

To allow the user timer to run without an active login session:

```bash
sudo loginctl enable-linger "$USER"
```

## Local layout

Default mirror location:

```text
~/SharePoint/<project>/<remoteRoot>/
```

State:

```text
~/.local/state/sharepoint-sync/<project>-<remoteRoot>/
```

Installed application files:

```text
~/.local/share/sharepoint-sync/
```

Configuration:

```text
~/.config/sharepoint-sync/
```

## Important behavior

- The SharePoint side is read-only.
- Remote deletions are reflected by deleting the corresponding item from the local mirror.
- Local mirror files should be treated as cache/materialization, not as an editing workspace.
- The delta checkpoint advances only after all local operations for the batch succeed.
- Large-file partial downloads are retained and resumed only when their provider `eTag` and expected size still match.
- If a provider request fails, the tool reports failure rather than treating it as an empty result.

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md).

## Publish this project to GitHub without touching host GitHub credentials

For maintainers who want to create a new public repository from this source
tree, the publication helper runs GitHub CLI entirely inside a disposable
Podman container:

```bash
./scripts/publish-github.sh
```

The host checkout is mounted read-only and copied into container-local storage.
The container uses an ephemeral `HOME`, `XDG_CONFIG_HOME`, and `GH_CONFIG_DIR`;
the host `~/.config/gh`, host Git credential helpers, `GH_TOKEN`, `GITHUB_TOKEN`,
and SSH agent are not mounted or passed through. The browser/device-code login
is therefore valid only for the disposable container and is removed when it
exits.

The helper runs validation, tests and a generic secret scan before creating and
pushing a **new public** GitHub repository. Pass a different repository name as
the first argument if desired:

```bash
./scripts/publish-github.sh my-repository-name
```

The publisher currently requires a Fedora host with Podman. If Podman is absent,
the script offers to install it with `dnf` after explicit confirmation.

## License

Apache License 2.0, the same license used by Gnostoa. See [LICENSE](LICENSE).
