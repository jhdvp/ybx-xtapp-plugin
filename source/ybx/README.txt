YBX XTApp — experimental independent client

Target: stock Licorice X4 Pro API 2.18 and this CrossPoint 2.0.0 XTApp build.
This is a standalone Lua XTApp package, not a port of the website into the firmware.
Its app-local UI is currently English-only; Cyrillic titles/search are supported.
The firmware translation catalog cannot supply strings to stock Licorice packages.
The public protocol reference is https://ybx.app/crosspoint-plugin/device.json
and https://github.com/jhdvp/ybx-crosspoint-plugin (plugin version 1.6.16).
No upstream plugin JavaScript is included. Lua source follows the repository license.
icon.png is the YBX brand mark (three bars on a rounded square) redrawn at
180x180, 1 bit, after https://ybx.app/static/app/apple-touch-icon.png. The YBX
brand artwork is attributed to YBX; no repository-license claim is made for it.

Implemented:
- Device-code pairing with text and QR; manual polling respects server delays.
- All/reading/want-to-read/finished/uploaded shelves and Yandex/WB/LitRes catalogs.
- Combined search; 3 books per page with typographic cover fallbacks.
- Streaming EPUB downloads, HTTPS-only redirects, no bearer token sent across origins.
- App-local EPUB opening and local-book deletion; 32 download records, 32 MiB per EPUB.
  CrossPoint also enforces a 128 MiB aggregate app-files quota.
- Reports book.downloaded after a saved EPUB; retries retain the same event ID.
  Up to 16 pending reports in ybx-events.json; retry one at a time from Settings.
  A full queue or SD error keeps the EPUB and shows a reporting warning.
  Account changes invalidate old reports. The queue contains no access token.
  Timestamp follows the native plugin: Unix time when available, otherwise zero.
- Cloud reading profile, daily calendar, received/pending achievements.
- A limited KOSync credential can be requested and entered manually in firmware settings.
- Token revocation and local sign-out. Downloaded books survive sign-out.

Reader integration and remaining differences:
- With the new CrossPoint reader bridge, opening a saved book from this app enables
  native open/exit/session recording for that file. Up to 16 records are held in
  a 10 KiB app-private FIFO; a full queue drops new records. Returning to/reopening YBX
  uploads them through verified HTTPS. Settings also offers a manual retry.
  Pending book-ID mappings survive local EPUB deletion; tracking files are removed.
  By default reports upload on reopening; the opt-in option below adds
  pre-sleep sync. No reader recording is
  claimed for stock Licorice; its corresponding event source is still unresolved.
- Optional pre-sleep reading delivery is described below.
- The app cannot configure stock KOSync settings automatically. Use its setup screen and
  the firmware's own KOSync UI; actual position synchronization remains firmware-owned.
- Cloud-statistics import into vCodex firmware is absent.
- Downloads live inside the app's own files folder, not the original plugin's /books/ybx.
  Open them from Downloaded books in this app. No native plugin sidecar/event registration
  is created. Uninstalling the stock app can delete its private downloaded books.
These gaps remain work/compatibility questions; this is not a claim of full plugin parity.

Build package using the MIT-licensed community packer at the pinned revision:
  git clone https://github.com/omer-faruq-xteink/touch-licorice-apps
  git -C touch-licorice-apps checkout f5166f069909f52d54631d3d2e1bd0e8ae4528c3
  python scripts/build_ybx_stock_source.py /path/to/staged-ybx
  python touch-licorice-apps/xtpack.py /path/to/staged-ybx -o YBX.xtapp
Use its embedded device public key, not its older --image key-location heuristic.
Requires the packer's Python dependencies. Do not put tokens or personal config in this folder.

Stock install: copy YBX.xtapp to the SD card, install through All Files, launch in Ink App.
CrossPoint: build x4pro-xtapp, copy YBX.xtapp onto the SD card and open it in Browse Files.
The stock image supplied for API research was build 26110501, SHA-256:
9557c6d7cf1f285d0614c73eafeb86d5f77f1b8a9b5874f0011c1438a9c770f8
Stock API evidence includes static analysis and community code, not hardware execution.

