# ps-edge-cli — Design (v1)

AI-friendly Microsoft Edge automation CLI in **pure Windows PowerShell 5.1** (no external
dependencies). Controls Edge via the **Chrome DevTools Protocol (CDP)** over WebSocket
(`System.Net.WebSockets.ClientWebSocket`). Command set is modeled after Playwright MCP
(`browser_snapshot` / ref-based interaction).

This document is the single source of truth for architecture and command syntax.
Task specs delegated to Codex refer to it.

## Repository layout

```
ps-edge.ps1          # entry point: dot-sources src/*.ps1, then Invoke-PseMain $args
src/NN-name.ps1      # function-only files (NO top-level side effects), NN = load order
  10-util.ps1        #   JSON helpers, free-port helper, output helpers
  20-state.ps1       #   session state file (%TEMP%\ps-edge\state.json)
  30-cdp.ps1         #   CDP WebSocket client + HTTP endpoints (/json/*)
  40-browser.ps1     #   Edge process lifecycle (find/launch/stop)
  50-session.ps1     #   connect to current target, page helpers
  60-snapshot.ps1    #   ref-based page snapshot (injected JS)
  70-actions.ps1     #   click/type/fill/press/hover/select/wait/console
  80-commands.ps1    #   one Invoke-PseCmd* function per CLI command
  90-main.ps1        #   Invoke-PseMain: arg parsing, dispatch table, help
build.ps1            # bundles everything into dist/ps-edge.ps1 (single file)
dist/ps-edge.ps1     # generated, committed artifact
tests/*.Tests.ps1    # throw on failure; run via tests/run-tests.ps1
docs/DESIGN.md       # this file
```

**Bundling contract:** `src/*.ps1` files contain only function definitions, so
`dist/ps-edge.ps1` is produced by concatenating `src/*.ps1` (sorted by name) followed by
the line `Invoke-PseMain @args`. The dev entry `ps-edge.ps1` does the same thing via
dot-sourcing. Both must behave identically.

## Function naming

All functions use the `Pse` prefix (Verb-PseNoun), e.g. `Start-PseBrowser`,
`Send-PseCdp`, `Invoke-PseCmdClick`.

## Session model

- Each CLI invocation is a fresh process. The browser survives between invocations
  because it runs with `--remote-debugging-port`.
- State file `%TEMP%\ps-edge\state.json`: `{ port, pid, userDataDir, targetId,
  attached, downloadDir }`.
  `targetId` = currently selected tab. Commands read it to find the browser.
- Element refs (`e1`, `e2`, ...) are assigned by `snapshot` and stored **inside the
  page** as `window.__pseRefs` (ref -> Element map). They stay valid until navigation.
  Action commands resolve refs there; a missing map/ref yields:
  `Error: ref 'e5' not found - run 'snapshot' first (refs are reset by navigation)`.

## CLI conventions

- Invocation: `.\ps-edge.ps1 <command> [args] [options]`.
- Options are hand-parsed from `$args` (case-insensitive, `-Name` and `--name` both OK).
- Output: UTF-8 text designed to be pasted into an LLM context. Success output is
  plain lines; errors go to stderr as `Error: <message>` with exit code 1; success
  exits 0.
- Every command that talks to the page prints, at the end:
  `# url: <current url>` and `# title: <title>` (helps AI keep orientation).

## Command set (v1)

