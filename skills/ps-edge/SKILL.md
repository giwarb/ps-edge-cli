---
name: ps-edge
description: Drive Microsoft Edge from pure PowerShell using ps-edge-cli (CDP-based, Playwright-MCP-style snapshot + ref interaction, no installs needed). Use whenever the task involves opening, reading, testing, scraping, filling, screenshotting, or otherwise automating a web page in a browser on this Windows machine.
---

# Driving Edge with ps-edge-cli

ps-edge-cli is a single-file PowerShell CLI that controls Microsoft Edge through the
Chrome DevTools Protocol. You observe pages with `snapshot` (a compact accessibility
tree with `[ref=eN]` handles) and act with ref-based commands (`click e3`,
`type e5 "text"`). No Node, no Python, no installs — Windows PowerShell 5.1 is enough.

## Locating the CLI

- The CLI lives at `scripts\ps-edge.ps1` relative to this `SKILL.md`.
- From PowerShell, invoke directly: `& <skill-dir>\scripts\ps-edge.ps1 <command> [args]`.
  Do not start a nested `powershell.exe` for every browser operation.
- From a non-PowerShell host, use the portable fallback:
  `powershell -NoProfile -ExecutionPolicy Bypass -File <skill-dir>\scripts\ps-edge.ps1 <command> [args]`.
- To install, copy the whole `skills/ps-edge` folder into `~/.claude/skills/`
  (user-level) or `<project>/.claude/skills/` (project-level).

## The golden loop

1. Run `status` once. If it says `Not running.`, run `start` once (add `-Headless`
   only when no human login or visual takeover is needed).
2. `goto <url>`
3. For forms, run `inspect`; use `snapshot` only when you need surrounding page text.
4. Put related known operations in one `batch -Json '[...]'`, with a final verification
   step. Use single `click` / `fill` / `select` commands only for isolated actions.
5. **After navigation, ref invalidation, or a big DOM change: observe again.**
   Do not take a snapshot after every field mutation.
   Refs are stored inside the page and are wiped by navigation — never reuse old refs
   across page loads.
6. Verify progress with the `# url:` / `# title:` footer lines every page command
   prints, or with `eval`, or visually with `screenshot`.
7. `stop` when the whole task is done (the browser survives between commands;
   you do NOT restart it per command).

## Command cheat sheet

| Goal | Command |
|---|---|
| Launch browser | `start [-Port 9222] [-Headless] [-NoQuietFlags] [-ExtraArg <arg>] [-Url <url>] [-UserDataDir <path>] [-DownloadDir <path>] [-OktaFastPassOrigin <https-origin>]` / `start -Attach [-Port 9222]` |
| Shut down | `stop` — Check liveness: `status` |
| Downloads | `downloads [-Dir <path>]` |
| Navigate | `goto <url>` / `back` / `forward` / `reload` |
| Read page context | `snapshot [-Selector <css>] [-MaxChars 24000]` |
| Inspect form controls (preferred for forms) | `inspect [-Selector <css>] [-MaxItems 200]` |
| Pixels | `screenshot [<path>] [-FullPage]` |
| PDF | `pdf [<path>]` |
| Resize viewport | `resize <width> <height>` |
| Click | `click <ref> [-Right] [-Double]` |
| Type into field | `type <ref> <text> [-Submit]` (`-Submit` presses Enter after) |
| Set value directly | `fill <ref> <value>` (fires input+change; fastest for forms) |
| Keyboard | `press Enter` / `press Tab` / `press Control+A` / `press Delete` ... |
| Hover | `hover <ref>` |
| Dropdown | `select <ref> <value> [<value>...]` (matches option value or label) |
| Upload files | `upload <ref> <path> [<path>...]` |
| Run JavaScript | `eval <expression>` (returnByValue, promises awaited) |
| Run related operations once | `batch -Json <json-array>` |
| Wait | `wait -Text <str>` / `wait -Gone <str>` / `wait -Selector <css>` / `wait -SelectorGone <css>` / `wait -Time <sec>` (`-TimeoutSec 30`) |
| Tabs | `tabs` / `tabs new [url]` / `tabs select <n>` / `tabs close [<n>]` |
| Console logs | `console` (captured best-effort after the session hook is installed) |
| JS dialogs | `dialog` / `dialog -Accept [-Text <reply>]` / `dialog -Dismiss` / `dialog -Rescue [-Accept [-Text <reply>] \| -Dismiss]` |
| Raw CDP escape hatch | `cdp <method> [<params-json>]` e.g. `cdp Page.navigate '{"url":"https://example.com"}'` |
| Usage | `help` |