Validation so far: mocked Lua tests plus the actual app running inside the C++ host.
The user has shown the catalog/search running on their device and reported a
download error. That establishes catalog execution, not end-to-end compatibility.
The user also reproduced the first-append error with the 0.7.0 UI.
The 0.8.0 changes still require device verification.

Sleep-card integration:
Settings -> Sleep screen -> Refresh card downloads and validates a 480x800 monochrome card into
app-private A/B cache slots. Refresh is foreground-only. CrossPoint offers
Use YBX sleep screen and Restore usual wallpaper. Select Custom in CrossPoint's
sleep-screen settings. Cover+Custom also uses it when falling back to Custom;
Quick Resume and the remaining modes keep their behavior.
Use YBX sleep screen again after a refresh to replace the selected snapshot.
No /sleep.bmp or existing wallpaper is overwritten. The selected snapshot is
stored separately, and removing the selection restores the normal Custom path.
Another app can replace the global selection; YBX cannot clear that app's choice.
Storage errors can prevent selection/restoration and are reported in the app.

For a stock package with a lock-screen entry, stage the source first:
  python scripts/build_ybx_stock_source.py /path/to/staged-ybx
  python touch-licorice-apps/xtpack.py /path/to/staged-ybx -o YBX.xtapp
On stock, choose Use YBX sleep screen and confirm the system dialog;
Settings -> Display -> Off wallpaper must be Default. Restore usual wallpaper
clears the choice only when YBX is selected. The stock lock entry draws the
newest valid cached image. Networking is disabled by default; the optional stock
refresh described below attempts to update this cache.
CrossPoint accepts that same two-entry package but does not execute its lock Lua;
it renders the explicitly selected snapshot using its existing BMP renderer.
Stock lock entry execution, image decoding, and EPUB opening remain unverified
on hardware. The delivered 0.5.0 sleep changes passed independent reviews. See the candidate VALIDATION.txt for
build results and remaining hardware/acceptance limits.

Automatic CrossPoint refresh (0.4.0 experimental candidate):
Settings -> Sleep screen -> Refresh options -> Refresh before sleep selects the cached image and stores an app-private
HTTPS GET request. Custom and Cover+Custom modes attempt to update the snapshot
before sleep when battery is at least20%; Quick Resume skips this work. The
existing saved-network join has a10second budget; the image loop cancels after
15seconds, followed by network cleanup. These are software budgets, not measured
hardware shutdown latency. Failure preserves the previous snapshot. Native
plugin events still drain first. Image refresh itself does not upload events; the separate option below enables sync first.
Turning Refresh before sleep off removes the stored request. Restore usual wallpaper
also disables it. Account changes and local sign-out require successful removal
of the persisted request before changing the local token; storage failures cancel
that account change and show an error. The stored request contains a copy of the
device token, in app-private SD storage. It is never printed in build/runtime logs.
The delivered 0.5.0 package uses only its foreground-refreshed cache on stock.
The 0.6.0 candidate adds the conditional stock refresh described below.

Reading sync before sleep (0.5.0 experimental candidate):
Settings -> Reading sync -> Sync before sleep is a separate toggle.
For the app owning the last opened EPUB, CrossPoint attempts up to16 queued
reports within a15second request-loop budget before refreshing the sleep image.
Battery must be at least20%; Quick Resume skips it. Worker cleanup can extend the
elapsed time; actual hardware latency is unmeasured. The current reading session
is flushed before this hook. A later reader.exit can remain for the next retry.
Events are removed only after HTTP2xx and a matching queue/account snapshot.
Partial delivery keeps the remaining events with unchanged IDs. Invalid records,
missing book mappings and uncertain storage stop delivery without deleting data.
This option has its own app-private request configuration with the device token.
Account change/sign-out must clear both saved configurations or report failure.
It does not add stock Licorice reading-event capture. Source tests use simulated
network/storage. Independent reviews passed; see candidate VALIDATION.txt for
final build results and remaining device/account verification.