| Command | Syntax | Implementation notes |
|---|---|---|
| start | `start [-Port 9222] [-Headless] [-Url <url>] [-UserDataDir <path>] [-DownloadDir <path>]` / `start -Attach [-Port 9222]` | Launch Edge with `--remote-debugging-port`, isolated profile, wait for `/json/version`, configure downloads, save state. `-Attach` writes state for an existing CDP endpoint and never launches or changes browser settings. |
| stop | `stop` | `Browser.close` via CDP, fallback kill PID, clear state. |
| status | `status` | Show port/pid/version/tabs, or "not running". |
| downloads | `downloads [-Dir <path>]` | List files in the configured download directory (or explicit `-Dir`), newest first, marking partial downloads. |
| goto | `goto <url>` | `Page.navigate` + wait for load event. Bare domains get `https://`. |
| back / forward | `back` / `forward` | History navigation via `Page.getNavigationHistory` + `Page.navigateToHistoryEntry`. |
| reload | `reload` | `Page.reload` + wait for load. |
| snapshot | `snapshot [-Selector <css>]` | Injected JS walks DOM, emits YAML-ish a11y tree with `[ref=eN]` on interactive elements. See below. |
| screenshot | `screenshot [<path>] [-FullPage]` | `Page.captureScreenshot` (png). Default path `screenshot-<timestamp>.png` in CWD. Prints saved path. |
| click | `click <ref> [-Right] [-Double]` | Resolve ref, scrollIntoView, center coords, `Input.dispatchMouseEvent`. |
| type | `type <ref> <text> [-Submit]` | Focus element, `Input.insertText`; `-Submit` sends Enter key events after. |
| fill | `fill <ref> <value>` | JS: set `.value`, dispatch `input`+`change`. For fast form filling. |
| press | `press <key>` | `Input.dispatchKeyEvent`. Keys: Enter, Tab, Escape, Backspace, Delete, ArrowUp/Down/Left/Right, Home, End, PageUp, PageDown, plus `Control+A` style combos. |
| hover | `hover <ref>` | `Input.dispatchMouseEvent` type=mouseMoved at element center. |
| select | `select <ref> <value> [<value>...]` | JS: set selected options by value or label, dispatch `change`. |
| eval | `eval <javascript>` | `Runtime.evaluate` with `returnByValue:true, awaitPromise:true`; print JSON result. |
| wait | `wait [-Time <sec>] [-Text <str>] [-Gone <str>] [-TimeoutSec 30]` | Poll via `Runtime.evaluate` (document.body.innerText contains / not contains). |
| tabs | `tabs` / `tabs new [url]` / `tabs select <n>` / `tabs close [<n>]` | `/json/list`, `/json/new` (PUT), `/json/close/<id>`, `/json/activate/<id>`. `select` updates `targetId` in state. |
| console | `console` | Reads `window.__pseConsole` (hook injected at start/goto via `Page.addScriptToEvaluateOnNewDocument`). Best effort. |
| cdp | `cdp <method> [<params-json>]` | Raw CDP escape hatch, e.g. `cdp Page.navigate '{"url":"https://example.com"}'`. Prints result JSON. |
| help | `help [command]` | Usage. Also shown on unknown command (to stderr). |

## Snapshot format (AI-facing core)

Injected JS builds a filtered tree of the visible DOM:

```
- document "Page title"
  - heading "Welcome" [level=1]
  - link "Sign in" [ref=e1]
  - textbox "Email" [ref=e2]
  - button "Submit" [ref=e3] [disabled]
  - text: Some visible paragraph text (truncated at ~200 chars per node)
```

Rules:
- Roles derived from tag/type/ARIA (a=link, button/input[type=button|submit]=button,
  input[text/email/...]=textbox, input[checkbox]=checkbox [checked], select=combobox,
  textarea=textbox, h1-h6=heading, img=img "alt", nav/main/form etc. = landmark names).
- Refs only on interactive elements (links, buttons, inputs, selects, [onclick],
  [role=button] etc.). Ref counter increments per snapshot run; map replaces
  `window.__pseRefs` each time.
- Invisible elements (display:none, visibility:hidden, zero-size) are skipped, as are
  script/style/noscript/head.
- Accessible name resolution (simplified): aria-label > associated <label> >
  placeholder > title > trimmed innerText (truncated).

## CDP client rules (PowerShell 5.1)

- Sync-over-async: `.GetAwaiter().GetResult()` with `CancellationTokenSource` timeouts.
- Receive loop: 64KB buffer into MemoryStream until `EndOfMessage` (screenshot payloads
  are multi-MB), UTF-8 decode, `ConvertFrom-Json`.
- Request/response matched by `id`; messages without `id` are events, buffered in the
  connection object for `Wait-PseCdpEvent`.
- `ConvertTo-Json -Depth 12 -Compress` for outbound payloads.
- No PS7-only syntax: no `&&`/`||`, no ternary, no `??`, no `?.`.

## Testing

- Plain PS 5.1 test scripts in `tests/*.Tests.ps1`, throw on failure.
- Integration tests launch real Edge **headless** on a free port with a temp
  user-data-dir, navigate to `data:` URLs (no network needed), and always clean up
  (try/finally: kill process, remove profile dir).
