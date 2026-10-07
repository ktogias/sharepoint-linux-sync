# Architecture

```text
Microsoft Graph / SharePoint
          |
          | delta feed + metadata
          v
  sharepoint-sync.ps1
          |
          +---- state / deltaLink
          |
          +---- resumable downloads
          v
      local mirror
```

## Initial synchronization

The first run starts from the target folder's Graph `delta` endpoint. It follows every `@odata.nextLink`, applies the returned items locally, and persists the final `@odata.deltaLink` only after all operations succeed.

## Incremental synchronization

Later runs start from the stored `deltaLink`. Only provider changes since the prior checkpoint need to be processed.

## Restart behavior

If a run fails before state commit, the old checkpoint remains authoritative. A retry can safely see some items again. Existing files are skipped when size and modification time match.

## Large files

File metadata provides a short-lived `@microsoft.graph.downloadUrl`. The transfer uses `Invoke-WebRequest -Resume`. A partial download is reused only if a sidecar records the same provider `eTag` and expected size.

## Identity and local state

The local path is a materialization, not source identity. Provider item IDs, `eTag`, modification time and delta state are retained only as local operational metadata.
