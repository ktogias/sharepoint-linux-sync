# Changelog

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
