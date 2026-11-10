#!/usr/bin/env python3
"""Verify the YBX XTApp source and the packaged .xtapp agree.

  python tools/validate_source.py [--source DIR] [--package FILE]

Only checks that need no firmware key: the manifest, the sleep-card inline
drift guard, the version string, and the package header (its manifest, code
section length and icons section). The code section itself is AES-CTR
encrypted for the device key, so its bytes cannot be read here; its length is
exact, which is enough to catch a .xtapp built from older sources.
"""
from __future__ import annotations

import argparse
import json
import re
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / "source" / "ybx"

MAGIC = b"XTAP"
HEADER_SIZE = 0x80
MANIFEST_OFF = 0x80
MANIFEST_MAX = 0x2000
XTCO_HEAD = 16
XTCO_ENTRY = 104
FEATURE_CODE = 0x02
XTAB_MAGIC = b"XTAB"
XTAB_HEAD = 64
XTAB_NAME = 24

BEGIN = b"-- BEGIN SHARED SLEEP CARD\n"
END = b"-- END SHARED SLEEP CARD\n"
WRAP_OPEN = b"local SleepCard=(function()\n"
WRAP_CLOSE = b"end)()\n"

SEMVER = re.compile(r"\d+\.\d+\.\d+\Z")
API_2X = re.compile(r"2\.\d+\Z")
VERSION_LUA = re.compile(rb"^local VERSION = '([^']+)'$", re.MULTILINE)
APP_VERSION_LUA = re.compile(rb"^local APP_VERSION = VERSION\b", re.MULTILINE)

REQUIRED = ("manifest.json", "index.lua", "icon.png", "README.txt",
            "src/sleep_card.lua", "src/lockscreen.lua")


def load_json(path: Path, errors: list[str]) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        errors.append(f"{path.name}: {exc}")
        return {}


def validate_source(source: Path, errors: list[str]) -> tuple[dict, bytes]:
    for name in REQUIRED:
        if not (source / name).is_file():
            errors.append(f"missing source file: {name}")
    if any(not (source / name).is_file() for name in REQUIRED):
        return {}, b""

    manifest = load_json(source / "manifest.json", errors)
    index = (source / "index.lua").read_bytes()
    version = manifest.get("version", "")

    if manifest.get("app_id") != "ybx":
        errors.append("manifest.app_id must be ybx")
    if not isinstance(version, str) or not SEMVER.fullmatch(version):
        errors.append("manifest.version must be SemVer")
    if manifest.get("entry", "index.lua") != "index.lua":
        errors.append("manifest.entry must be index.lua")
    if not API_2X.fullmatch(str(manifest.get("api", ""))):
        errors.append("manifest.api must be a 2.x host API version")
    if manifest.get("permissions") != ["net"]:
        errors.append('manifest.permissions must be exactly ["net"]')
    for secret in ("token.json", ".env"):
        if (source / secret).exists():
            errors.append(f"secret file must not be shipped: {secret}")

    found = VERSION_LUA.search(index)
    if not found:
        errors.append("index.lua VERSION literal missing")
    elif found.group(1).decode() != version:
        errors.append("index.lua VERSION disagrees with manifest.version")
    if not APP_VERSION_LUA.search(index):
        errors.append("index.lua APP_VERSION must alias VERSION")

    sleep_card = (source / "src" / "sleep_card.lua").read_bytes()
    inline = BEGIN + WRAP_OPEN + sleep_card + WRAP_CLOSE + END
    if not index.startswith(inline):
        errors.append("index.lua inline sleep-card block drifted from src/sleep_card.lua")

    readme = (source / "README.txt").read_text(encoding="utf-8", errors="replace")
    if version not in readme:
        errors.append("README.txt changelog does not mention the manifest version")
    return manifest, sleep_card


def find_package(errors: list[str]) -> Path | None:
    directory = ROOT / "package"
    if not directory.is_dir():
        return None
    items = sorted(directory.glob("*.xtapp"))
    if len(items) == 1:
        return items[0]
    if items:
        errors.append("package/ must hold exactly one .xtapp: "
                      + ", ".join(p.name for p in items))
    return None


