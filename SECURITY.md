# Security policy

## Supported scope

The initial release is a read-only synchronization client for SharePoint document libraries on Fedora.

## Credential handling

- Do not put access tokens, refresh tokens, passwords, client secrets, certificates or private keys in `projects.json`.
- Authentication is delegated to Microsoft Graph PowerShell (`Microsoft.Graph.Authentication`).
- The project never intentionally prints access tokens or pre-authenticated download URLs.
- Provider download URLs are treated as secrets and are used only in memory for the active transfer.

## Permission scope

The default authentication flow requests `Files.Read.All` as a delegated permission. This can read every file the signed-in identity is allowed to access. Use a dedicated account or more constrained tenant/application design where your security model requires it.

## Local confidentiality

A local mirror has the same practical confidentiality risk as a downloaded copy of the source documents. Use appropriate filesystem permissions, encrypted storage, backup policy and endpoint security.

## Reporting security issues

Do not open a public issue containing credentials, private SharePoint URLs, confidential file names, tokens or copied document contents. Use GitHub's private vulnerability-reporting mechanism if it is enabled for the repository, or contact the maintainer privately.
