# ps-edge-cli

ps-edge-cli は、AI エージェントが Microsoft Edge を操作するための PowerShell 製 CLI です。Windows PowerShell 5.1 だけで動き、追加インストールは不要です。Edge の Chrome DevTools Protocol (CDP) に接続し、Playwright MCP 風の `snapshot` と ref ベース操作でページを扱います。

単一ファイル版は [skills/ps-edge/scripts/ps-edge.ps1](skills/ps-edge/scripts/ps-edge.ps1) です。`skills/ps-edge` フォルダをコピーすれば使えます。

## Quick Start

```powershell
PS> .\skills\ps-edge\scripts\ps-edge.ps1 start -Headless
Started Edge Edg/150.0.4078.48 (pid 7940) on port 9222
 [1] about:blank  about:blank

PS> .\skills\ps-edge\scripts\ps-edge.ps1 goto https://example.com
# url: https://example.com/
# title: Example Domain

PS> .\skills\ps-edge\scripts\ps-edge.ps1 snapshot
- document "Example Domain"
  - heading "Example Domain" [level=1]
  - text: This domain is for use in documentation examples without needing permission. Avoid use in operations.
  - link "Learn more" [ref=e1]
# url: https://example.com/
# title: Example Domain

PS> .\skills\ps-edge\scripts\ps-edge.ps1 click e1
Clicked e1
# url: https://www.iana.org/help/example-domains
# title: Example Domains

PS> .\skills\ps-edge\scripts\ps-edge.ps1 screenshot page.png
Saved screenshot: C:\work\page.png (741x441)
# url: https://www.iana.org/help/example-domains
# title: Example Domains

PS> .\skills\ps-edge\scripts\ps-edge.ps1 stop
Stopped.
```

開発中のエントリポイントは `.\ps-edge.ps1` です。配布やコピー用途では `.\skills\ps-edge\scripts\ps-edge.ps1` を使ってください。

## Command Reference

| Command | Syntax | Notes |
|---|---|---|
| `start` | `start [-Port 9222] [-Headless] [-NoQuietFlags] [-ExtraArg <arg>] [-Url <url>] [-UserDataDir <path>] [-DownloadDir <path>] [-OktaFastPassOrigin <https-origin>]` / `start -Attach [-Port 9222]` | Edge を remote debugging port 付きで起動し、状態を保存します。通常は welcome、crash restore、permission prompt を表示しません。`-OktaFastPassOrigin` は exact HTTPS origin に限り、isolated profile 内で Okta protocol と local/loopback network を許可します。registry は変更しません。`-Attach` は既存の CDP endpoint に接続します。 |
| `stop` | `stop` | CDP の `Browser.close` を試し、必要なら PID を停止し、状態を消します。 |
| `status` | `status` | port、pid、version、tabs を表示します。未起動なら `Not running.` を表示します。 |
| `downloads` | `downloads [-Dir <path>]` | 設定済み、または指定した download dir のファイルを新しい順に表示します。 |
| `goto` | `goto <url>` | ページへ移動して load を待ちます。裸のドメインは `https://` として扱います。 |
| `back` / `forward` | `back` / `forward` | ブラウザ履歴を戻る、進む。 |
| `reload` | `reload` | 現在ページを再読み込みして load を待ちます。 |
| `snapshot` | `snapshot [-Selector <css>] [-MaxChars 24000]` | DOM を走査し、AI が読みやすい YAML 風ツリーを出力します。操作可能要素には `[ref=eN]` が付きます。上限到達時はブラウザ内の走査も停止します。`-MaxChars 0` で無制限。 |
| `inspect` | `inspect [-Selector <css>] [-MaxItems 200]` | 表示中の操作可能要素だけを、ref・名前・現在値・select option を含む圧縮 JSON 配列で返します。フォーム操作では `snapshot` より優先します。 |
| `screenshot` | `screenshot [<path>] [-FullPage]` | PNG スクリーンショットを保存します。path 省略時は CWD に `screenshot-<timestamp>.png`。 |
| `pdf` | `pdf [<path>]` | 現在のページを PDF として保存します。path 省略時は CWD に `page-<timestamp>.pdf`。headless Edge が必要です。 |
| `resize` | `resize <width> <height>` | 現在のページの viewport を正の整数サイズに設定します。 |
| `click` | `click <ref> [-Right] [-Double]` | ref の要素を表示範囲へスクロールし、中央座標をクリックします。 |
| `type` | `type <ref> <text> [-Submit]` | 要素へフォーカスしてテキストを挿入します。`-Submit` は Enter も送ります。 |
| `fill` | `fill <ref> <value>` | JS で `.value` を設定し、`input` と `change` を発火します。 |
| `press` | `press <key>` | キーイベントを送ります。例: `Enter`, `Tab`, `Escape`, `Control+A`。 |
| `hover` | `hover <ref>` | ref 要素の中央へ mouseMoved を送ります。 |
| `select` | `select <ref> <value> [<value>...]` | select の option を value または label で選択し、`change` を発火します。 |
| `upload` | `upload <ref> <path> [<path>...]` | Set one or more real local files on an `input[type=file]` ref via CDP. |
| `eval` | `eval <javascript>` | `Runtime.evaluate` を `returnByValue:true, awaitPromise:true` で実行し、結果を JSON として表示します。 |
| `batch` | `batch -Json <json-array>` | `eval` / `snapshot` / `inspect` / `click` / `fill` / `type` / `press` / `select` / `wait` / `goto` / `reload` を1プロセス・1 CDP 接続で順次実行し、結果と最終 URL/title を1つの JSON で返します。 |
| `wait` | `wait [-Time <sec>] [-Text <str>] [-Gone <str>] [-Selector <css>] [-SelectorGone <css>] [-TimeoutSec 30]` | 時間待ち、body text の出現/消滅、または CSS selector の出現/消滅をポーリングします。指定した条件はすべて満たす必要があります。 |
| `tabs` | `tabs` / `tabs new [url]` / `tabs select <n>` / `tabs close [<n>]` | タブ一覧、新規作成、選択、終了。`select` は状態の `targetId` を更新します。 |
| `console` | `console` | ページ内で捕捉した console log を表示します。best effort です。 |
| `dialog` | `dialog` / `dialog -Accept [-Text <reply>]` / `dialog -Dismiss` | JS hook + CDP safety net による dialog 自動応答 policy を表示・設定します。native dialog も command を block せず、`# dialog: ...` footer で報告されます。`beforeunload` は navigation 続行のため常に accept されます。 |
| `cdp` | `cdp <method> [<params-json>]` | 生の CDP 呼び出しです。例: `cdp Page.navigate '{"url":"https://example.com"}'`。 |
| `help` | `help` | usage を表示します。不明な command でも stderr に usage を表示します。 |

