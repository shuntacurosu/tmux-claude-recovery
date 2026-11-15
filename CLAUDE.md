# CLAUDE.md

このリポジトリで開発するときのメモ。利用者向けの説明（入れ方・動かし方・困ったとき）は README.md に書き、
**README には開発の話（テストの流し方、実装の工夫、コードの構造）を書かない**。逆に、運用の手順をこちらに重複させない。

## これは何か

コンテナが落ちて `docker start` し直したとき、tmux の構成・画面の文字・各ペインの Claude Code の会話を戻す仕組み。
`session/` は「見本と検証用のイメージ」で、利用者は中身を自分のサンドボックスのイメージに組み込む。

## ファイルと役割

| パス | 役割 |
|---|---|
| `session/bin/tmux-state` | すべての保存の入口。構成（resurrect 形式）と画面の文字（差分）を書く。`save` / `final-save` / `prepare-restore` / `blocked` |
| `session/bin/claude-pane` | Claude の対応表と再開。`hook`(SessionStart) / `end`(SessionEnd) / `save` / `pre-restore` / `restore` / `restoring` / `check` |
| `session/entrypoint.sh` | 起動時の復元、毎秒の保存ループ、SIGTERM での停止直前の保存。オンボーディング省略と `main` 作成は見本の都合 |
| `session/tmux.conf` | `/etc/tmux.conf`。resurrect の読み込み、resurrect のフック、構成の変化で即保存する tmux フック、警告のステータス行 |
| `session/managed-settings.d/50-claude-pane.json` | Claude Code のフック登録（`/etc/claude-code/managed-settings.d/`） |
| `session/Dockerfile` | tmux 3.8 をソースからビルド（sha256 検証）、claude・resurrect を版固定 |
| `test.sh` | Docker 上の結合テスト（t1〜t25） |
| `docs/production-checklist.md` | 本番に入れる前に確かめる項目（利用者向け。README から参照） |

## 処理の流れ

**保存**（すべて `tmux-state save` を通る。`flock` で排他し、走行中に来た依頼は `save.pending` で 1 回にまとめる）
- entrypoint の毎秒ループ。保存にかかった時間 × `SAVE_BACKOFF` まで間を空ける（上限 `SAVE_MAX_GAP` 秒）。取り込み直しの時間は `save.ms` から除く
- `tmux.conf` の `set-hook`（pane-created / pane-exited / pane-moved / after-kill-pane / window-linked / window-unlinked / session-*）
- prefix + C-s
- 構成を書いたら `claude-pane save` で位置基準の対応表 `map` も書き直す
- 10 秒ごとに `claude-pane save`（死んだ claude を外す）と `claude-pane check`（フック未動作の見張り）

**停止**: SIGTERM → `tmux-state final-save`（`@tmux_state_stopping` を立てて以後の保存を止め、1 回だけ全部保存）→ `tmux kill-server`

**復元**: `tmux-state prepare-restore`（`last` の修復、索引どおりに `pane_contents.tar.gz` を組み立て）→ resurrect の `restore.sh` →
`@resurrect-hook-pre-restore-all`（`claude-pane pre-restore` が `@claude_pane_restoring` を立てる）→
`@resurrect-hook-post-restore-all`（`claude-pane restore` が `map` の各ペインに `cd … && <env> claude <残す引数> --resume <id>` を send-keys、旗を下ろし `@restore-finished` を立てる）
→ 起動した claude の SessionStart で `@claude_pending` が本記録に置き換わる

restore.sh は必ず `tmux run-shell` 経由で呼ぶ。restore.sh は `$TMUX` を前提にしている（`new_session` が `TMUX="" tmux -S "$(tmux_socket)" new-session …` で、`tmux_socket` は `$TMUX` から取る）ので、シェルから直接呼ぶ形に書き換えると壊れる。
tmux-continuum の自動復元は使わない（起動直後に他の tmux クライアントがいると黙って復元をやめる）。entrypoint が自分で呼ぶ。

## 状態の置き場所

- `~/.local/share/tmux/resurrect/`: `tmux_resurrect_<時刻>.txt`（構成、最後の行が `state` なら書き終わり）、`last`（シンボリックリンク）、`pane_contents.tar.gz`（復元直前に作る）
- `~/.local/state/claude-pane/`（`CLAUDE_PANE_STATE` で変更可）: `map`（US 区切り: 位置・sid・cwd・引数・環境変数）、`log`、`pane_contents/`（`hist-<位置>.<時刻>`・`screen-<位置>.<時刻>`）、`pane_contents.idx`（確定の印）、`layout.key`・`layout.time`、`save.lock`・`save.pending`・`save.ms`、`capture.trace`（`TMUX_STATE_DEBUG=1` のとき）
- tmux のペインオプション: `@claude_pid` `@claude_start` `@claude_sid` `@claude_cwd` `@claude_args` `@claude_env`（後ろ 3 つは base64）`@claude_pending` `@claude_seen` `@claude_seen_pid` `@claude_warned`
- tmux のグローバルオプション: `@claude_pane_restoring`（時刻、10 分で期限切れ）`@tmux_state_stopping` `@restore-finished` `@claude_pane_warn`

## 崩してはいけない前提

