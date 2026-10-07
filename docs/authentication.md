# Authentication

The initial release relies on Microsoft Graph PowerShell's delegated interactive authentication.

```powershell
Connect-MgGraph -Scopes "Files.Read.All" -ContextScope CurrentUser
```

Run:

```bash
sharepoint-sync-auth
```

The first connection normally opens a browser. Later non-interactive runs can reuse the current-user token cache.

## Tenant policy

`Files.Read.All` is a broad delegated read permission. Depending on Microsoft Entra policy, users may be able to consent themselves or may see an administrator-approval prompt. Conditional Access can also deny an otherwise successful sign-in.

This project does not attempt to bypass tenant consent or Conditional Access.

## Application identity

The initial release uses the application identity selected by Microsoft Graph PowerShell when `Connect-MgGraph` is called without a custom `ClientId`. A future release may add an explicit custom-app mode, but credentials and client secrets will remain outside `projects.json`.
