# Security architecture

The sync process separates three kinds of state:

1. **configuration** — provider locations and local mirror paths;
2. **authentication** — delegated token state managed by Microsoft Graph PowerShell;
3. **materialization** — local copies of remote documents and a delta checkpoint.

The configuration format intentionally has no credential fields. The bundled validator rejects credential-like keys.

## Read-only provider boundary

The sync engine calls Microsoft Graph using HTTP `GET` operations. It does not contain remote create, update or delete operations.

Remote deletions can cause **local** deletion because the local directory is a mirror. This is not a remote mutation.

## Download URLs

Microsoft Graph can return a short-lived, pre-authenticated download URL for a file. The tool:

- requires HTTPS;
- never logs the URL;
- never adds the Microsoft Graph Authorization header to it;
- requests a fresh URL on every retry;
- checks the provider `eTag` before reusing a partial download.

## Local materialization

The mirror is non-authoritative local state. Treat it as sensitive when the source is sensitive. In particular:

- do not commit it to Git;
- do not expose it through a web server;
- do not upload it as a CI artifact by default;
- review backup and snapshot behavior;
- consider full-disk encryption.

## systemd

The supplied unit is a user service and runs with the current user's privileges. It does not require root to synchronize files.
