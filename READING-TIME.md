# Reading time: server owns accounting

XTApp reports a downloaded EPUB identity (partial MD5), progress and a stable device identity through Basic-authenticated PUT /api/v1/crosspoint/kosync/syncs/progress. The wire body contains document, progress, percentage, device and device_id only. Authentication keys stay on the device. No reading duration or fabricated session interval is added.

The server estimates time from positive text movement and reading speed, bounded by elapsed time, and rejects implausible navigation. The local server implementation is reading_metrics.reading_seconds / postgres_kosync._reading_seconds. This is estimated time, not an active-reading measurement. Backward position reports remain valid; server time accounting decides how to interpret them. Replaying an unchanged position must not manufacture fresh client minutes.

The client shows device statistics as local values and cloud statistics as server values; they are not added together. HTTP acceptance of a KOSync report is not proof of delivery to Yandex or of Yandex crediting minutes.

## 1.7.0 comparison diagnostics

The client snapshots genuine cumulative per-book `read_sec` with document, observed_at, percent and a stable sample UUID. POST `/api/v1/crosspoint/reading/diagnostics` uses the paired device Bearer token. No book titles, fabricated active intervals or credited minutes are sent. The persistent bounded queue retains IDs across retries, isolates accounts, and can be disabled in Reader settings.

Schema 29 stores diagnostics and receipt-time server estimate checkpoints separately. Idempotent retries cannot add samples; changed payloads under an existing ID conflict. Old observations, counter resets, missing mappings and uncertain batched intervals do not produce a comparison delta. The admin Diagnostics page groups retained samples by version/model without exposing account or device identities. Server estimates cover the account/book across devices, and receipt intervals can differ from offline observation intervals; these are comparison data, not measured active reading or totals to add to statistics.

Reading-history deletion removes both diagnostic tables for the account. Runtime PostgreSQL never creates schema; migrate 28 to 29 through the owner rollout script before shipping the client.

Physical-device position delivery/restoration, OTA installation and counter sleep/restart semantics remain unverified. Classic keys and Pro touch were checked in the official Studio simulator. Any later use of counters for accounting needs physical-device evidence and overlap replacement rules.