## For AI Agents

Install by copying the `skills/ps-edge` folder into `~/.claude/skills/` (user-level) or `<project>/.claude/skills/` (project-level). One folder, done. After cloning this repository, run `.\build.ps1` once to enable the generated project skill under `.claude/skills/ps-edge`.

Claude Code などのエージェントには、スキル [skills/ps-edge/SKILL.md](skills/ps-edge/SKILL.md) を読み込ませてください(このリポジトリ内ではプロジェクトスキルとして自動で利用可能です)。スキルには操作ループ、コマンドチートシート、エラー対応表が含まれており、**このスクリプト+スキルだけ**でブラウザ操作を自走できます。他マシンへは `skills/ps-edge/` をコピーしてください。

推奨ループ:

1. フォームなら `inspect`、ページ全体の文脈が必要なら `snapshot` で ref を取得する。
2. 複数の既知操作は `batch -Json '[...]'` にまとめ、最後の step で検証する。
3. ナビゲーション、ref 失効、または大きな DOM 変更の後だけ再度 `inspect` / `snapshot` する。フィールドを1つ変えるたびに読み直さない。
4. 単発操作では `# url:` / `# title:`、batch では結果 JSON の `url` / `title` を確認する。

ref は `inspect` または `snapshot` 実行時にページ内へ保存されます。ページ遷移で ref はリセットされるため、古い `e1` や `e2` を使い回さないでください。ref が見つからないエラーが出たら、再度 `inspect` または `snapshot` を実行します。

PowerShell 上ではスクリプトを `& .\skills\ps-edge\scripts\ps-edge.ps1 inspect` のように直接呼び出してください。すでに PowerShell を実行しているのに、各操作でさらに `powershell.exe -File ...` を起動すると不要なプロセス起動時間が加わります。

起動時はまず `status` を1回実行し、`Not running.` の場合は通常の `start` を使います。`start -Attach` は、通常のEdgeが開いているという意味ではありません。`--remote-debugging-port` と専用 `--user-data-dir` を付けて手動起動したEdgeにだけ使用してください。CDPのHTTP/WebSocket通信は管理プロキシを経由せず、常に `127.0.0.1` へ直接接続します。

Okta FastPass を使う場合は、たとえば `start -OktaFastPassOrigin https://tenant.okta.com` としてから対象ページへ移動します。外部アプリの自動起動を全サイトへ許可するのは危険なため、この許可はデフォルトではなく指定した exact origin だけに適用されます。既知の Okta protocol (`com-okta-authenticator`, `okta-verify`, `com.okta.mobile`) は専用 profile の `Preferences` に保存され、Local Network Access はその browser process の CDP permission として付与されます。

## Development

主な構成:

```text
ps-edge.ps1          dev entry point
src/*.ps1           function-only source files, sorted by name
build.ps1           skills/ps-edge/scripts/ps-edge.ps1 generator and .claude/skills sync
skills/ps-edge/     distributable agent skill folder
skills/ps-edge/scripts/ps-edge.ps1  generated, committed single-file bundle
tests/*.Tests.ps1   plain PowerShell tests
tests/run-tests.ps1 test runner
docs/DESIGN.md      architecture and command syntax source of truth
docs/ROADMAP.md     prioritized feature gaps for future PRs
.claude/skills/ps-edge/           generated, untracked dogfood copy (run .\build.ps1 once after cloning)
CLAUDE.md           Claude/Codex collaboration workflow
```

**ドキュメント同期ルール**: CLI のコマンド追加・削除・出力形式変更を行う PR では、
`skills/ps-edge/SKILL.md`(スキル)、`README.md` のコマンドリファレンス、
`docs/DESIGN.md` を**同じ PR 内で必ず更新**してください。スキルが古いままだと、
それを読むすべてのエージェントを誤誘導します。

テスト:

```powershell
.\tests\run-tests.ps1
```

単一ファイル版の生成:

```powershell
.\build.ps1
```

The build writes `skills/ps-edge/scripts/ps-edge.ps1` and syncs `skills/ps-edge` to `.claude/skills/ps-edge` for dogfooding. Do not edit `.claude/skills/ps-edge/` by hand.

`build.ps1` は `src/*.ps1` を名前順に連結し、`ps-edge.ps1` の `#region PSE-SOURCES` 外にある dispatch 行を末尾へ追加します。生成物は UTF-8 with BOM です。`skills/ps-edge/scripts/ps-edge.ps1` は生成ファイルなので直接編集しないでください。
