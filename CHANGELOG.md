# Changelog

## 0.1.2

- Replace the PowerShell Invoke-WebRequest file-transfer path with a curl-based resumable downloader to avoid provider-specific runtime NullReferenceException failures.
- Keep pre-authenticated Graph download URLs out of process arguments by using mode-0600 temporary curl config files.
- Add opt-in skipForbidden handling for item-specific HTTP 403 responses; denied items are tracked and retried on later runs.
- Extend the doctor for the curl transfer dependency.

## 0.1.1

- Fix Fedora fallback PowerShell installation by verifying the RPM against the SHA-256 digest published in GitHub release metadata, with a `hashes.sha256` fallback.
- Honor `XDG_CONFIG_HOME` for the default private project configuration path.
- Honor `XDG_STATE_HOME` for synchronization state.

## 0.1.0

- Initial Fedora-only public release.
- Read-only Microsoft Graph / SharePoint synchronization.
- Initial + delta synchronization.
- Multiple project configuration.
- Resumable large-file downloads with provider-version checks.
- User-level systemd service and timer.
- Fedora setup wizard and configuration validator.