def validate_package(package: Path, manifest: dict, index: bytes, sleep_card: bytes,
                     source: Path, errors: list[str]) -> None:
    data = package.read_bytes()
    if len(data) < HEADER_SIZE or data[:4] != MAGIC:
        errors.append(f"{package.name}: not an XTAPP container")
        return
    version, header_size = struct.unpack_from("<HH", data, 4)
    total, mask = struct.unpack_from("<II", data, 8)
    man_off, man_len = struct.unpack_from("<II", data, 0x10)
    code_off, code_len = struct.unpack_from("<II", data, 0x18)
    icons_off, icons_len = struct.unpack_from("<II", data, 0x30)
    _, data_len = struct.unpack_from("<II", data, 0x38)

    if version != 1 or header_size != HEADER_SIZE:
        errors.append(f"{package.name}: unsupported header {version}/{header_size:#x}")
    if total != len(data):
        errors.append(f"{package.name}: header total {total} B, file is {len(data)} B")
    if man_off != MANIFEST_OFF or not 1 <= man_len <= MANIFEST_MAX or man_off + man_len > len(data):
        errors.append(f"{package.name}: bad manifest location")
        return
    try:
        packed = json.loads(data[man_off:man_off + man_len].decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        errors.append(f"{package.name}: manifest JSON: {exc}")
        return
    for key in ("app_id", "version", "entry"):
        if packed.get(key) != manifest.get(key):
            errors.append(f"{package.name}: manifest {key} disagrees with source")
    lockscreen = packed.get("lockscreen")
    if not (isinstance(lockscreen, dict) and lockscreen.get("enabled") is True
            and lockscreen.get("entry") == "lockscreen.lua"):
        errors.append(f"{package.name}: stock lockscreen block missing from the manifest")

    staged_lock = (WRAP_OPEN + sleep_card + WRAP_CLOSE
                   + (source / "src" / "lockscreen.lua").read_bytes())
    expected_code = XTCO_HEAD + XTCO_ENTRY * 2 + len(index) + len(staged_lock)
    if not mask & FEATURE_CODE:
        errors.append(f"{package.name}: code section not flagged in the feature mask")
    if code_off + code_len > len(data):
        errors.append(f"{package.name}: code section runs past the file")
    elif code_len != expected_code:
        errors.append(f"{package.name}: code section {code_len} B, source builds "
                      f"{expected_code} B (package is stale)")
    if data_len:
        errors.append(f"{package.name}: unexpected data section ({data_len} B)")
    if not icons_len or icons_off + icons_len > len(data):
        errors.append(f"{package.name}: icons section missing")
        return
    icons = data[icons_off:icons_off + icons_len]
    if icons[:4] != XTAB_MAGIC:
        errors.append(f"{package.name}: icons section is not XTAB")
        return
    count = struct.unpack_from("<I", icons, 8)[0]
    first = icons[XTAB_HEAD:XTAB_HEAD + XTAB_NAME].split(b"\0")[0]
    if count < 1 or first != b"app_icon_s":
        errors.append(f"{package.name}: grid icon app_icon_s missing")


def validate(source: Path = DEFAULT_SOURCE, package: Path | None = None) -> list[str]:
    errors: list[str] = []
    manifest, sleep_card = validate_source(source, errors)
    if errors:
        return errors
    package = package or find_package(errors)
    if package is not None:
        if not Path(package).is_file():
            errors.append(f"package not found: {package}")
        else:
            validate_package(Path(package), manifest, (source / "index.lua").read_bytes(),
                             sleep_card, source, errors)
    return errors


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE,
                        help="app source directory (default: source/ybx)")
    parser.add_argument("--package", type=Path,
                        help="packaged .xtapp to compare (default: the one in package/)")
    args = parser.parse_args()
    errors = validate(args.source, args.package)
    if errors:
        raise SystemExit("\n".join(errors))
    manifest = json.loads((args.source / "manifest.json").read_text(encoding="utf-8"))
    print(f"YBX XTApp source verified ({manifest.get('version')})")


if __name__ == "__main__":
    main()
