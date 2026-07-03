# ps-edge-cli — 運用ルール

このリポジトリは「Claude Code が司令塔、Codex CLI が実装担当」という分業体制で運用する。

## 役割分担

### Claude Code(司令塔)
原則としてソースコードを直接編集しない。役割は以下のみ:

- 要件をタスクに分解する
- 受け入れ条件付きのタスク仕様書を作成する
- `codex exec` で Codex に実装を委譲する
- 成果物(`git diff`)をレビューする
- テストを実行する(`.\tests\run-tests.ps1`)
- 論理単位でコミットし、`gh` で PR を作成する

### Codex CLI(実装担当)
ソースコードの作成・編集はすべて Codex が行う。

## Codex への委譲方法

フラグは `codex exec --help` で確認済み(2026-07-03 時点)。実際に動作検証済みの呼び出し方:

```powershell
# 1. 仕様書を .codex-task.md に書き出す(gitignore 済み)
# 2. stdin 経由で渡して実行する
Get-Content .codex-task.md -Raw | & C:\Users\yoshi\.codex\packages\standalone\current\bin\codex.exe exec -s workspace-write -C C:\Users\yoshi\work\ps-edge-cli -o .codex-last-message.md -
```

- `codex exec` は非対話モード。承認プロンプトは出ない
- サンドボックスは `-s workspace-write`(リポジトリ内のみ書き込み可)。`danger-full-access` は使わない
- `-o <FILE>` で Codex の最終報告をファイルに保存し、レビューの参考にする
- 差し戻しは同じ形式で `resume` を使う(オプションは `exec` の直後、`resume` の前に置く):
  ```powershell
  Get-Content .codex-task.md -Raw | & C:\Users\yoshi\.codex\packages\standalone\current\bin\codex.exe exec -s workspace-write -C C:\Users\yoshi\work\ps-edge-cli -o .codex-last-message.md resume --last -
  ```

### この環境特有の注意点(2026-07-03 検証)

- **必ず standalone バイナリ `C:\Users\yoshi\.codex\packages\standalone\current\bin\codex.exe` を直接呼ぶこと。** PATH 上のランチャー(`...\Programs\OpenAI\Codex\bin\codex.exe`)経由だと、Windows サンドボックスの補助バイナリ(`codex-windows-sandbox-setup.exe` / `codex-command-runner.exe`)を実行ファイル隣の `codex-resources` から見つけられず、`program not found` や `CreateProcessWithLogonW failed: 2` で全コマンド・全ファイル書き込みが失敗する
- **仕様書はコマンドライン引数ではなく stdin で渡すこと。** 引数渡しだと仕様書内の二重引用符で引数解釈が壊れる。また PowerShell 5.1 のパイプは日本語が文字化けしてCodexに届くため、仕様書の見出し・ファイルパス・検証値など要点は ASCII でも判読できる形(コードブロックや英語併記)にしておくとより安全
- Codex のサンドボックスは別ユーザーで実行されるため、Codex からの `git` 操作は `dubious ownership` で失敗する。git 操作は Claude 側で行う(役割分担どおり)

## タスク仕様書のルール

- 実装タスクは **1つずつ** 渡す(1回の `codex exec` に複数タスクを混ぜない)
- 仕様書には必ず以下を含める:
  - **目的**: なぜこの変更が必要か
  - **変更対象**: 作成・編集するファイルのパス
  - **受け入れ条件**: 完了と判断できる検証可能な条件(テストが通る、コマンドが特定の出力を返す等)
  - **制約**: 触ってはいけないファイル、守るべき規約

## レビューループ(必須)

`codex exec` の実行後、毎回以下を行う:

1. `git diff` を必ずレビューする(仕様との一致、余計な変更の有無)
2. `.\tests\run-tests.ps1` でテストを実行する
3. 問題があれば、具体的な修正指示を添えて `codex exec resume --last` で差し戻す
4. 差し戻しは **最大3回** まで。それでも解決しない場合のみ Claude が自分で修正してよい

## ドキュメント同期ルール(必須)

エージェント向けスキル `.claude/skills/ps-edge/SKILL.md` は**製品の一部**である。
CLI のコマンド追加・削除・出力形式変更を行うタスクでは、同じタスク(同じ PR)内で必ず以下を更新する:

1. `.claude/skills/ps-edge/SKILL.md`(チートシート・エラー対応表・レシピ)
2. `README.md`(コマンドリファレンス表)
3. `docs/DESIGN.md`(コマンド体系の正)

Codex への仕様書にはこの3点の更新を受け入れ条件として含め、Claude はレビュー時に同期漏れを必ず確認する。将来の機能候補は `docs/ROADMAP.md` で管理する。

## コミット / PR

- コミットは論理単位で行う(1機能・1修正 = 1コミット)
- PR は `gh pr create` で作成する
- force push は禁止

## 技術スタック

- 言語: PowerShell(Windows PowerShell 5.1 互換を維持する)
- テスト: 追加依存なし。`tests\*.Tests.ps1` に素の PowerShell で記述し、`tests\run-tests.ps1` が一括実行する
  - 各テストファイルは失敗時に例外を投げる(throw)こと。ランナーが捕捉して集計する