Conditional stock refresh (0.6.0 experimental candidate):
Settings -> Sleep screen -> Refresh options -> Refresh before sleep saves an app-private refresh token. Once per lock-entry
load, the app attempts one HTTPS GET with a requested15second timeout if the host
provides networking. It does not force Wi-Fi on. Unsupported networking or failed
responses keep the cached card. A complete valid BMP and unchanged configuration
are required before updating the cache. Leaving the lock entry cancels its job;
late callbacks cannot update storage. Turning Refresh before sleep off clears the
saved token; restoring the stock lock screen or changing accounts clears it too.
Failure to clear it blocks a local account change and reports that explicitly.
The weather app in the pinned community SDK uses a similar conditional sideloaded
lock request, but notes that store lock entries lack network access. This is an
implementation basis, not evidence that build26110501 permits it. Hardware behavior,
request timeout enforcement and Wi-Fi availability remain unverified. Disabled by
default; the manual foreground refresh remains available.

0.7.0 UI and download update:
- Font-measured titles, wrapped book rows, author-line touch targets, compact
  paging/search/home controls, a clearer home and book screen, contextual Back.
- Stock drawer icon copied from YBX. CrossPoint Browse Files uses its existing
  file browser; adding an icon does not change that firmware UI.
- Network chunks are appended in <=16 KiB pieces. Static stock analysis shows
  a 256 KiB per-call write argument limit; callback chunk size is not assumed.
  The user's error does not prove oversized callbacks were its cause.
- Storage errors, including a short returned code, are distinct from the 32 MiB
  EPUB cap. Cancelled requests ignore late data callbacks. Partial files are
  removed on failure. Current device reproduction remains outstanding.
- The existing 0.5/0.6 CrossPoint firmware is sufficient; no reflash is required
  when upgrading only this app. Install the new XTApp without uninstalling the
  old app first, since uninstalling can remove its downloads and private state.

0.8.0 approved design implementation:
Library / Search / Activity replaces the old home menu. Three substantial book
rows use author-initial cover fallbacks, wrapped titles, author and local-file
status. Settings is the header control. Primary actions are rounded outlines;
touch mode has no permanent selection box, while physical keys show focus.
Book details preserve the originating shelf/search/page. Descriptions and
progress are shown only when provided. The native EPUB reader remains external.
Pairing, connection expiry, empty shelves, download progress/completion/failure,
account confirmation, diagnostics, activity/calendar/achievements and sleep/sync
settings have their own layouts. KOSync credentials are concealed until revealed
and cleared on leaving that page. Existing download files and token state remain
compatible. No migration or native firmware reflash is required.

Stock append issue: the user reproduced failure at0KiB on stock Licorice.
The app checks append availability before creating the EPUB. It uses storage's
append method or the documented files alias when the former is unavailable.
It never retries a failed write through another API, which could duplicate bytes.
Thrown exceptions and returned failure reasons are retained in Technical details.
This is compatibility handling and diagnosis, not proof the device error is fixed.

Sleep preview uses host image decoding when available; otherwise a32x48 sampled
monochrome preview uses at most768 packed runs (~8KiB Lua array capacity).
The source BMP is48,062bytes and temporary during preview creation. The worst
preview remains below the native1024-draw-command limit including controls.
Only bounded metadata is retained for activity and achievements. Browser/desktop
rendering uses substitute fonts; final glyph wrapping and touch need device checks.

0.8.1 stock download compatibility candidate:
Stock Licorice uses a native net:request save target instead of Lua on_data plus
append. CrossPoint keeps its bounded streaming path. Native saved files are
checked for ZIP prefix, size and HTTP Content-Length before recording
completion. The 32 MiB limit is checked during ticks and at completion; native
writes can exceed it between ticks. Failed files are removed.
Storage check now requests an explicit read length/offset and reports actual
read type, size and sample instead of a bare assertion. Search uses a rounder
magnifying-glass outline. Install over the existing app; no firmware reflash.