## Reading snapshots

```
- document "Login - Acme"
  - heading "Sign in" [level=1]
  - textbox "Email" [ref=e1]
  - textbox "Password" [ref=e2]
  - checkbox "Remember me" [ref=e3] [checked]
  - button "Sign in" [ref=e4] [disabled]
  - link "Forgot password?" [ref=e5]
  - text: Some visible paragraph text
```

- Only interactive elements get refs. `[checked]` / `[disabled]` / `[selected]` /
  `[level=N]` annotations reflect live state.
- Hidden elements are omitted. If something you expect is missing, it may be
  collapsed behind a menu/accordion — click the toggle first, then re-snapshot.
- Huge page? Scope with `snapshot -Selector "main"` (any CSS selector).
- If the output ends with `[snapshot truncated at <n> chars - narrow with -Selector <css> or raise -MaxChars]`, the right response is usually to re-run `snapshot -Selector "<narrow container>"`, not to raise the limit blindly.

## Efficient form workflow

`inspect` returns one compressed JSON array containing refs, accessible names, DOM IDs,
current values, checked/disabled state, and select options. Use it instead of a broad
snapshot when locating form controls.

After refs are known, batch related work:

```powershell
$steps = '[{"action":"fill","ref":"e2","value":"hello"},{"action":"select","ref":"e3","values":["v2"]},{"action":"eval","expression":"({value:document.querySelector(\"#subject\").value})"}]'
& $cli batch -Json $steps
```

The result contains `ok`, ordered `steps`, and one final `url` / `title`. Batch fails
fast; `Error: batch step 1 (select): ...` means later steps were not run.

## Error recovery playbook

| Symptom | Fix |
|---|---|
| `Error: ref 'eN' not found - run 'snapshot' first` | Page navigated since your last observation. Run `inspect` for controls or `snapshot` for page context, then use fresh refs. |
| `Error: batch step N (action): ...` | The batch stopped at that zero-based step. Inspect/snapshot again if navigation invalidated refs, then submit a corrected remaining batch. |
| `Error: invalid selector ...` from `inspect` | Fix or narrow the CSS selector. A no-match selector is also an explicit error. |
| `Error: browser is not running - run 'start' first` | Run `start -Headless` (state lives in `%TEMP%\ps-edge\state.json`). |
| `# dialog: [type] ... -> dismissed` in output | A native dialog was auto-answered. If the page needed acceptance, run `dialog -Accept` and retry the action. |
| `Page.enable` timed out with `try 'dialog -Rescue'` | A native dialog opened while no CLI client was attached. With a visible browser, run `dialog -Rescue`; headless Edge auto-dismisses unattended dialogs. |
| `port 9222 is already in use` | Another session owns it: `stop` first, or use `start -Port <other>`. |
| `no CDP endpoint ... launch Edge first` from `start -Attach` | A normal running Edge is not attachable. Use plain `start`, or manually launch a separate Edge with both `--remote-debugging-port=9222` and a dedicated `--user-data-dir`, then attach. |
| `Edge did not start a CDP endpoint...` | Do not retry with certificate flags or random ports: page TLS does not control the local CDP endpoint. Read the appended endpoint/process error and fix that cause. |
| Okta FastPass shows an external-app or Local Network Access prompt | Restart the isolated browser with `start -OktaFastPassOrigin https://<tenant>.okta.com`, using the exact HTTPS origin shown in the login URL. Do not use a wildcard or disable Local Network Access globally. |
| `# warning: load event not fired within 30s` | Page is slow/SPA; it may still be usable — `snapshot` and check, or `wait -Text <expected>`. |
| `[snapshot truncated at <n> chars - narrow with -Selector <css> or raise -MaxChars]` | Re-run `snapshot -Selector "<specific container>"`; only raise `-MaxChars` when broad page context is truly needed. |
| Click had no visible effect | `snapshot` again (DOM may have changed), check `console` for JS errors, or try `eval` on the element directly. |
| Element exists but not in snapshot | It may be in an iframe (not yet supported) — fall back to `eval`/`cdp`, or note the limitation. |
| Exit code 1 | Read stderr (`Error: ...` line); every failure states its cause. |

