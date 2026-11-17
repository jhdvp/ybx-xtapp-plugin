#!/usr/bin/env python3
"""Publish a validated official Studio export (never rebuild with the legacy packer).

  python scripts/publish_xtapp.py --dry-run --no-release --notes "What changed"

Defaults to source/ybx-studio and package/YBX-<version>.xtapp. Validates the
reviewed source/package receipt BEFORE modifying the site's static catalog.
--dry-run writes nothing. --site selects an isolated site checkout for handoff.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SITE = ROOT.parent / "YBX Site"
STATIC_SUBDIR = Path("src") / "xteink_yandex_bridge" / "static" / "xtapp"
DEFAULT_SOURCE = ROOT / "source" / "ybx-studio"
SEMVER = re.compile(r"\d+\.\d+\.\d+\Z")


def source_version(source: Path = DEFAULT_SOURCE) -> str:
    manifest = json.loads((source / "manifest.json").read_text(encoding="utf-8"))
    index = (source / "index.lua").read_text(encoding="utf-8")
    match = re.search(r"^local VERSION = '([0-9]+\.[0-9]+\.[0-9]+)'", index, re.MULTILINE)
    if not match:
        raise SystemExit("VERSION not found in source/ybx-studio/index.lua")
    version = manifest["version"]
    if version != match.group(1) or not SEMVER.match(version):
        raise SystemExit(f"manifest version {version} != index VERSION {match.group(1)}")
    return version


def publish(package: Path, version: str, notes: str, release: bool, dry_run: bool, site: Path, source: Path = DEFAULT_SOURCE) -> None:
    if version != source_version(source):
        raise SystemExit("requested release version differs from source")
    subprocess.run([sys.executable, str(ROOT / 'tools' / 'validate_source.py'),
                    '--source', str(source), '--package', str(package)], check=True)
    payload = package.read_bytes()
    if payload[:4] != b"XTAP":
        raise SystemExit("package does not start with XTAP")
    static = site / STATIC_SUBDIR
    target = static / f"YBX-{version}.xtapp"
    document = {
        "app": "ybx-xtapp",
        "channel": "gancao",
        "min_api": "2.26",
        "firmware": "Gancao",
        "version": version,
        "url": f"/xtapp/YBX-{version}.xtapp",
        "size": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
        "notes": notes,
        "published": datetime.now(timezone.utc).date().isoformat(),
    }
    if target.exists() and target.read_bytes()!=payload:
        raise SystemExit("immutable version URL already contains different bytes; export a new version")
    if dry_run:
        print(json.dumps(document, ensure_ascii=False, indent=2))
        print(f"would write {target}")
        return
    static.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(package, target)
    (static / "gancao").mkdir(exist_ok=True)
    (static / "gancao" / "latest.json").write_text(
        json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"published {target} ({len(payload)} bytes)")
    if release:
        tag = f"v{version}"
        result = subprocess.run(
            [
                "gh", "release", "create", tag, str(package.resolve()),
                "--title", f"YBX XTApp {version}",
                "--notes", f"{notes}\n\nsha256: {document['sha256']}",
            ],
            cwd=ROOT,
        )
        if result.returncode != 0:
            print(f"warning: GitHub release {tag} not created (see above)", file=sys.stderr)
    print(f'deploy: cd "{site}" && ./deploy.sh')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--notes", default="")
    parser.add_argument("--no-release", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--site", type=Path, default=DEFAULT_SITE)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--package", type=Path, help="official Studio-exported .xtapp; never rebuilt by the legacy packer")
    args = parser.parse_args()
    version = source_version(args.source)
    package = args.package or ROOT / "package" / f"YBX-{version}.xtapp"
    publish(package, version, args.notes, not args.no_release, args.dry_run, args.site, args.source)


if __name__ == "__main__":
    main()
