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
  45-download.ps1    #   browser-level download event watch + JSONL event log
  50-session.ps1     #   connect to current target, page helpers
  60-snapshot.ps1    #   ref-based page snapshot (injected JS)
  70-actions.ps1     #   click/type/fill/press/hover/select/wait/console
  80-commands.ps1    #   one Invoke-PseCmd* function per CLI command
  90-main.ps1        #   Invoke-PseMain: arg parsing, dispatch table, help
build.ps1            # bundles everything into skills/ps-edge/scripts/ps-edge.ps1 and syncs .claude/skills
skills/ps-edge/      # distributable agent skill folder
skills/ps-edge/scripts/ps-edge.ps1  # generated, committed artifact
.claude/skills/ps-edge/             # generated, untracked dogfood copy
tests/*.Tests.ps1    # throw on failure; run via tests/run-tests.ps1
docs/DESIGN.md       # this file
```

**Bundling contract:** `src/*.ps1` files contain only function definitions, so
`skills/ps-edge/scripts/ps-edge.ps1` is produced by concatenating `src/*.ps1` (sorted by name) followed by
the line `Invoke-PseMain @args`. The dev entry `ps-edge.ps1` does the same thing via
dot-sourcing. Both must behave identically. `build.ps1` also copies the canonical
`skills/ps-edge` folder to `.claude/skills/ps-edge` for project-local dogfooding; that
copy is generated and untracked.

## Function naming

All functions use the `Pse` prefix (Verb-PseNoun), e.g. `Start-PseBrowser`,
`Send-PseCdp`, `Invoke-PseCmdClick`.

## Session model

- Each CLI invocation is a fresh process. The browser survives between invocations
  because it runs with `--remote-debugging-port`.
- State file `%TEMP%\ps-edge\state.json`: `{ port, pid, userDataDir, targetId,
  attached, downloadDir }`.
  `targetId` = currently selected tab. Commands read it to find the browser.
- Element refs (`e1`, `e2`, ...) are assigned by `snapshot` or `inspect` and stored **inside the
  page** as `window.__pseRefs` (ref -> Element map). They stay valid until navigation.
  Action commands resolve refs there; a missing map/ref yields:
  `Error: ref 'e5' not found - run 'snapshot' first (refs are reset by navigation)`.

## CLI conventions

- Invocation: `.\ps-edge.ps1 <command> [args] [options]`.
- Options are hand-parsed from `$args` (case-insensitive, `-Name` and `--name` both OK).
- Output: UTF-8 text designed to be pasted into an LLM context. Success output is
  plain lines; errors go to stderr as `Error: <message>` with exit code 1; success
  exits 0.
- Every single command that talks to the page prints, at the end:
  `# url: <current url>` and `# title: <title>` (helps AI keep orientation).
- `batch` is the structured exception: it returns one compressed JSON object with ordered
  step results and final `url` / `title`, using one page session for all steps.

## Command set (v1)

| Command | Syntax | Implementation notes |
|---|---|---|
| start | `start [-Port 9222] [-Headless] [-NoQuietFlags] [-ExtraArg <arg>] [-Url <url>] [-UserDataDir <path>] [-DownloadDir <path>] [-OktaFastPassOrigin <https-origin>]` / `start -Attach [-Port 9222]` | Launch Edge with `--remote-debugging-port`, isolated profile, wait for `/json/version`, configure downloads, save state. Quiet flags are enabled by default; browser permission prompts are denied instead of displayed and crash-restore UI is hidden. `-NoQuietFlags` restores the minimal launch flags, and repeated `-ExtraArg <arg>` passes raw Chromium switches. `-OktaFastPassOrigin` pre-allows known Okta external protocols in the isolated profile and grants local/loopback network permissions through CDP for one exact HTTPS origin. `-Attach` writes state for an existing CDP endpoint and never launches or changes browser settings. |
| stop | `stop` | `Browser.close` via CDP, fallback kill PID, clear state. |
| status | `status` | Show port/pid/version/tabs, or "not running". |
| downloads | `downloads [-Dir <path>]` | List files in the configured download directory (or explicit `-Dir`), newest first, marking partial downloads, then merge tracked `click -WaitDownload` events so canceled, last-observed in-progress, and completed-but-missing downloads remain visible. |
| goto | `goto <url>` | `Page.navigate` + wait for load event. Bare domains get `https://`. |
| back / forward | `back` / `forward` | History navigation via `Page.getNavigationHistory` + `Page.navigateToHistoryEntry`. |
| reload | `reload` | `Page.reload` + wait for load. |
| snapshot | `snapshot [-Selector <css>] [-MaxChars 24000]` | Injected JS walks DOM, emits YAML-ish a11y tree with `[ref=eN]` on interactive elements, and stops traversal at the browser-side budget. PowerShell applies a final safety cap; `-MaxChars 0` disables the cap. |
| inspect | `inspect [-Selector <css>] [-MaxItems 200]` | Return a compressed JSON array of visible interactive controls with refs, accessible names, values, state, and select options. Traversal stops at MaxItems; `0` is unlimited. |
| screenshot | `screenshot [<path>] [-FullPage]` | `Page.captureScreenshot` (png). Default path `screenshot-<timestamp>.png` in CWD. Prints saved path. |
| pdf | `pdf [<path>]` | `Page.printToPDF` with backgrounds. Default path `page-<timestamp>.pdf` in CWD. Requires a headless session. |
| resize | `resize <width> <height>` | `Emulation.setDeviceMetricsOverride` on the current page target; positive integer dimensions only. |
| click | `click <ref> [-Right] [-Double] [-WaitDownload] [-AcceptDialog] [-DownloadTimeoutSec 300]` | Resolve ref, scrollIntoView, center coords, `Input.dispatchMouseEvent`. `-WaitDownload` opens a browser-level event watch before clicking and exits 0 only for a completed download. `-AcceptDialog` overrides both page hooks and CDP dialog handling for this invocation without persisting policy. |
| type | `type <ref> <text> [-Submit]` | Focus element, `Input.insertText`; `-Submit` sends Enter key events after. |
| fill | `fill <ref> <value>` | JS: set `.value`, dispatch `input`+`change`. For fast form filling. |
| press | `press <key>` | `Input.dispatchKeyEvent`. Keys: Enter, Tab, Escape, Backspace, Delete, ArrowUp/Down/Left/Right, Home, End, PageUp, PageDown, plus `Control+A` style combos. |
| hover | `hover <ref>` | `Input.dispatchMouseEvent` type=mouseMoved at element center. |
| select | `select <ref> <value> [<value>...]` | JS: set selected options by value or label, dispatch `change`. |
| upload | `upload <ref> <path> [<path>...]` | Resolve paths locally, verify ref is `input[type=file]`, then use CDP `DOM.setFileInputFiles`. |
| eval | `eval <javascript>` | `Runtime.evaluate` with `returnByValue:true, awaitPromise:true`; print JSON result. |
| batch | `batch -Json <json-array>` | Parse and validate a JSON step array, open one page session, execute `eval` / `snapshot` / `inspect` / `click` / `fill` / `type` / `press` / `select` / `wait` / `goto` / `reload` sequentially, fail fast with the step index, then return one compressed result object. |
| wait | `wait [-Time <sec>] [-Text <str>] [-Gone <str>] [-Selector <css>] [-SelectorGone <css>] [-TimeoutSec 30]` | Poll via `Runtime.evaluate` (document.body.innerText contains / not contains, `document.querySelector` exists / is gone). All supplied conditions must hold. |
| tabs | `tabs` / `tabs new [url]` / `tabs select <n>` / `tabs close [<n>]` | `/json/list`, `/json/new` (PUT), `/json/close/<id>`, `/json/activate/<id>`. `select` updates `targetId` in state. |
| console | `console` | Reads `window.__pseConsole` (hook injected at start/goto via `Page.addScriptToEvaluateOnNewDocument`). Best effort. |
| dialog | `dialog` / `dialog -Accept [-Text <reply>]` / `dialog -Dismiss` / `dialog -Rescue [-Accept [-Text <reply>] \| -Dismiss]` | The injected page hook handles same-origin frames, while both CDP receive loops auto-handle `Page.javascriptDialogOpening` from persisted policy and report native answers as `# dialog: ...` footer lines; `beforeunload` is always accepted. The page session also calls `Target.setAutoAttach` with flattened sessions, answers OOPIF dialogs on the same `sessionId` that emitted them, and repeats auto-attach in each attached iframe/page session so nested OOPIFs are covered recursively. Chromium's `Page.handleJavaScriptDialog` works only from the session that had Page enabled when the dialog opened, so in-command dialogs can be auto-answered but a dialog opened with no client attached cannot be cleared on reconnect. Use `dialog -Rescue` for that case; it invokes the visible Edge dialog through Windows UI Automation and therefore does not work with a headless browser. |
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
- The browser-side character counter stops traversal as soon as MaxChars is exceeded;
  the existing PowerShell limiter formats the stable truncation marker.

## Inspect and batch interface

- `inspect` is the preferred observation for forms and control-heavy legacy pages. It
  avoids serializing unrelated page text and includes current values and select options.
- `batch` reuses the same low-level action helpers as single commands. It never invokes
  command handlers recursively and obtains/closes one `Get-PseSession` per invocation.
- Steps are static JSON. A prior `inspect` / `snapshot` supplies refs; steps may also use
  `inspect` / `snapshot` after navigation before a later invocation.
- Batch errors are not partial success objects. stderr identifies the zero-based step and
  action, and execution stops before later steps.

## CDP client rules (PowerShell 5.1)

- All CDP discovery HTTP requests and WebSocket connections explicitly disable proxies.
  The endpoint is loopback-only; routing it through an enterprise proxy can return a
  block page instead of `/json/version` and makes a healthy Edge look unavailable.
- Sync-over-async: `.GetAwaiter().GetResult()` with `CancellationTokenSource` timeouts.
- Receive loop: 64KB buffer into MemoryStream until `EndOfMessage` (screenshot payloads
  are multi-MB), UTF-8 decode, `ConvertFrom-Json`.
- Request/response matched by `id`; messages without `id` are events, buffered in the
  connection object for `Wait-PseCdpEvent`.
- `ConvertTo-Json -Depth 12 -Compress` for outbound payloads.
- No PS7-only syntax: no `&&`/`||`, no ternary, no `??`, no `?.`.

## Download watch

- `click -WaitDownload` connects to the browser WebSocket before opening the page
  session, enables flattened `Target.setAutoAttach`, and subscribes to
  `Browser.downloadWillBegin` / `Browser.downloadProgress` before dispatching the
  click. Both the browser watch and page connection use the invocation's dialog
  policy, so popup and OOPIF dialogs can be answered while the watch is active.
- Immediately before the click, the watch re-asserts `Browser.setDownloadBehavior`
  with `eventsEnabled:true`. Configured sessions use `allow` plus the saved
  `downloadDir`; attached sessions use `default` and only report a path when CDP
  supplies one.
- The watch distinguishes `completed`, `canceled`, timeout while `in-progress`, and
  timeout with no `downloadWillBegin` (`not-observed`). Only `completed` exits 0,
  preventing callers from treating an ambiguous result as permission to retry a
  non-idempotent click.
- Each observed download is appended as BOM-free JSONL to
  `%TEMP%\ps-edge\downloads-events-<port>.jsonl`, capped at the newest 200 lines.
  Records contain guid, filename, URL, terminal/observed state, byte counts, CDP
  file path when available, and an ISO 8601 end timestamp.
- `downloads` reads that JSONL log using the current state's port, ignores malformed
  lines, and keeps the last record for each guid. Events whose filename or recorded
  path basename matches a current directory file are accounted for by the normal file
  listing. Remaining events are printed newest first: a completed event explicitly
  reports that its file is missing (moved or removed), rather than making the completed
  download invisible; canceled and last-observed in-progress events retain their
  respective states. With neither files nor tracked events, the command says the state
  is unknown and notes that downloads not triggered with `click -WaitDownload` are not
  recorded.

## Browser prompt policy

- Default quiet startup uses Chromium's `--deny-permission-prompts` and
  `--hide-crash-restore-bubble` in addition to the existing first-run, default-browser,
  sync/sign-in, extension, and infobar suppression. `-NoQuietFlags` disables these
  optional quiet switches.
- External application launch is never globally allowed. `-OktaFastPassOrigin` requires
  an exact HTTPS origin, merges only known Okta schemes into
  `Default\Preferences`, and preserves existing profile preferences.
- The same option grants `localNetwork`, `localNetworkAccess`, and `loopbackNetwork` for
  that origin with `Browser.grantPermissions` before navigating the requested initial URL.
  It does not modify HKCU/HKLM Edge policies or weaken Local Network Access for other
  origins.

## Testing

- Plain PS 5.1 test scripts in `tests/*.Tests.ps1`, throw on failure.
- Integration tests launch real Edge **headless** on a free port with a temp
  user-data-dir, navigate to `data:` URLs (no network needed), and always clean up
  (try/finally: kill process, remove profile dir).
