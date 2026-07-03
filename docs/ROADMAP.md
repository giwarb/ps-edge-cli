# ps-edge-cli — Roadmap (post v1 gap analysis)

Question examined: **is the v1 command set sufficient for an AI agent doing real
daily business tasks in a browser?** (intranet portals, SaaS back offices, form
entry, report downloads, light scraping/testing)

Verdict: v1 covers the observe/act loop well, but real daily work hits four hard
blockers (P0) and several quality-of-life gaps (P1). Known structural limitations
are listed as P2 with honest notes on difficulty.

## P0 — blockers for daily business use

| # | Feature | Why it blocks daily work | Implementation sketch |
|---|---|---|---|
| 1 | **Attach to a running Edge** (`start -Attach [-Port <n>]`) | Corporate SSO / logged-in sessions live in the user's real profile. v1 always launches a throwaway profile, so every session starts logged out. Attaching to an Edge the user started with `--remote-debugging-port` (real profile, human-visible) unlocks all authenticated workflows. | If a CDP endpoint already answers on the port, just write state (no launch). Document the manual launch line. |
| 2 | **File upload** (`upload <ref> <path> [<path>...]`) | Attaching a file to a form (expense receipts, CSV import) is everyday office work; currently impossible because file inputs cannot be set from JS. | `DOM.setFileInputFiles` on the ref's node (needs `DOM.getDocument` + backendNodeId via `DOM.describeNode` from the ref element). |
| 3 | **File download** (`start` sets a download dir; `downloads` lists results) | "Download the monthly report" is a top-frequency task. v1 has no defined download location and no way to know when a download finished. | `Browser.setDownloadBehavior {behavior:'allow', downloadPath}` at start (persists browser-side). `downloads` lists the dir with sizes + `.crdownload` detection for in-progress. |
| 4 | **JS dialog handling** (`dialog -Accept` / `-Dismiss` / `-Text <reply>`) | One unexpected `confirm()` freezes the page for every subsequent command (CDP evaluate hangs). Deletion confirmations are ubiquitous in business apps. | CLI is connectionless, so CDP dialog events can't be awaited; instead extend the injected hook (same mechanism as console capture) to override `alert`/`confirm`/`prompt` with a policy stored in the page + log of suppressed dialogs. Default: auto-dismiss + record. |

## P1 — high-value quality of life

| # | Feature | Why | Sketch |
|---|---|---|---|
| 5 | `wait -Selector <css>` / `-SelectorGone <css>` | SPAs render after load; waiting on text alone is brittle (spinners share text). | Extend existing polling loop with `document.querySelector` checks. |
| 6 | Snapshot size cap (`-MaxChars <n>`, sane default, `[snapshot truncated ...]` marker + guidance to use `-Selector`) | Real portals produce snapshots far larger than an LLM context slice; today the agent gets flooded. | Truncate in the injected JS (per-node budget) or post-truncate in PS with a clear tail marker. |
| 7 | `pdf <path>` | Archiving a page as PDF is a common deliverable; headless Chrome does this natively. | `Page.printToPDF` (headless only), base64 → file. |
| 8 | `resize <width> <height>` | Responsive layouts hide elements at odd default sizes; screenshots need fixed dimensions. | `Emulation.setDeviceMetricsOverride`. |

## P2 — known limitations (documented, not scheduled)

- **iframes**: snapshot does not descend into cross-process iframes. Needs
  `Target.getTargets` + per-frame sessions and ref namespacing (`f1:e3`). Legacy
  business apps use iframes heavily — largest remaining structural gap after P0/P1.
- **Shadow DOM**: closed shadow roots are invisible to the walker; open ones could be
  pierced with `el.shadowRoot` traversal.
- **drag & drop**: `Input.dispatchDragEvent` sequences; niche until a concrete need.
- **Network request listing**: proper `Network.*` capture needs a persistent listener;
  an approximation via `performance.getEntriesByType('resource')` is possible cheaply.
- **Cookie/session export-import** (`storage-state` style): `Network.getCookies` /
  `setCookies`; less urgent once `-Attach` (P0-1) exists.
- **Concurrent sessions**: the state file is global (`%TEMP%\ps-edge\state.json`);
  a `-Port`-keyed state layout would allow parallel browsers.
- **Old-headless quirk**: `--headless` on very old Edge versions behaves differently;
  v1 targets current Edge only.

## Maintenance rule

Every feature PR must update, in the same PR: `docs/DESIGN.md` (command table),
`README.md` (reference table), and `.claude/skills/ps-edge/SKILL.md` (cheat sheet /
error playbook). See CLAUDE.md.
