#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Dependency-free validation for projects.json."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

PROJECT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
HOST_RE = re.compile(r"^[A-Za-z0-9.-]+$")
FORBIDDEN_KEY_RE = re.compile(
    r"(?:token|password|passwd|secret|credential|clientsecret|privatekey|refresh)",
    re.IGNORECASE,
)
ALLOWED_KEYS = {
    "enabled",
    "project",
    "siteHost",
    "sitePath",
    "driveName",
    "remoteRoot",
    "localRoot",
    "maxDownloadAttempts",
    "connectionTimeoutSeconds",
    "operationTimeoutSeconds",
}


def fail(message: str) -> None:
    raise ValueError(message)


def validate_int(item: dict, key: str, lower: int, upper: int, index: int) -> None:
    if key not in item:
        return
    value = item[key]
    if isinstance(value, bool) or not isinstance(value, int):
        fail(f"entry {index}: {key} must be an integer")
    if not lower <= value <= upper:
        fail(f"entry {index}: {key} must be between {lower} and {upper}")


def validate(path: Path) -> int:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list):
        fail("configuration root must be a JSON array")
    if not data:
        fail("configuration must contain at least one project")

    names: set[str] = set()
    for index, item in enumerate(data, start=1):
        if not isinstance(item, dict):
            fail(f"entry {index}: expected an object")

        for key in item:
            if FORBIDDEN_KEY_RE.search(key):
                fail(f"entry {index}: credential-like key is forbidden: {key}")
            if key not in ALLOWED_KEYS:
                fail(f"entry {index}: unsupported key: {key}")

        for required in ("project", "siteHost", "sitePath"):
            if required not in item or not isinstance(item[required], str) or not item[required]:
                fail(f"entry {index}: missing non-empty string '{required}'")

        project = item["project"]
        if not PROJECT_RE.fullmatch(project):
            fail(
                f"entry {index}: project must match {PROJECT_RE.pattern!r}; "
                "use a short filesystem-safe local label"
            )
        if project in names:
            fail(f"entry {index}: duplicate project name: {project}")
        names.add(project)

        host = item["siteHost"]
        if not HOST_RE.fullmatch(host) or "://" in host or "/" in host:
            fail(f"entry {index}: siteHost must be a hostname only")

        site_path = item["sitePath"]
        if not site_path.startswith("/") or "\n" in site_path or "\r" in site_path:
            fail(f"entry {index}: sitePath must be an absolute provider path")

        if "enabled" in item and not isinstance(item["enabled"], bool):
            fail(f"entry {index}: enabled must be boolean")

        for key in ("driveName", "remoteRoot", "localRoot"):
            if key in item and (not isinstance(item[key], str) or not item[key]):
                fail(f"entry {index}: {key} must be a non-empty string")

        remote_root = item.get("remoteRoot", "General")
        if any(part == ".." for part in remote_root.replace("\\", "/").split("/")):
            fail(f"entry {index}: remoteRoot must not contain '..' path segments")

        validate_int(item, "maxDownloadAttempts", 1, 20, index)
        validate_int(item, "connectionTimeoutSeconds", 1, 3600, index)
        validate_int(item, "operationTimeoutSeconds", 1, 86400, index)

    print(f"OK: {len(data)} project configuration entr{'y' if len(data) == 1 else 'ies'}")
    return 0


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} PATH", file=sys.stderr)
        return 2
    try:
        return validate(Path(sys.argv[1]).expanduser())
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