## Practical tips

- Quote arguments containing spaces: `type e2 "hello world"`. JSON params for `cdp`
  go in single quotes so the double quotes survive.
- `fill` is faster and more reliable than `type` for plain form fields; use `type`
  when the page listens to real key events (autocomplete, rich editors).
- Prefer one `batch` for several fills/selects and one final `eval` verification. This
  avoids a new PowerShell process, HTTP discovery, and CDP WebSocket for every field.
- For login flows: `goto` → snapshot → fill credentials → `click` submit →
  `wait -Text <something only visible when logged in>` → snapshot.
- `eval` returns JSON — use it to extract data in bulk instead of parsing snapshots
  (e.g. `eval "JSON.stringify([...document.querySelectorAll('h2')].map(e=>e.innerText))"`).
- Everything is stateless between CLI calls except the browser itself and
  `%TEMP%\ps-edge\state.json` (port/pid/current tab). Parallel sessions on different
  ports share that single state file — avoid concurrent sessions.
- `start` without `-Headless` opens a visible window — useful when a human wants to
  watch or take over.
- Quiet launch flags are on by default: welcome/default-browser/crash-restore UI is
  suppressed, browser permission requests are denied instead of displayed, sync/sign-in
  prompts and extension dialogs are disabled. Use `-NoQuietFlags` when you need
  extensions or Edge's stock behavior; use repeated `-ExtraArg <arg>` to pass raw
  Chromium switches.
- For Okta FastPass, start with the exact tenant origin, for example
  `start -OktaFastPassOrigin https://tenant.okta.com`. This allows known Okta external
  protocols in the isolated profile and grants local/loopback network access only to
  that origin. It never writes global Edge policies; never replace the origin with a
  wildcard.
- To use a logged-in real profile, manually launch Edge first with
  `msedge.exe --remote-debugging-port=9222 --user-data-dir=C:\path\to\debug-profile`,
  then run `start -Attach`; `stop` only detaches and leaves that browser running.
  Do not try `start -Attach` merely because ordinary Edge windows are already open.
- For report downloads, use `start -DownloadDir <path>` or the default state download
  directory, then run `downloads` to list completed and in-progress files.
- Uploads need a real file path on disk: run `upload e3 C:\path\file.pdf` only after
  `snapshot` shows the file input ref.
- Dialogs opened during a command are handled by the injected JS hook or CDP safety
  net; `beforeunload` is always accepted, and auto-handled native dialogs appear as
  `# dialog: ...` footer lines. If a command fails with the `Page.enable` timeout
  hint, run `dialog -Rescue` against the visible browser. Rescue is a headful-only
  concern because headless Edge auto-dismisses unattended dialogs. The persisted
  policy remains configurable with `dialog -Accept` / `dialog -Dismiss`.

## Maintenance rule (for developers of ps-edge-cli)

This skill is part of the product. **Any PR that adds, removes, or changes a CLI
command or its output format MUST update `skills/ps-edge/SKILL.md` in the same PR**
(cheat sheet, error table, and recipes), plus README.md and docs/DESIGN.md.
`.claude/skills/ps-edge/` is a generated copy for dogfooding in this repository:
edit the file under `skills/`, then run `build.ps1`. An outdated skill actively
misleads every agent that uses the tool.
