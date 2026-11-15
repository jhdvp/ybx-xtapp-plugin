# Reading time: server owns accounting

XTApp reports a downloaded EPUB identity (partial MD5), progress and a stable device identity through Basic-authenticated PUT /api/v1/crosspoint/kosync/syncs/progress. The wire body contains document, progress, percentage, device and device_id only. Authentication keys stay on the device. No reading duration or fabricated session interval is added.

The server estimates time from positive text movement and reading speed, bounded by elapsed time, and rejects implausible navigation. The local server implementation is reading_metrics.reading_seconds / postgres_kosync._reading_seconds. This is estimated time, not an active-reading measurement. Backward position reports remain valid; server time accounting decides how to interpret them. Replaying an unchanged position must not manufacture fresh client minutes.

The client shows device statistics as local values and cloud statistics as server values; they are not added together. HTTP acceptance of a KOSync report is not proof of delivery to Yandex or of Yandex crediting minutes.

Future measured source: verify read_sec on both Classic and Pro before uploading it. Check per-book accumulation, sleep/idle treatment, restart persistence, clock changes, resets and offline reading. A lifetime per-book counter does not identify exact active intervals or the days they belong to. Never split a large delta into invented sub-minute sessions merely to satisfy reader_sessions validation. Add a distinct server import contract only after these semantics are verified; measured coverage must replace overlapping estimates, not add to them.

Physical-device position upload/restoration remains unverified. No production settings were changed for this decision.
