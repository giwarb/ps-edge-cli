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

フラグは `codex exec --help` で確認済み(2026-07-03 時点)。

```powershell
codex exec -s workspace-write -C C:\Users\yoshi\work\ps-edge-cli -o .codex-last-message.md "<タスク仕様書>"
```

- `codex exec` は非対話モード。承認プロンプトは出ない
- サンドボックスは `-s workspace-write`(リポジトリ内のみ書き込み可)。`danger-full-access` は使わない
- `-o <FILE>` で Codex の最終報告をファイルに保存し、レビューの参考にする
- 直前のセッションへの差し戻しは `codex exec resume --last "<修正指示>"`

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

## コミット / PR

- コミットは論理単位で行う(1機能・1修正 = 1コミット)
- PR は `gh pr create` で作成する
- force push は禁止

## 技術スタック

- 言語: PowerShell(Windows PowerShell 5.1 互換を維持する)
- テスト: 追加依存なし。`tests\*.Tests.ps1` に素の PowerShell で記述し、`tests\run-tests.ps1` が一括実行する
  - 各テストファイルは失敗時に例外を投げる(throw)こと。ランナーが捕捉して集計する
