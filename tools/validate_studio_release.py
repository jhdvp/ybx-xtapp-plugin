"""Validate an official Studio export against a reviewed local release receipt.

The receipt pairs source/asset hashes with an exported package. It is not a
signature or decryption proof; only Studio can build the encrypted package.
"""
from __future__ import annotations
import hashlib
import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def runtime_files(source: Path) -> dict[str, str]:
    files = [source / 'manifest.json']
    files += [p for p in source.rglob('*.lua') if 'docs' not in p.relative_to(source).parts]
    files += [p for p in (source / 'assets').glob('*') if p.is_file()]
    return {p.relative_to(source).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(files)}

def validate(source: Path, package: Path, receipt: Path | None = None) -> list[str]:
    errors = []
    try:
        manifest = json.loads((source / 'manifest.json').read_text())
        version = manifest['version']
        receipt = receipt or ROOT / 'releases' / f'{version}.json'
        record = json.loads(receipt.read_text())
        if record.get('version') != version:
            errors.append('release receipt version disagrees with source')
        if record.get('files') != runtime_files(source):
            errors.append('source/assets differ from reviewed Studio export; export and review a new package')
        data = package.read_bytes()
        if record.get('package_sha256') != hashlib.sha256(data).hexdigest():
            errors.append('package SHA-256 differs from reviewed Studio export')
        if len(data) < 128 or data[:4] != b'XTAP':
            return errors + ['not an XTAP package']
        fmt, header = struct.unpack_from('<HH', data, 4)
        total, mask = struct.unpack_from('<II', data, 8)
        if (fmt, header, total) != (1, 128, len(data)):
            errors.append('invalid XTAP header')
        sections = [struct.unpack_from('<II', data, off) for off in (16, 24, 32, 48, 56)]
        for offset, length in sections:
            if length and (offset < 128 or offset + length > len(data)):
                return errors + ['XTAP section outside package bounds']
        mo, ml = sections[0]
        packed = json.loads(data[mo:mo+ml])
        for key, value in manifest.items():
            if packed.get(key) != value:
                errors.append(f'packed manifest {key} differs from source')
        if packed.get('dek_wrap_alg') != 'P256-ECDH-HKDF-SHA256-AESKW':
            errors.append('expected an official Studio export, not the legacy community packer')
        lua = [source / name for name in runtime_files(source) if name.endswith('.lua')]
        if not mask & 2 or sections[1][1] != 16 + 104 * len(lua) + sum(p.stat().st_size for p in lua):
            errors.append('code section length differs from source modules')
        io, il = sections[3]
        icons = data[io:io+il]
        if icons[:4] != b'XTAB' or len(icons) < 144:
            errors.append('device icon table missing')
        elif any(icons[64+i*40:88+i*40].split(b'\0')[0] != name
                 for i, name in enumerate((b'app_icon_s', b'app_icon_l'))):
            errors.append('small/large device icons missing')
    except (OSError, ValueError, KeyError, TypeError, struct.error) as exc:
        errors.append(f'Studio release validation: {exc}')
    return errors
