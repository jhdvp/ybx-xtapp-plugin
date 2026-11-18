# Published combined release — 2026-11-16

- Production server/Installer: main commit `046df658872b870411d00a609e495fb8867f653d`, PostgreSQL schema 29; service active, smoke passed.
- Verified backup: `/var/backups/ybx/v28-before-v29-20261116T092940Z-046df65`.
- Client source: `ybx-apps/main` at `7f1a0bd`, reviewed and host gate passed. Existing dirty Android documentation preserved.
- Public beta and stable releases: PocketBook a13 fat **0.5.7**, PocketBook legacy4 **0.5.6**, Android legacy **0.8.7** (8701), Android modern **0.8.7** (8702). Owner confirmed physical-device checks for these versions.
- Every primary public download was downloaded again and matched signed SHA-256 and size. APK signer matches the previously published APK; the manifest signing key matches clients and the live feed. USB archives contain the exact verified app bytes.
- Legacy HTTP OTA verified on `opds.ybx.app` for PocketBook and Android legacy; modern target rejected over the legacy HTTP route. Prior legacy HTTP commits are included in the server release.
- Backend archive gate: **6811 passed, 4 intentional skips, 4 expected failures; 0 PostgreSQL coverage skips**. Frontend tests passed, all 12 committed bundles were byte-identical to the clean build.
- GitHub Actions for the client push could not start because the account Actions budget prevents further use; local gates and actual artifact verification passed.

## XTApp 1.7.0 — published

Official source `source/ybx-studio`; package `package/YBX-1.7.0.xtapp`, **245112 bytes**.
SHA-256: `2bfe0a24fa2e0ee51290812daa0673d648fa8a250683171b78ff70ffdeada2b3`.

The XTApp store approved and listed **1.7.0**, with Classic and Pro support, Gancao API 2.26. Project `784cb883-9704-4bc7-bbf5-812129d5a80b`, app `u_c410dcba5c524789a6586fa34d935bcf`. GitHub release `https://github.com/jhdvp/ybx-xtapp-plugin/releases/tag/v1.7.0` is public. Installer and Gancao OTA serve the exact validated export. The historical 1.6.17 update catalog remains separate; unrelated local modifications to that immutable old package/catalog were not shipped.

Device seconds remain comparison diagnostics only; credited reading minutes remain server-owned. Physical XTApp OTA installation, position delivery/restoration and counter sleep/restart semantics remain unverified and were disclosed to store reviewers.

Proof and full public-download receipt: `publication/2026-11-16/xtapp-1.7.0-published.jpg` and `publication/2026-11-16/combined-release-receipt.json`. The rollout is complete; do not restart a preflight or publish the old incorrectly labeled Android-modern staging pair.

Naming: Gancao (甘草) and Licorice name the same official firmware family, not distinct regional versions. CN/EN are regional variants. Installer copy must describe the required API and historical app version without presenting those names as incompatible systems.

## XTApp 1.7.1 — official export validated, publication pending

Source `source/ybx-studio` and manifest/index are **1.7.1**, host API 2.26.
Root exported the source through official Studio after permission to sync the
existing YBX project. `package/YBX-1.7.1.xtapp` is **246931 bytes**, SHA-256
`b0112caae138772651c6e54d61a9ec8355ffa1581d72ebe860902037d021c3e7`.
`releases/1.7.1.json` records exact runtime and asset hashes. Official-package
validation, Studio behavioral tests, legacy tests, 200×400-step monkey tests
and all eight release-pipeline tests passed. Source and package are integrated
in local main; the Site Gancao feed update is staged locally with the new file.
No store submission, public GitHub release or server deployment for 1.7.1 is
claimed yet. Complete the combined Site/Installer release gates and publish
from reviewed main. Historical 1.7.0 and legacy 1.6.17 files remain separate.
Physical OTA installation and position restoration are still not verified.
