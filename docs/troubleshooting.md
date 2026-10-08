# Troubleshooting

## `Approval required`

Your Microsoft Entra tenant can require administrator approval even for delegated read access. This is a tenant policy decision; the sync tool cannot bypass it.

## Conditional Access / `AADSTS53003`

Authentication succeeded but tenant Conditional Access denied the session. Check the sign-in details and ask the tenant administrator which policy applied.

## `System.Text.Json` assembly error

Upgrade PowerShell. The Fedora installer requires PowerShell 7.6+ to avoid runtime incompatibility with current Microsoft Graph PowerShell modules.

## First run opens a browser, later runs do not

Expected. `Connect-MgGraph -ContextScope CurrentUser` uses the current-user token cache. Reauthentication can still be required by tenant policy, token revocation or account changes.

## Large files take more than five minutes

Downloads use a short-lived pre-authenticated Graph download URL and the system
`curl` client. The URL is passed through a mode-0600 temporary curl config
rather than the process command line. `OperationTimeoutSeconds` is mapped to a
low-speed/stall timeout, not a total transfer deadline, so large files can run
for much longer while bytes continue flowing.

## Sync was interrupted

Run it again. Completed files with matching size and modification time are skipped. Compatible `.part` downloads can resume. The delta checkpoint is advanced only after the entire batch has been applied successfully.

## Local file disappeared

Remote deletions are mirrored locally. The SharePoint source remains read-only; the deletion happened only in the local mirror in response to a provider deletion event.

## Inspect logs

```bash
journalctl --user -u sharepoint-sync.service -n 200 --no-pager
```

## PowerShell `Invoke-WebRequest` NullReferenceException

Some PowerShell releases can encounter `System.NullReferenceException` in
`Invoke-WebRequest` for otherwise valid SharePoint download responses. Current
releases of this tool use `curl` for the file byte stream and keep Microsoft
Graph PowerShell for authenticated metadata and delta requests.

## One file returns HTTP 403 / Access denied

By default this fails the project, because an incomplete mirror should not be
reported as complete. If item-specific restrictions are expected, set
`"skipForbidden": true` for that project. The denied item is logged and tracked
in state, the rest of the project continues, and the item is retried on later
runs.

## PowerShell named-pipe shutdown noise

PowerShell 7.6 creates a diagnostics IPC named-pipe listener by default. On
non-Windows systems, shutdown of that listener can occasionally produce a
`NamedPipeIPC_ServerListenerError` even after a successful command. This tool
does not use `Enter-PSHostProcess` or that diagnostics pipe, so tool-managed
PowerShell processes set `POWERSHELL_DIAGNOSTICS_OPTOUT=1` before PowerShell
starts. This disables creation of the optional diagnostics named pipe and avoids
the shutdown-only noise without changing Microsoft Graph authentication or sync
behavior.