0.8.2 bounded stock read correction:
Licorice read arguments are name, offset, length. Version0.8.1 reversed these
for native download validation and the storage test. The corrected prefix read
requests four bytes at offset zero. The mock now follows the stock contract.
A real authenticated download of the reported book returned587091 bytes and
passed ZIP CRC/mimetype checks. Replaying those bytes through the Lua app with
the corrected stock contract rejects0.8.1 and accepts0.8.2 byte-for-byte.
This local replay is not stock firmware execution; device verification remains
necessary. The earlier append/read-back issue is not established as fixed.

0.8.4 stock download and report fixes:
Static analysis of build26110501 shows two separate save namespaces in the net
job. save={to='storage'} writes %s/%s/files/%s under /sdcard/XTApps and aborts
with limit_exceeded above 256 KiB. save={to='files'} writes to the app sandbox
/sdcard/AppFiles/<app>/<name> - the same directory ctx.storage, the files alias
and system:open('file') use - with an 8 MiB cap. 0.8.1-0.8.3 used the first,
so the firmware never placed the EPUB where the app verifies it and larger
books aborted. The native path now targets 'files'; limit_exceeded is reported
as an 8 MiB firmware limit instead of a bare HTTP 0. CrossPoint is unchanged.
book.downloaded event IDs are now <8 lowercase hex>-<decimal>, minted from a
per-launch nonce plus a counter, because YBX /events answers HTTP 400 for any
other shape. Queues saved by older builds held 32-hex IDs that were always
rejected; they are re-minted and rewritten once on load, so pending reports
survive the upgrade and are delivered instead of retrying forever.

0.8.5 stock download path corrected again after a device report:
0.8.4 on stock answered HTTP 200 but the app still found no readable EPUB, so
'to=files' did not place the file where ctx.storage sees it either. Rather than
guess further, the app now prefers the bounded streaming path (on_data plus
storage.append in <=16 KiB pieces) on both firmwares whenever append is
available, because it writes through the same ctx.storage calls the app already
uses for its own state files, has no 8 MiB per-download ceiling and lets the app
verify every byte itself. The native firmware save stays only as a last-resort
mode when no append method exists, and also as a one-shot retry: if the very
first streamed append fails on stock before any byte is stored, the app repeats
the request once with the native save instead of failing immediately. Failure
details now include the app's byte count and, when the firmware reports one, its
own 'saved' byte count, so a future mismatch is visible on the device. The
native save target remains 'files' for those fallbacks.

0.8.6 throughput and time-limit fixes after the second device report:
0.8.5 streamed 425984 of 587091 bytes and stopped. Static reading of the stock
net job shows the body transfer is bounded by time: the streaming deadline is
120 s (0x421495fa) and the request timeout_ms is clamped to 1000..60000 with a
30000 default (0x42149298), i.e. a ~14 KiB/s link can deliver roughly 420 KiB in
30 s - exactly the observed cut. Two changes: downloads now pass the maximum
timeout_ms=60000, and network chunks are batched in Lua and appended in 128 KiB
blocks instead of <=16 KiB pieces, so one EPUB costs about five resolve/stat/
open/flush cycles on the SD card rather than one per chunk. The incomplete-body
message now appends the firmware's own error code when it reports one. CrossPoint
is unaffected (it ignores timeout_ms and streams 8 KiB chunks, which are still
appended in 128 KiB batches).

