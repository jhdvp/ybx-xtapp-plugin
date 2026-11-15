# Release 1.7.0

Source: `source/ybx-studio`; official Studio project `784cb883-9704-4bc7-bbf5-812129d5a80b`.
Package: `package/YBX-1.7.0.xtapp`, 245112 bytes.
SHA-256: `2bfe0a24fa2e0ee51290812daa0673d648fa8a250683171b78ff70ffdeada2b3`.
Store app: `u_c410dcba5c524789a6586fa34d935bcf`.
Compatibility: Classic and Pro, Gancao API 2.26.

The official export is checked against `releases/1.7.0.json`. Never rebuild with the old community packer. The publisher refuses different bytes at an existing version URL and writes `static/xtapp/gancao/latest.json`; the legacy Licorice catalog remains separate. Clients 1.6.19 and newer receive the Gancao catalog through the compatibility endpoint; older clients retain their original catalog.

OTA validates app, firmware channel, minimum API, version, same-origin versioned URL, bounded size, XTAP magic and the SHA-256 of the saved file before offering installation.

Deploy site schema 29 and the matching server before submitting the client. Run the full backend PostgreSQL gate, frontend tests and reproducible asset build, then use `scripts/upgrade_schema.sh 28 29` from a clean committed checkout. Preserve unrelated modified 1.6.17 files.

Seconds are shadow diagnostics only; credited minutes remain server-owned. Physical-device checks remain outstanding as documented in READING-TIME.md.
