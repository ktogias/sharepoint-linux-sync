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

Downloads use a pre-authenticated Graph download URL and PowerShell `Invoke-WebRequest`. `OperationTimeoutSeconds` limits a stall between stream reads rather than total transfer time. Large files may therefore take much longer than the configured value as long as data continues flowing.

## Sync was interrupted

Run it again. Completed files with matching size and modification time are skipped. Compatible `.part` downloads can resume. The delta checkpoint is advanced only after the entire batch has been applied successfully.

## Local file disappeared

Remote deletions are mirrored locally. The SharePoint source remains read-only; the deletion happened only in the local mirror in response to a provider deletion event.

## Inspect logs

```bash
journalctl --user -u sharepoint-sync.service -n 200 --no-pager
```