0.8.7 stock saves through the firmware again, with verification:
0.8.6 still stopped short (327187 of 587091 bytes). A throttled reference
download (curl --limit-rate 10k) fetched all 587091 bytes in 57 s, so the
service does not cut slow clients; the stock Lua streaming path is simply paced
by the host loop (~11-14 KiB/s) and cannot finish a book inside its own 120 s
window. Stock therefore uses the firmware save (net:request save) again, which
writes on the network side with no per-chunk Lua round trips, while CrossPoint
keeps streaming with 128 KiB appends. Because a save can land in the app sandbox
under a name other than the requested one, the app now lists ctx.storage after a
save and, when an entry matches the response Content-Length, copies it to the
expected file in 64 KiB reads. A save that leaves nothing readable reports both
byte counts and the sandbox listing (e.g. "app sees 0 B, firmware saved 587091 B,
files: ...") instead of a bare HTTP 200, which pins the failing layer.

0.8.8 holds Wi-Fi awake during transfers:
0.8.7 proved the native save leaves nothing readable on this build ("app sees
0 B, firmware saved -, files: none"), so the file has to come through
ctx.storage. The community SDK in this workspace (licorice-apps, api 2.17/2.18)
shows what YBX was missing: every network app calls
ctx.net:keep_wifi(5*60*1000) before requests and releases it with keep_wifi(1)
when leaving; its rss app documents that the reader otherwise drops Wi-Fi while
idle and each request pays ~7 s to come back. A long EPUB transfer loses its
socket that way, which matches the previous cuts at 425984 and 327187 bytes with
HTTP 200. 0.8.8 keeps Wi-Fi up for five minutes before every request, refreshes
the hold from the streaming callback (at most every 30 s) and releases it on
leave. Stock streams into app storage again (the native save remains only for
hosts without append), still with 128 KiB appends, the 60 s request timeout and
the listing/byte-count diagnostics.

0.8.9 zero-copy streaming, native save without a pre-created target, timing:
0.8.8 (holding Wi-Fi) changed nothing, so the service and the radio were tested
again from outside: curl --limit-rate 10k fetched all 587091 bytes in 57 s and
--limit-rate 2k in 287 s, both HTTP 200 with a valid ZIP, so no server or proxy
timeout touches slow readers; Range requests answer 200 with the whole body
(accept-ranges: none is real), so slicing the book is not possible. The stock
host therefore stops delivering on its own. 0.8.9 removes the two remaining
app-side risks and makes the next report measurable:
- the streaming callback hands each delivered chunk straight to
  storage.append (one call, no Lua copy, no 128 KiB staging string), because the
  host already allocates the chunk and a second copy doubled peak heap during a
  long transfer; chunks over the 256 KiB per-call cap are still split.
- the native-save path no longer pre-creates the destination file: the firmware
  writes its own temp and renames it onto the name, and a pre-existing empty file
  can defeat that rename (every earlier native attempt pre-created it).
- the incomplete-body detail now reports elapsed milliseconds, the number of
  callbacks and KiB/s, and the native detail distinguishes "file missing" from
  "app sees 0 B".

0.9.0 collect during the transfer and tick faster:
0.8.9 removed the bottleneck: the device now reports 887529 of 1215209 bytes in
13 chunks, 1861 ms, 487 KiB/s. So the host no longer runs out of time, it stops
delivering after ~73% of a fast transfer. The host allocates a new Lua string for
every delivered chunk and keeps nothing else, so the heap grows with the body
unless the collector runs; the earlier 128 KiB staging copy made this fail
sooner (425984, then 327187 bytes), and zero-copy moved the stop to 887529.
0.9.0 therefore calls collectgarbage from the download callback after each
chunk (captured at load; ignored when the firmware does not expose it) and sets
the tick to 100 ms for the duration of a transfer, restoring 1000 ms afterwards,
so a host that steps its collector on ticks collects during the download too.
The incomplete-body detail now also prints gc=on/off and the heap size when
collectgarbage is available.

0.9.1 the book tree is ctx.files (answered by the on-device probe):
YBXPROBE on the reader (api 2.21) printed:
  storage w=true size=5 read=string app=none
  files   w=true size=5 read=string app=true
  cross: S sees pv-files.txt=nil
  save files   status=200 saved=true S=nil F=257
  save storage status=200 saved=true S=257 F=nil
So ctx.storage and ctx.files are separate trees on this build, only ctx.files has
append, net:request save.to selects exactly the named service, and
system.open('file') reads the files tree. 0.8.4-0.8.7 wrote the EPUB into
ctx.files but checked ctx.storage, which is why the device always reported a
missing/empty file while the firmware answered HTTP 200. 0.9.1 keeps every EPUB
operation (write, append, size, read, remove, list, and the storage self-test)
on ctx.files, falling back to ctx.storage only where no files service exists
(CrossPoint). Stock therefore uses the firmware save first - no per-chunk Lua
strings, up to 8 MiB - verifies in the same tree, opens through system:open and
adopts a same-size entry from that tree; if the save leaves nothing readable the
app retries once through ctx.files streaming (batched, Wi-Fi held).

0.10.0 Cyrillic keyboard and three UI languages:
The stock reader ships an English/Latin on-screen keyboard only, so Russian and
Kazakh search was impossible. The app now draws its own keyboard (view
'keyboard'): Latin, Russian and, when enabled in Settings, Kazakh. Layout keys
are ЙЦУКЕН for Russian; Kazakh keeps the same three rows and adds a fourth row
with ә і ң ғ ү ұ қ ө һ. Shift, 123/abc, layout switch (EN/РУ/ҚА), delete,
space and comma/period/@ are on the pad; Done/Cancel and the physical Ok/Back
keys work as expected. The typed string is bounded to 128 bytes and encoded with
the same percent rules as before.
Settings gains two rows: Language cycles English -> Русский -> Қазақша (stored in
app state as ctx.state.lang and applied immediately to headings, buttons,
shelves, settings rows and the common status messages), and Kazakh keyboard is an
opt-in switch (ctx.state.kb_kk) that adds the Kazakh layout to the keyboard
without changing the UI language. Russian remains always available.
Strings live in one STR table keyed by name with en/ru/kk columns and a T()
lookup, so adding a language is one more column. Long diagnostic texts (storage
self-test details, HTTP error bodies) remain English.
Tests cover: opening the keyboard from Search, switching EN->РУ, typing Тест
with and without Shift (URL-encoded query asserted), switching the UI to Russian
and Kazakh and back, enabling the Kazakh layout and typing ә (D3 99 asserted).

0.10.1 keyboard matched to the firmware layout:
The first cut of the app keyboard put the pad right under the search field and
used its own Cancel/Done arrangement. It now follows the firmware keyboard
(FreeInkUI compact layouts, which the CrossPoint KeyboardEntryActivity uses):
- the text field stays at the top and the pad is anchored to the bottom edge of
  the 480x800 screen;
- three letter rows plus a bottom row; Shift and Del sit at the ends of the
  third row, and the bottom row is [?123] [EN/РУ/ҚА] [wide Space] [OK];
- keys are sized in units so each row fills the width, and the letter font
  steps down on the long Cyrillic rows;
- there is no separate Cancel key: the header Back (and the physical Back key)
  cancels, OK (or the physical Ok key) accepts, like the firmware keyboard;
- layouts are the firmware's own CyrillicRu and CyrillicKk rows, so Kazakh puts
  ұ қ ң ғ һ on the first row and ү і ә ө on the second instead of a fourth row;
- no shared modifier row; Shift toggles case only.

0.10.2 keyboard and switch redesign:
The 0.10.1 pad squeezed Kazakh into the Russian rows (17 keys, ~21 px each, small
font) and drew keys as bare letters with no outlines. Now:
- every key is an outlined rounded cell, 64 px tall; letters use the medium font;
- English is QWERTY 10/9/7; Russian is standard ЙЦУКЕН 12/11/10 with ё closing
  the third row; Kazakh is the Russian pad plus its own top row
  ә і ң ғ ү ұ қ ө һ (nine ~45 px keys) under a thin divider;
- Shift and Delete are drawn icons (an outlined arrow; filled while Shift is
  on), the layout key is a globe with the code EN/РУ/ҚА, the space bar is
  labelled with the layout name (English/Русский/Қазақша), and OK is wider with
  a bold border and a check mark;
- the "EN / РУ / ҚА" caption above the pad is gone.
Switches are a 64x34 pill: on is a solid track with a white knob holding a
check mark, off is an outlined track with a solid knob. Both are drawn with
1 px spans, so no colour or circle primitives are needed. The Settings row is
now "Kazakh layout" under a "Keyboard" caption, with the added letters as a
second line. fill() rounds to whole pixels and skips empty spans.

0.11.0 cached library, background prefetch, Russian by default, new translations:
- Library cache (ybx-cache.json in app storage, owner-bound, wiped on sign-out):
  up to 10 shelf pages plus the raw stats, achievements and calendar responses.
  Launch opens straight onto the cached Reading shelf; a cached screen opens at
  once and is refreshed by a quiet background request, redrawn only if it
  changed. The blocking "Connecting to YBX" screen now appears only on a cache
  miss, a search, a download or an explicit refresh (new header button and
  Try again).
- Background requests: one at a time, no loader, 20 s timeout (cancelled at
  25 s), dropped as soon as a foreground request starts, and they respect the
  server's Retry-After. A 401 signs out as before.
- Idle prefetch (browsing screens only, 3 s after the last input, two tries per
  item): Reading and All books page 1, the page after the one on screen, stats,
  achievements and the current calendar month, each once per session.
- A fresh install starts in Russian; Language still cycles EN/RU/KK.
- The translation table was rewritten for context, and every remaining
  hard-coded English screen and status message now goes through it (stats,
  calendar, achievements, sleep screen, reading sync, KOSync, help, errors).
  Month and weekday names and full dates are localised ("9 ноября 2026",
  "2026 жылғы 9 қараша"). Raw diagnostic details stay English on purpose.
  The Activity tab is now Stats/Статистика.
- Success messages get a "Done" title by message key instead of guessing from
  English words; streak shows a number with a "Days in a row" label (no plurals).
- The on-screen keyboard opens in the UI language (РУ, or ҚА when the Kazakh
  layout is on) until the reader switches layouts.
- Layout: settings-row values are right-aligned and no longer cut to 72 px
  ("Eng..."); header titles fit the space left by header buttons.
- Every screen was rendered in en/ru/kk with Arial metrics at the firmware's
  20/24/30 px line heights and checked for truncation, off-screen text, text
  overlaps and text crossing dividers or button outlines: none found.
- Fixed: submitting an empty search called go() before it was defined.

0.12.0 parity with the CrossPoint plugin 1.6.15:
Compared against ybx-plugin 1.6.15 (device.json + the web page plugin.js).
- Requests now carry v=1.6.15 (also the stock lock-screen refresh).
- European mirror (emy.ybx.app). Help & diagnostics -> Server: Auto / Main /
  Europe. Auto retries a request that got no HTTP answer once on the other host
  (not for firmware-saved downloads or after data arrived) and keeps a working
  mirror for 5 minutes, like the plugin. Main and Europe use exactly one host.
  Addresses handed to the firmware (sleep refresh, sync before sleep, stock
  lock-screen refresh) follow only an explicit choice. The pairing QR uses the
  server's verification_uri_complete when it points at a YBX host.
- Stats: books finished this year ("Books in 2026"), yearly-goal pace (ahead /
  behind / on track, with Russian plural forms), and Continue reading (the
  summary's currently_reading, up to 4 books).
- Book card: GET /reading/books/{id} -> progress, time read, sessions, start and
  finish dates and data sources, with Open book to reach download/read.
- KOSync: shows the plain-HTTP sync host the plugin now uses
  (http://sync.ybx.app/..., esync for Europe) plus the HTTPS address, and
  Check key verifies the issued key against /kosync/users/auth over HTTPS.
- Quotes and notes: separate KOSync key via /auth/clippings-key, validated like
  the plugin (kosync_ + 43 chars, YBX sync_url, clippings_enabled), and revoke.
  Useful only if the firmware's KOSync syncs quotes.
- Errors: 403 signs out like 401; 404 with X-YBX-Device-Removed and 502/503/504
  get their own messages.
- Not portable to Licorice: writing the firmware KOSync settings, vCodex stats
  export, plugin self-update, /books/ybx + sidecar files, X3 sleep size.
- Helpers moved into a table F: the main chunk had reached Lua's 200-local limit.

0.12.1 store shortcuts:
- The Library screen has Яндекс / WB / ЛитРес buttons under the shelf tabs (in
  place of the "Your library" caption), matching the plugin's top-level store
  lists. One tap opens that store's catalog; tapping the active store returns
  to All books. Filter still reaches Want to read / Finished / My uploads, and
  opens with the current store preselected.
- The first page of each store is prefetched once per session, after the other
  background items, so the buttons usually open without a loader.
- ЛитРес is spelled as in the plugin (was Литрес).

1.6.15 store connection help; version aligned with the plugin:
- New "Connect stores" screen: a QR code and link to https://ybx.app, where
  Yandex Books, WB Books and LitRes are connected, plus Refresh library.
  Three ways in: the (i) button next to the store buttons in Library, the first
  row of Help & diagnostics, and a "How to connect" button on the "store not
  connected" message (HTTP 409). The QR image is released when the screen is
  left or the app closes.
- The app version now follows the CrossPoint plugin it mirrors: 1.6.15 (the
  previous app build was 0.12.1). The About screen and the v= parameter on
  every request show the same number.

1.6.15 build corrections (rebuilt package):
- Quotes (clippings) key: the sync URL may be the main host or the EU mirror
  (https://emy.ybx.app). The server hands back the clippings base of whichever
  host the request used, and both bases share one clipping store, so a reader
  whose main host is blocked can still sync quotes. Any other host, scheme or
  path is refused.
- Native stock save: a boolean "saved" with Content-Length now reports the
  firmware byte count instead of a nil local.
- The package is built by scripts/build_ybx_stock_source.py and its consistency
  with the source is checked by tools/validate_source.py.

1.6.16 version alignment (rebuilt package):
- The version follows the CrossPoint plugin 1.6.16: the About screen and the
  v= parameter on every request, including the stock lock-screen refresh, now
  report 1.6.16. Behaviour is unchanged; the quote-key handling already accepts
  both trusted clippings bases (main and the EU mirror).

Hold to delete (after 1.6.16):
- Holding Delete on the keyboard keeps deleting: one letter on touch, then
  after 450 ms one every 120 ms until the finger lifts or slides off the key.
  The tick runs at 100 ms only while held, then returns to the download or
  idle rate. A plain tap still deletes exactly one letter.
- Fixed: header() returned no value for a missing header, and tonumber() of
  nothing raises an error, so a 429 without Retry-After (or a download without
  Content-Length) would crash. It now returns nil explicitly.

Testing: tests/YbxMonkeyTest.lua drives the app on stock and CrossPoint hosts,
signed in or not, with random taps, keys, touch holds, ticks, restarts (fresh
Lua state), resumes, language switches and corrupted saved files/state, while
every request gets an endpoint-shaped random answer (valid, missing fields,
wrong types, no response, 0/401/403/404 with and without device-removed,
429 with and without Retry-After, 409/5xx, redirects, short downloads). It
fails on any Lua error, off-screen drawing, or a busy screen with no request
in flight. Release run: 2000 runs x 500 steps. With the header() fix
reverted it finds the crash at three call sites.

Book file names (after 1.6.16):
- Downloaded books are named "<Author> - <Title>.epub" instead of a number.
  Storage name rules are not fully known (an early probe said no spaces;
  Cyrillic untested), so each candidate is tried with an empty write and the
  first accepted one is used: as written, then spaces as underscores, then
  transliterated Latin, then the old numbered name. A name already used by
  another book gets " (2)" and so on. Names stay under ~170 bytes by shortening
  the title. Old numbered downloads keep working.
- On CrossPoint the reading tracker writes "<name>.track" to ctx.storage, so a
  name is used only if that sidecar name is accepted too. File-name checks in
  the downloads list and the reader book map accept any safe .epub name; a stale
  pending download is removed only if it is not a saved book.

Update channel (after 1.6.16):
- The app asks {host}/xtapp/latest.json at most once a day after the first
  shelf load (only when the device clock is available) and on demand from
  About. A newer version opens a dialog; the package downloads into the app
  files folder and the app shows its ctx.files.path and the All Files
  instructions. The host has no install API and cannot open .xtapp, so
  installation stays manual; books, settings and the token survive it.
- Publishing: python scripts/publish_xtapp.py --notes "..." builds, writes
  static/xtapp/latest.json plus the package into the site and creates the
  GitHub release v<version>. Rollout to devices is the site only.
