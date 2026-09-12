# vibeee Script Worker (design/13-script-worker.md)

> **Status: proposed, not implemented.**
>
> Context: the reader's scripts run QuickJS, Lexbor, the DOM bridge and a small amount of C glue in the `web` process. A fault in any of them reaches the kernel's page-fault path and takes the browser down; `hln.be` reproduced that. QuickJS memory and stack limits (already set) bound managed allocation and interpreter recursion only. They do not contain native faults.
>
> This document designs the containment boundary. Until it is built, a page can still crash the reader.

Subsystem: `apps/web/script_worker.zig` (new), `apps/web/web.zig`, `apps/web/scripts/dom.zig`, `src/user/js`.

## 1. Problem

A page is untrusted input. Today the whole script stack shares the browser's address space:

```text
web process
├── fetch, cookies, history, settings
├── lexbor parse
├── QuickJS runtime
├── apps/web/scripts/dom.zig  (DOM bridge)
├── src/user/js/port/*.c      (C glue)
└── layout + view
```

Any of these can fail in ways QuickJS cannot turn into a script exception:

- a bad pointer in the DOM bridge,
- a Lexbor assertion or callback misuse,
- an ABI mistake in the QuickJS mirror,
- stack exhaustion on a path QuickJS does not police,
- a C-library abort.

The kernel reports these as faults; the reader dies. No QuickJS allocation limit fixes that.

## 2. Decision

Move the script stack into a **disposable worker process**.

- `web` keeps everything that must survive a page: network, cookies, history, settings, layout, view, rendering, input.
- `worker` owns everything a page can corrupt: QuickJS, the DOM bridge, the C glue, and the parse/extract of the page the scripts run against.

The worker is the only thing a page can crash.

## 3. Architecture

```text
web (browser, long-lived)
 ├── fetch/cookies/history/settings
 ├── layout + view + input
 └── channel to worker
      │
worker (per navigation, disposable)
 ├── lexbor parse of the markup
 ├── QuickJS runtime
 ├── apps/web/scripts/dom.zig
 └── src/user/js/port glue
```

The worker is spawned per navigation, or reused only for same-origin sub-navigations where the tree is retained; the simplest correct rule is **one worker per committed navigation**, killed on the next one.

## 4. Ownership

### `web` owns

- TCP/TLS fetch and the blocklist,
- the cookie jar (so cookies survive worker death),
- history and settings,
- the retained `page_mod.Page`, layout, and drawing,
- the address bar and all input.

### `worker` owns

- the parsed lexbor tree for one page,
- the QuickJS runtime and contexts,
- script-visible state: timers, listeners, `localStorage`/`sessionStorage` for that page,
- the DOM bridge and C glue.

Script-visible storage that must outlive the page (cookies) is **not** owned by the worker; the worker asks `web` to read and write it.

## 5. Message protocol

Bounded, length-prefixed messages over an existing channel/ring with a hard cap (e.g. 64 KiB inline; larger payloads via shared memory). Each message is a tagged union.

### web -> worker

| message | payload |
|---|---|
| `start` | address, user agent, markup bytes, charset, kept stylesheets |
| `script` | inline source, or external URL to run |
| `click` | control index / run index |
| `typed` | control index, value, submitted? |
| `fetchReply` | request id, status, body bytes or error |
| `cookieRead` | request id |
| `cookieWrite` | `Set-Cookie`/`document.cookie` assignment |
| `tick` | timer wheel advance |
| `stop` | — |

### worker -> web

| message | payload |
|---|---|
| `page` | serialized extracted `page_mod.Page` (blocks, runs, strings, links, forms, controls, pictures, containers) |
| `navigate` | target URL |
| `fetchRequest` | request id, URL |
| `cookieValue` | request id, cookie line |
| `scriptError` | source URL, exception text |
| `missing` | capability name (for the missing-API telemetry) |
| `stopped` | exit reason |

`page` is the whole current page model; sending a fresh snapshot on mutation keeps the protocol simple and bounded by page size, which the reader already holds in memory.

## 6. Lifecycle

1. `web` fetches, parses headers, and decides it is a page.
2. `web` spawns `worker`, sends `start` with markup and stylesheets.
3. Worker parses, runs scripts, sends back the first `page`.
4. `web` lays out and draws.
5. Script timers/listeners keep the worker alive; each mutation produces a new `page`.
6. On navigation, `web` sends `stop`, waits briefly, then kills and spawns a fresh worker.
7. If the worker dies unexpectedly, `web` keeps the last rendered `page`, marks the page "scripts stopped", and shows that in the status area.

## 7. Failure handling

This is the point of the design.

- Worker exit / channel peer-death -> `web` catches the existing channel error, keeps the rendered page, and continues to be usable: scroll, links, back/forward all still work off the last snapshot.
- Repeated worker death is bounded: after a crash on start, do **not** respawn in a loop. Mark the page as script-disabled for that navigation and let the user navigate again to retry.
- Worker never holds the only copy of: cookies, history, settings, or the rendered page.
- Worker memory and stack limits still apply, and now they protect the browser's RAM budget as well as the engine.

## 8. Resource limits

- QuickJS: memory limit and max stack size (already set: 8 MiB / 512 KiB) are now per-worker.
- Worker: a heap cap enforced by the supervisor; exceeded -> kill worker, keep page. Current QuickJS limits only bound the engine's managed allocation, not the worker's total. Keep both: engine limits turn script bugs into exceptions; worker cap turns runaway allocation into a dead worker, not a dead browser.

## 9. Migration

Keep the change small and reversible:

1. Add `script_worker.zig` with the same public entry points `dom.bind/load/click/typed/loop/waits/release`.
2. Move `apps/web/scripts/dom.zig` and `src/user/js` behind the worker boundary.
3. Serialize `page_mod.Page` between worker and web.
4. Replace direct calls in `web` with channel sends.
5. Keep the current in-process path behind a build flag (`-Dscript-worker=false`) until the worker path is proven by tests and by the same target traces used today (`web -t`) and manual VNC runs.

The current `scripts` setting (on/off) still works: with scripts off, `web` never spawns a worker.

## 10. Testing

- Host tests: message encode/decode round-trips, bounded sizes.
- Host tests: worker start/stop lifecycle and restart-on-navigation.
- Fault-injection tests: kill the worker mid-page; assert `web` keeps the last page and remains responsive.
- Target traces through `web -t`: confirm script errors and missing-API telemetry survive the boundary.
- Manual: the sites that crashed or misbehaved (hln.be, standaard.be, Google consent) navigated in VNC with the worker enabled.

Fault injection is the load-bearing test: it is the only test that proves the guarantee "a page cannot crash the browser".

## 11. Open questions

- Whether the worker parses, or `web` parses and ships a serializable tree. Parsing in the worker keeps the risky code in the disposable process; shipping a parsed tree across a channel is more work. Recommendation: worker parses; `web` only ships markup + stylesheets.
- Whether one worker per navigation is too costly at 630 MHz. Measure; consider reuse for same-document (hash/timer-only) updates, which do not need a new tree.
- Exact serialization format for `page_mod.Page`: a stable, versioned, length-prefixed layout, not a host-memory dump.