- **書き込みは原子的に**: 一時ファイル → `sync` → `mv`。`last` は `ln -sfn` + `mv -Tf`。画面の文字は索引 `pane_contents.idx` の差し替え（rename 1 回）が確定で、履歴は有効バイト数までしか使わない。途中で落ちても前の確定が残ること
- **復元中・停止中は保存しない**（`blocked` / `cmd_restoring`）。保存の新しい入口を足すときも `tmux-state save` を通す
- **最初のプロンプトを再送しない**: `filter_args` は位置引数を必ず捨て、知らないオプションは直後の位置引数ごと捨てる。claude の版を上げたら `claude --help` と `arg_kind` を突き合わせる
- **秘密を残さない**: 環境変数は `KEEP_ENV` に一致し `DROP_ENV` に一致しないものだけ（`map` とペインオプションに平文で残るため）
- **フックは claude を止めない**: `claude-pane hook|end` は常に exit 0
- **記録はペインオプションに置く**（tmux サーバーと一緒に消えるので古い記録が新しいペインに当たらない）。ペイン id はサーバー起動時刻（`#{start_time}`）と組にして使う
- **毎秒の経路で fork しない**: 時刻は `printf -v … '%(%s)T'`、ファイル読みは `readf`、エスケープは `esc`（結果を `E` に）。変化が無いときの外部呼び出しは tmux への問い合わせ 3 回だけ
- **tmux 3.8 以上が前提**。3.8 未満の分岐は消してあり、entrypoint が起動を止める。戻さない
- 画面の取り込みで `-J` を使わない（行数で差分を取るので継ぎ目がずれる）。`if-shell -F` を使わない（実行順が保証されず履歴が画面側に出た）。増えた分の範囲は `-S -0 -E -1` にならないよう「増分 + 1 行取って先頭を落とす」
- 使わないもの: tmux-continuum（自動復元が他クライアントがいると黙ってやめる）、resurrect の `save.sh`（グループ化したセッションがあるときの代替だけ）、`@resurrect-processes` への claude 追加、`pipe-pane`、TPM
- 付けない tmux フック: `window-renamed`・`window-layout-changed`（頻発）、`pane-activity`（間引かれない）、`set-hook -B`
- 自分で閉じたもの（`/exit` = `prompt_input_exit`、閉じたペイン）は戻さない。それ以外の SessionEnd（clear・resume・other）では記録を消さない

設計を変えたら、決定事項と理由をこの節に書く（なぜそうしたかは、ここと各スクリプトのコメントにしか残らない）。

## 書き方

- bash。`bin/` は `set -u`（`set -e` は使わない）、`entrypoint.sh` は `set -e`。`$(…)` を毎秒の経路に増やさない
- コメントは日本語の平易な文で「なぜそうするか」を書く（既存の調子に合わせる）。ユーザー向けメッセージ（`display-message`）も日本語、ログは英語
- 改行は LF（`.gitattributes` で `*.sh`・`*.conf`・`session/bin/**` を固定）。拡張子の無いスクリプトを `session/bin/` 以外に置くなら `.gitattributes` に足す
- 実行ビットは git で持つ（Windows では `git update-index --chmod=+x <file>`）。`session/bin/` に足したら Dockerfile の `chmod` にも足す
- このマシン（Windows）には `shellcheck` が無い。構文だけなら `bash -n <file>`。スクリプトは Linux コンテナの中で動くので、確かめるのは `test.sh` で

## テスト

```bash
cp .env.example .env    # CLAUDE_CODE_OAUTH_TOKEN を書く（環境変数でもよい）
./test.sh 2>&1 | tee test.log          # 全部。イメージのビルドからコンテナ削除まで、約 45 分
./test.sh t1 t13                       # 一部だけ（t3 以降は t1 の状態を前提にするので t1 を先に）
KEEP=1 ./test.sh t1                    # コンテナを残す → docker exec -it claude-pane-test bash
REUSE=1 KEEP=1 ./test.sh t13           # 残したコンテナで流し直す
```

- 実際にモデル（既定 haiku、`TEST_MODEL=` で変更）を 1 往復ずつ呼ぶので、課金とトークンが要る。全部流すのは長いので、変更に関係する tN から絞って流す
- 環境変数: `C=`（コンテナ名）、`IMAGE=`、`STRESS_ITER=`（t24 の回数）、`TMUX_STATE_DEBUG=1`（取り込みの記録）
- 主シナリオは `docker kill` → 同じコンテナを `docker start` → `@restore-finished` を待って確認。ボリュームは付けない（本番と同じ）
- テストを足すときは `tN() { # 何を確かめるか` を書き、末尾の `ALL=(…)` に入れる。確認は `check "説明" コマンド…`
- Windows の Git Bash と Linux の両方で動かす（`MSYS_NO_PATHCONV=1`、`pwd -W`）。ホスト側の前提は docker・bash・GNU coreutils・tar だけにする
- 各テストの意図は `tN()` の行のコメント、期待値は `check` の説明

## 版の固定（`session/Dockerfile`）

- `TMUX_VERSION` / `TMUX_SHA256`、`CLAUDE_VERSION`、`RESURRECT_REV`。上げたら全テスト
- tmux を上げたら `tmux show-hooks -g` でフックが登録されることも確かめる
