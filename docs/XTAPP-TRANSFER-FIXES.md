# XTApp 1.7.0 — catalog transfer fixes

Two source-only fixes in the cloud Studio app (`source/ybx-studio/index.lua`).
Version stays **1.7.0**; the release manifest, Studio export and store
publication are assigned separately by root and are **not** validated here — no
new Studio export exists yet.

## 1. Aligned native-save watchdog

Contract (public XTApp 2.x spec §14): `timeout_ms` (1000..60000) bounds the
**entire** request — Wi-Fi ramp, headers and the complete body. A native save
atomically replaces the whole file just before the completion callback, so the
saved file need **not** show growing byte sizes beforehand. The old fixed 35 s
idle watchdog therefore cancelled legitimate 60 s native saves that had no
visible growth yet.

Fix: each attempt records a per-request host deadline that covers the full
`timeout_ms` plus a short callback grace, and the tick cancels only at that
deadline.

- `F.request_deadline = now() + (timeout or 30000) + 5000` is set in `send()`
  (per attempt, including auto-mode host hops).
- `on_tick` cancels at `now() >= F.request_deadline` (was `now() - request_started >= 35000`).
- The download path requests `timeout_ms = 60000`; the deadline becomes `+65000`.

Consequences covered by tests:
- A native save that completes atomically at **45 s** with no prior file growth
  is accepted (a download is registered) instead of being killed at 35 s.
- A lost completion is still cancelled at **65 s** (deadline + grace), clearing
  `c.state.pending`.
- **Late callbacks after cancellation** are fenced by generation
  (`if generation ~= request_id then return end`) and are ignored.
- **Explicit user Cancel** (loader action) and **`on_leave`** both bump
  `request_id`, cancel the active handle and `clear_partial()` so pending files
  are removed and no download is registered; a completion arriving after either
  is ignored.

Native-save retry across hosts remains **disabled** (unchanged): the aligned
deadline is per attempt and only the existing auto-mode hop path re-arms it; no
retry is introduced.

## 2. Non-persistence of partial catalog results

A catalog response is *partial* when it reports `incomplete == true` or carries
a non-empty `warnings` list/dict — `F.catalog_incomplete(data)` is the single
predicate. Partial results must never be persisted or marked fresh, and they
must never silently replace a known-good page.

- Cache format is **schema 2** (`F.CACHE_SCHEMA = 2`). `cache_save` writes the
  schema tag; `cache_load` rejects any blob whose `schema` is missing or not 2.
  Schema-1 blobs may have persisted pages despite source warnings, so they are
  invalidated rather than trusted.
- Foreground `catalog()` writes cache only when the response is complete
  (`if key and not incomplete then cache_put(...)`). A partial page is shown but
  **not** persisted and **not** marked fresh.
- Background `revalidate_page()` returns before any `cache_put`/`show_page` on a
  partial result, so the **existing complete cache and the visible page survive**
  an unavailable source. A later complete revalidation still redraws even when
  the item signature is unchanged, so the warning clears after recovery.
- Account isolation (owner tag) and cache bounds (`order` trimmed to 10) are
  unchanged.

### Partial UI (non-modal)

The WIP surfaced the partial notice through the global `message` overlay, which
is **modal**: it replaced the whole catalog screen, hid the available books and
drew no header-refresh control, so a retry tap was swallowed. The notice is now
rendered as a compact, non-modal inline warning:

- `show_page()` / `revalidate_page()` set `ui.catalog_partial` (a field on the
  existing `ui` table — no new chunk-level local) instead of raising the modal,
  and keep `view='catalog'` so the books stay listed and tappable.
- The catalog screen draws a one-line warning (`T('catalog_partial')`:
  "Some sources did not respond. Refresh to retry.") with a warning icon; it is
  non-interactive, so it does not steal the book-row or header hit targets.
- Retry reuses the existing header **Refresh** action, already wired to
  `catalog(true)`; a partial page can be retried immediately. A complete retry
  clears the warning, and a subsequent complete background refresh also clears
  it. `on_load` resets the flag so a stale warning never reappears.

The user sees only the understandable warning and the refresh affordance; no
cache/schema internals are exposed, and incompleteness is never hidden.

## Files touched

- `source/ybx-studio/index.lua` — watchdog alignment + partial-catalog
  non-persistence + non-modal inline warning.
- `tests/StudioCatalogTransferTest.lua` — fixture-driven coverage through real
  public callbacks and ordinary taps: old-schema rejection, partial
  foreground/background, complete recovery, atomic-save completion at 45 s with
  no visible growth, 65 s lost-callback cancel, late-callback rejection, and
  explicit user-cancel/leave safety.
- `tests/run-studio-tests.js` — register the new test in the studio suite.
- `docs/XTAPP-TRANSFER-FIXES.md` — this document.

## Limitations

- No new Studio export, package, store publication or release manifest is
  produced or validated in this change; version is intentionally kept at 1.7.0.
- Root independently reviews and re-tests before integration.
