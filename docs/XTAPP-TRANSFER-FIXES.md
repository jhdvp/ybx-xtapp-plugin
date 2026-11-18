# XTApp 1.7.1 — catalog transfer fixes

The reviewed source in `source/ybx-studio` was exported with official XTApp
Studio on 2026-11-17 as `package/YBX-1.7.1.xtapp` (246931 bytes).
Manifest and code `VERSION` are **1.7.1**; the host API remains **2.26**.
`releases/1.7.1.json` records exact source/asset and package hashes. Structural
validation and all eight release-pipeline tests passed. Publication to the
store, GitHub and the live Installer is tracked separately; an export alone
is not evidence of deployment.

## Native-save watchdog

`timeout_ms` bounds the whole request (XTApp 2.x contract §14). A native save
replaces the file atomically at completion, so the old fixed 35 s idle timer
could cancel a legitimate 60 s save with no visible file growth. Each attempt
sets `F.request_deadline = now() + timeout_ms + 5000`; `on_tick` cancels only at
that deadline. The download uses `timeout_ms = 60000` (65 s deadline). Late
callbacks are fenced by request generation; user Cancel and `on_leave` cancel
the handle and clear pending state. No cross-host save retry was introduced.

## Partial catalog results

`F.catalog_incomplete()` is the single predicate (`incomplete == true` or any
`warnings`). Partial results are never cached or marked fresh:

- Cache format is schema 2; schema-1 blobs are invalidated.
- Foreground `catalog()` caches only complete pages.
- Background `revalidate_page()` keeps the last complete cache/page on a partial
  response; it never lets an unavailable source overwrite them.

The notice is a compact, non-modal inline warning (`ui.catalog_partial`) drawn
over the usable book list, not the modal `message` overlay. A partial **Search**
page now also shows the header **Refresh** action, so retry works with the
query, shelf and page preserved. A complete foreground or background retry
clears the warning. Background recovery only redraws when `message == ''`, so an
unrelated modal error is never dismissed by a background response. `on_load`
resets the flag so a stale warning cannot reappear.

## Explicit pagination

`catalog_path()` sends `page_size=3` (explicit stride) alongside `limit=3`
(item count) and `page=N` for catalogue, search and provider shelves. Callers
that omit `page_size` keep the server's legacy lookahead; the abandoned
`paging=sized` marker is not used.

## Verification

`tests/StudioCatalogTransferTest.lua` drives the real app through public
callbacks and ordinary taps: paged catalogue/search/provider URLs, partial
foreground/background pages, the partial Search retry, modal-error protection,
cache recovery and the native-save deadline/cancel paths. Root re-runs the
Studio and host suites, validates the official export against its new receipt,
and reviews independently before main integration.
