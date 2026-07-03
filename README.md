# ps-edge-cli

ps-edge-cli は、AI エージェントが Microsoft Edge を操作するための PowerShell 製 CLI です。Windows PowerShell 5.1 だけで動き、追加インストールは不要です。Edge の Chrome DevTools Protocol (CDP) に接続し、Playwright MCP 風の `snapshot` と ref ベース操作でページを扱います。

単一ファイル版は [dist/ps-edge.ps1](dist/ps-edge.ps1) です。このファイルだけを制限された Windows 環境へコピーすれば使えます。

## Quick Start

```powershell
PS> .\dist\ps-edge.ps1 start -Headless
Started Edge Edg/150.0.4078.48 (pid 7940) on port 9222
 [1] about:blank  about:blank

PS> .\dist\ps-edge.ps1 goto https://example.com
# url: https://example.com/
# title: Example Domain

PS> .\dist\ps-edge.ps1 snapshot
- document "Example Domain"
  - heading "Example Domain" [level=1]
  - text: This domain is for use in documentation examples without needing permission. Avoid use in operations.
  - link "Learn more" [ref=e1]
# url: https://example.com/
# title: Example Domain

PS> .\dist\ps-edge.ps1 click e1
Clicked e1
# url: https://www.iana.org/help/example-domains
# title: Example Domains

PS> .\dist\ps-edge.ps1 screenshot page.png
Saved screenshot: C:\work\page.png (741x441)
# url: https://www.iana.org/help/example-domains
# title: Example Domains

PS> .\dist\ps-edge.ps1 stop
Stopped.
```

開発中のエントリポイントは `.\ps-edge.ps1` です。配布やコピー用途では `.\dist\ps-edge.ps1` を使ってください。

## Command Reference

| Command | Syntax | Notes |
|---|---|---|
| `start` | `start [-Port 9222] [-Headless] [-Url <url>] [-UserDataDir <path>]` | Edge を remote debugging port 付きで起動し、状態を保存します。 |
| `stop` | `stop` | CDP の `Browser.close` を試し、必要なら PID を停止し、状態を消します。 |
| `status` | `status` | port、pid、version、tabs を表示します。未起動なら `Not running.` を表示します。 |
| `goto` | `goto <url>` | ページへ移動して load を待ちます。裸のドメインは `https://` として扱います。 |
| `back` / `forward` | `back` / `forward` | ブラウザ履歴を戻る、進む。 |
| `reload` | `reload` | 現在ページを再読み込みして load を待ちます。 |
| `snapshot` | `snapshot [-Selector <css>]` | DOM を走査し、AI が読みやすい YAML 風ツリーを出力します。操作可能要素には `[ref=eN]` が付きます。 |
| `screenshot` | `screenshot [<path>] [-FullPage]` | PNG スクリーンショットを保存します。path 省略時は CWD に `screenshot-<timestamp>.png`。 |
| `click` | `click <ref> [-Right] [-Double]` | ref の要素を表示範囲へスクロールし、中央座標をクリックします。 |
| `type` | `type <ref> <text> [-Submit]` | 要素へフォーカスしてテキストを挿入します。`-Submit` は Enter も送ります。 |
| `fill` | `fill <ref> <value>` | JS で `.value` を設定し、`input` と `change` を発火します。 |
| `press` | `press <key>` | キーイベントを送ります。例: `Enter`, `Tab`, `Escape`, `Control+A`。 |
| `hover` | `hover <ref>` | ref 要素の中央へ mouseMoved を送ります。 |
| `select` | `select <ref> <value> [<value>...]` | select の option を value または label で選択し、`change` を発火します。 |
| `eval` | `eval <javascript>` | `Runtime.evaluate` を `returnByValue:true, awaitPromise:true` で実行し、結果を JSON として表示します。 |
| `wait` | `wait [-Time <sec>] [-Text <str>] [-Gone <str>] [-TimeoutSec 30]` | 時間待ち、または body text の出現、消滅をポーリングします。 |
| `tabs` | `tabs` / `tabs new [url]` / `tabs select <n>` / `tabs close [<n>]` | タブ一覧、新規作成、選択、終了。`select` は状態の `targetId` を更新します。 |
| `console` | `console` | ページ内で捕捉した console log を表示します。best effort です。 |
| `cdp` | `cdp <method> [<params-json>]` | 生の CDP 呼び出しです。例: `cdp Page.navigate '{"url":"https://example.com"}'`。 |
| `help` | `help` | usage を表示します。不明な command でも stderr に usage を表示します。 |

## For AI Agents

Claude Code などのエージェントには、スキル [.claude/skills/ps-edge/SKILL.md](.claude/skills/ps-edge/SKILL.md) を読み込ませてください(このリポジトリ内ではプロジェクトスキルとして自動で利用可能です)。スキルには操作ループ、コマンドチートシート、エラー対応表が含まれており、**このスクリプト+スキルだけ**でブラウザ操作を自走できます。他マシンへは `dist/ps-edge.ps1` と `.claude/skills/ps-edge/` をコピーしてください。

推奨ループ:

1. `snapshot` で現在のページ構造と ref を取得する。
2. `click eN`、`type eN "text"`、`fill eN "value"`、`select eN value` など、ref で操作する。
3. ナビゲーション、フォーム送信、画面更新の後は必ず `snapshot` を取り直す。
4. 判断に迷う場合は `# url:` と `# title:` を確認してから次の操作を決める。

ref は `snapshot` 実行時にページ内へ保存されます。ページ遷移で ref はリセットされるため、古い `e1` や `e2` を使い回さないでください。ref が見つからないエラーが出たら、まず `snapshot` を再実行します。

## Development

主な構成:

```text
ps-edge.ps1          dev entry point
src/*.ps1           function-only source files, sorted by name
build.ps1           dist/ps-edge.ps1 generator
dist/ps-edge.ps1    committed single-file bundle
tests/*.Tests.ps1   plain PowerShell tests
tests/run-tests.ps1 test runner
docs/DESIGN.md      architecture and command syntax source of truth
docs/ROADMAP.md     prioritized feature gaps for future PRs
.claude/skills/ps-edge/SKILL.md  agent-facing skill (part of the product)
CLAUDE.md           Claude/Codex collaboration workflow
```

**ドキュメント同期ルール**: CLI のコマンド追加・削除・出力形式変更を行う PR では、
`.claude/skills/ps-edge/SKILL.md`(スキル)、`README.md` のコマンドリファレンス、
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

`build.ps1` は `src/*.ps1` を名前順に連結し、`ps-edge.ps1` の `#region PSE-SOURCES` 外にある dispatch 行を末尾へ追加します。生成物は UTF-8 with BOM です。`dist/ps-edge.ps1` は生成ファイルなので直接編集しないでください。
