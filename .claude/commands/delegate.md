---
description: 実装タスクを仕様書化して Codex CLI に委譲し、レビュー・テストまで行う
---

以下のタスクを Codex CLI に委譲してください。あなた(Claude Code)はソースコードを直接編集せず、CLAUDE.md の運用ルールに従うこと。

## タスク

$ARGUMENTS

## 手順

1. **仕様書化**: 上記タスクを、以下を含む1件のタスク仕様書にまとめる
   - 目的
   - 変更対象ファイルのパス
   - 検証可能な受け入れ条件
   - 制約(PowerShell 5.1 互換、追加依存なし、テストは `tests\*.Tests.ps1` に置く 等)

2. **委譲**: 仕様書を渡して Codex を実行する
   ```powershell
   codex exec -s workspace-write -C C:\Users\yoshi\work\ps-edge-cli -o .codex-last-message.md "<仕様書>"
   ```

3. **レビュー**: `git diff` を確認し、`.codex-last-message.md` の報告と突き合わせる
   - 仕様との一致、余計な変更・不要ファイルの有無をチェック

4. **テスト**: `.\tests\run-tests.ps1` を実行する

5. **判定**:
   - 問題があれば、具体的な修正指示を添えて `codex exec resume --last "<修正指示>"` で差し戻す(最大3回。超えたら自分で修正してよい)
   - 問題がなければ、論理単位で `git commit` する(コミットメッセージにタスク概要を書く)

6. **報告**: 委譲内容、レビュー結果、テスト結果、コミットハッシュをユーザーに報告する
