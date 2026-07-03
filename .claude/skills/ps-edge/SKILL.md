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

- In this repository: `.\ps-edge.ps1` (dev entry) or `.\dist\ps-edge.ps1` (bundle).
- On other machines: copy the single file `dist\ps-edge.ps1` anywhere and run it.
- Invoke as: `powershell -NoProfile -ExecutionPolicy Bypass -File <path>\ps-edge.ps1 <command> [args]`
  (or directly `.\ps-edge.ps1 <command>` when the execution policy allows).

## The golden loop

1. `start -Headless` once per session (add `-Port <n>` if 9222 is taken).
2. `goto <url>`
3. `snapshot` — read the tree, find your target's `[ref=eN]`.
4. Act by ref: `click eN` / `type eN "text" -Submit` / `fill eN "value"` / `select eN value`.
5. **After any navigation, form submit, or big DOM change: `snapshot` again.**
   Refs are stored inside the page and are wiped by navigation — never reuse old refs
   across page loads.
6. Verify progress with the `# url:` / `# title:` footer lines every page command
   prints, or with `eval`, or visually with `screenshot`.
7. `stop` when the whole task is done (the browser survives between commands;
   you do NOT restart it per command).

## Command cheat sheet

| Goal | Command |
|---|---|
| Launch browser | `start [-Port 9222] [-Headless] [-Url <url>] [-UserDataDir <path>] [-DownloadDir <path>]` / `start -Attach [-Port 9222]` |
| Shut down | `stop` — Check liveness: `status` |
| Downloads | `downloads [-Dir <path>]` |
| Navigate | `goto <url>` / `back` / `forward` / `reload` |
| Read page (primary tool) | `snapshot [-Selector <css>]` |
| Pixels | `screenshot [<path>] [-FullPage]` |
| Click | `click <ref> [-Right] [-Double]` |
| Type into field | `type <ref> <text> [-Submit]` (`-Submit` presses Enter after) |
| Set value directly | `fill <ref> <value>` (fires input+change; fastest for forms) |
| Keyboard | `press Enter` / `press Tab` / `press Control+A` / `press Delete` ... |
| Hover | `hover <ref>` |
| Dropdown | `select <ref> <value> [<value>...]` (matches option value or label) |
| Run JavaScript | `eval <expression>` (returnByValue, promises awaited) |
| Wait | `wait -Text <str>` / `wait -Gone <str>` / `wait -Time <sec>` (`-TimeoutSec 30`) |
| Tabs | `tabs` / `tabs new [url]` / `tabs select <n>` / `tabs close [<n>]` |
| Console logs | `console` (captured best-effort after the session hook is installed) |
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

## Error recovery playbook

| Symptom | Fix |
|---|---|
| `Error: ref 'eN' not found - run 'snapshot' first` | Page navigated since your last snapshot. Run `snapshot`, get fresh refs. |
| `Error: browser is not running - run 'start' first` | Run `start -Headless` (state lives in `%TEMP%\ps-edge\state.json`). |
| `port 9222 is already in use` | Another session owns it: `stop` first, or use `start -Port <other>`. |
| `# warning: load event not fired within 30s` | Page is slow/SPA; it may still be usable — `snapshot` and check, or `wait -Text <expected>`. |
| Click had no visible effect | `snapshot` again (DOM may have changed), check `console` for JS errors, or try `eval` on the element directly. |
| Element exists but not in snapshot | It may be in an iframe (not yet supported) — fall back to `eval`/`cdp`, or note the limitation. |
| Exit code 1 | Read stderr (`Error: ...` line); every failure states its cause. |

## Practical tips

- Quote arguments containing spaces: `type e2 "hello world"`. JSON params for `cdp`
  go in single quotes so the double quotes survive.
- `fill` is faster and more reliable than `type` for plain form fields; use `type`
  when the page listens to real key events (autocomplete, rich editors).
- For login flows: `goto` → snapshot → fill credentials → `click` submit →
  `wait -Text <something only visible when logged in>` → snapshot.
- `eval` returns JSON — use it to extract data in bulk instead of parsing snapshots
  (e.g. `eval "JSON.stringify([...document.querySelectorAll('h2')].map(e=>e.innerText))"`).
- Everything is stateless between CLI calls except the browser itself and
  `%TEMP%\ps-edge\state.json` (port/pid/current tab). Parallel sessions on different
  ports share that single state file — avoid concurrent sessions.
- `start` without `-Headless` opens a visible window — useful when a human wants to
  watch or take over.
- To use a logged-in real profile, manually launch Edge first with
  `msedge.exe --remote-debugging-port=9222`, then run `start -Attach`; `stop` only
  detaches and leaves that browser running.
- For report downloads, use `start -DownloadDir <path>` or the default state download
  directory, then run `downloads` to list completed and in-progress files.

## Maintenance rule (for developers of ps-edge-cli)

This skill is part of the product. **Any PR that adds, removes, or changes a CLI
command or its output format MUST update this SKILL.md in the same PR** (cheat sheet,
error table, and recipes), plus README.md and docs/DESIGN.md. An outdated skill
actively misleads every agent that uses the tool.
