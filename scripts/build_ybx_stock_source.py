#!/usr/bin/env python3
"""Stage source/ybx into a build directory the Licorice packer (xtpack.py) accepts.

  python scripts/build_ybx_stock_source.py STAGED_DIR [--source DIR]

The shipped source keeps the shared sleep-card module in src/sleep_card.lua and the
stock lock entry in src/lockscreen.lua; the packer ignores src/. This script:
  * copies manifest.json, index.lua and icon.png into STAGED_DIR;
  * checks the sleep-card block already inlined in index.lua still matches
    src/sleep_card.lua byte for byte (drift guard);
  * generates STAGED_DIR/lockscreen.lua = the shared module wrapped as a local
    followed by src/lockscreen.lua (the lock entry reads the same local);
  * adds the manifest "lockscreen" block the stock firmware needs.

Pack the result with the pinned community packer, e.g.:
  python touch-licorice-apps/xtpack.py STAGED_DIR -o YBX.xtapp
"""
from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / "source" / "ybx"
BEGIN = "-- BEGIN SHARED SLEEP CARD\n"
END = "-- END SHARED SLEEP CARD\n"
WRAP_OPEN = "local SleepCard=(function()\n"
WRAP_CLOSE = "end)()\n"
LOCKSCREEN = {"enabled": True, "entry": "lockscreen.lua", "interval_sec": 3600}


def inline_block(sleep_card: bytes) -> bytes:
    return BEGIN.encode() + WRAP_OPEN.encode() + sleep_card + WRAP_CLOSE.encode() + END.encode()


def stage(source: Path, staged: Path) -> None:
    for name in ("manifest.json", "index.lua", "icon.png", "src/sleep_card.lua", "src/lockscreen.lua"):
        if not (source / name).is_file():
            raise SystemExit(f"missing source file: {source / name}")
    sleep_card = (source / "src" / "sleep_card.lua").read_bytes()
    index = (source / "index.lua").read_bytes()
    expected = inline_block(sleep_card)
    if not index.startswith(expected):
        raise SystemExit(
            "index.lua sleep-card block drifted from src/sleep_card.lua; "
            "re-inline the shared module before building"
        )
    manifest = json.loads((source / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("entry", "index.lua") != "index.lua":
        raise SystemExit("manifest entry must be index.lua")
    manifest["lockscreen"] = LOCKSCREEN

    staged.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source / "index.lua", staged / "index.lua")
    shutil.copyfile(source / "icon.png", staged / "icon.png")
    lockscreen = WRAP_OPEN.encode() + sleep_card + WRAP_CLOSE.encode() + (source / "src" / "lockscreen.lua").read_bytes()
    (staged / "lockscreen.lua").write_bytes(lockscreen)
    (staged / "manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(f"staged {source} -> {staged} (index.lua {len(index)} B, lockscreen.lua {len(lockscreen)} B)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("staged", type=Path, help="output build directory for xtpack.py")
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE, help="app source directory (default: source/ybx)")
    args = parser.parse_args()
    stage(args.source, args.staged)