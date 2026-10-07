# Configuration

The default configuration is:

```text
~/.config/sharepoint-sync/projects.json
```

It is a JSON array. Each entry defines one local mirror.

## Fields

| Field | Required | Meaning |
|---|---:|---|
| `enabled` | no | Set `false` to skip the entry. Defaults to enabled. |
| `project` | yes | Local filesystem-safe label used in logs/state. |
| `siteHost` | yes | SharePoint hostname, without scheme or path. |
| `sitePath` | yes | SharePoint site path beginning with `/`. |
| `driveName` | no | Document-library display name. Default: `Documents`. |
| `remoteRoot` | no | Folder inside the document library. Default: `General`. |
| `localRoot` | no | Explicit mirror path. `~/...` is supported. |
| `skipForbidden` | no | If `true`, an individual HTTP 403 file download is logged as denied, retained in state, retried on later runs, and does not fail the whole project. Default: `false`. |
| `maxDownloadAttempts` | no | Retry attempts, 1–20. Default: 4. |
| `connectionTimeoutSeconds` | no | Connection timeout. Default: 60. |
| `operationTimeoutSeconds` | no | Maximum stream stall between reads. Default: 300. |

No credential fields are supported.

## Finding SharePoint values

Open the target folder in SharePoint and inspect its URL. Typically:

```text
https://contoso.sharepoint.com/sites/ExampleProject/Shared%20Documents/...
```

maps to:

```json
{
  "siteHost": "contoso.sharepoint.com",
  "sitePath": "/sites/ExampleProject",
  "driveName": "Documents"
}
```

The library can be displayed as `Shared Documents` in a browser while Microsoft Graph reports its drive name as `Documents`; confirm with Graph if necessary.

## Item-specific access denial

The default is strict: an HTTP 403 while downloading an individual file fails
that project. If a document library intentionally contains items that the
signed-in user may enumerate but cannot download, opt into best-effort handling
for that project:

```json
{
  "skipForbidden": true
}
```

Denied items are not treated as successfully mirrored. They remain marked in
local sync state and are retried on later runs, so a later permission grant can
recover them without resetting the project's delta state.
