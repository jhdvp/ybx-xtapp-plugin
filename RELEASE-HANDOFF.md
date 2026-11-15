# Installer handoff — official Studio 1.6.19

- Source: source/ybx-studio; legacy source/ybx remains historical 1.6.17.
- Package: package/YBX-1.6.19.xtapp, 235572 bytes.
- SHA-256: 94465a39c574ad86f096922c254e98e663ce3217530c76b1d81540e32d989b2a.
- Store app: u_c410dcba5c524789a6586fa34d935bcf.
- Store project: 784cb883-9704-4bc7-bbf5-812129d5a80b.
- Devices: X4 Classic / X4 Pro. Requires compatible Gancao firmware, API 2.26.

The publisher consumes the official export and validates it BEFORE writing anything. Do not rebuild it with the legacy Licorice community packer. Do not delete or reset another agent's modified 1.6.17 package; versioned selection makes old packages harmless.

First run `python3 tools/validate_source.py`, `node tests/run-studio-tests.js`, and `python3 -m unittest discover -s tests -p test_release_pipeline.py`. Then run `python3 scripts/publish_xtapp.py --dry-run --no-release`.

To prepare an isolated site checkout: `python3 scripts/publish_xtapp.py --no-release --site /absolute/path/to/site-checkout --notes "Official Studio 1.6.19: YBX identity and KOSync fixes"`. The resulting latest.json uses app=ybx-xtapp and /xtapp/YBX-1.6.19.xtapp. The site agent must update Installer links/compatibility so this Gancao package is not advertised as a generic old Licorice update. Existing older firmware paths need to stay available where appropriate. Review and deploy the site through its own repository gate.

This work fixes local release preparation only. It does not deploy the website, alter stable or create a GitHub release. Physical-device progress delivery/restoration remains a separate check. Minutes stay server-estimated; no device timer was introduced.
