#!/usr/bin/env python3
"""Build and publish one YBX XTApp release.

  python scripts/publish_xtapp.py --notes "What changed" [--no-release] [--dry-run]

Steps: build the package with the pinned community packer, copy it into the
site's static/xtapp/ catalog, write latest.json next to it, run the source
validator, then create the GitHub release v<version>. Rollout to devices goes
only through the YBX site; the GitHub release is a public archive.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SITE = ROOT.parent / "YBX Site"
STATIC_SUBDIR = Path("src") / "xteink_yandex_bridge" / "static" / "xtapp"
PACKER = ROOT.parent / "touch-licorice-apps" / "xtpack.py"
SEMVER = re.compile(r"\d+\.\d+\.\d+\Z")


def source_version() -> str:
    manifest = json.loads((ROOT / "source" / "ybx" / "manifest.json").read_text(encoding="utf-8"))
    index = (ROOT / "source" / "ybx" / "index.lua").read_text(encoding="utf-8")
    match = re.search(r"^local VERSION = '([0-9]+\.[0-9]+\.[0-9]+)'", index, re.MULTILINE)
    if not match:
        raise SystemExit("VERSION not found in source/ybx/index.lua")
    version = manifest["version"]
    if version != match.group(1) or not SEMVER.match(version):
        raise SystemExit(f"manifest version {version} != index VERSION {match.group(1)}")
    return version


def build(version: str, out: Path) -> Path:
    staged = Path(tempfile.mkdtemp(prefix="ybx-xtapp-stage-"))
    subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "build_ybx_stock_source.py"), str(staged)],
        check=True,
    )
    if not PACKER.is_file():
        raise SystemExit(f"packer missing: {PACKER}")
    subprocess.run(
        [sys.executable, str(PACKER), str(staged), "-o", str(out)],
        check=True,
    )
    shutil.rmtree(staged, ignore_errors=True)
    return out


def publish(package: Path, version: str, notes: str, release: bool, dry_run: bool, site: Path) -> None:
    payload = package.read_bytes()
    if payload[:4] != b"XTAP":
        raise SystemExit("package does not start with XTAP")
    static = site / STATIC_SUBDIR
    static.mkdir(parents=True, exist_ok=True)
    target = static / f"YBX-{version}.xtapp"
    document = {
        "app": "ybx-xtapp",
        "version": version,
        "url": f"/xtapp/YBX-{version}.xtapp",
        "size": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
        "notes": notes,
        "published": datetime.now(timezone.utc).date().isoformat(),
    }
    if dry_run:
        print(json.dumps(document, ensure_ascii=False, indent=2))
        print(f"would write {target}")
        return
    shutil.copyfile(package, target)
    (static / "latest.json").write_text(
        json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    subprocess.run([sys.executable, str(ROOT / "tools" / "validate_source.py")], check=True)
    print(f"published {target} ({len(payload)} bytes)")
    if release:
        tag = f"v{version}"
        result = subprocess.run(
            [
                "gh", "release", "create", tag, str(ROOT / "package" / target.name),
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
    args = parser.parse_args()
    version = source_version()
    with tempfile.TemporaryDirectory(prefix="ybx-xtapp-build-") as temporary:
        package = build(version, Path(temporary) / f"YBX-{version}.xtapp")
        shutil.copyfile(package, ROOT / "package" / f"YBX-{version}.xtapp")
        publish(package, version, args.notes, not args.no_release, args.dry_run, args.site)


if __name__ == "__main__":
    main()
