# 本番コンテナで確認が必要な項目（チェックリスト）

検証環境（Windows の Docker Desktop と `session/` のイメージ）では確かめられない、または本番のイメージ・ホスト・アカウントによって変わる項目です。本番のイメージに組み込む前と、tmux・Claude Code の版を上げたときに確かめてください。

## Claude Code のフック

- [ ] **管理者用設定が効いているか**: 本番のコンテナの claude で `/status` を開き、`Setting sources` に `Enterprise managed settings` が出ること（`managed-settings.json` も置いている環境では `(file + drop-ins)` と出ることを確認済み）。組織が claude.ai の管理画面からサーバー管理設定を配っていると、既定ではそちらだけが使われ、`/etc/claude-code/managed-settings.d/` のフックは警告なしに無視される。本番の `managed-settings.json` に `disableAllHooks: true` が無いこと、配布で `/etc/claude-code/managed-settings.d/` が消えないこと。あわせて `~/.local/state/claude-pane/log` に `hook:` が出ること、ステータス行に `claude 未記録` が出ないこと。
- [ ] **`/etc/claude-code` を利用者が書き換えられないか**: コンテナ内で利用者が root になれないこと（sudo の有無、`USER`）。root になれるなら、フックを消せる前提で運用する。

## 停止と再起動

- [ ] **PID 1 が SIGTERM を entrypoint に届けるか**: 本番の entrypoint が `tini`・`dumb-init`・シェルのラッパーなどで起動されていると、SIGTERM が entrypoint のトラップに届かないことがある。`docker stop` 後に、ログに `state: saved ... (final)` が 1 回だけ出ること。
- [ ] **停止の猶予**: 本番の `docker stop -t`（または compose の `stop_grace_period`、オーケストレーターの停止猶予）が、停止直前の保存にかかる時間より長いこと。ペイン数 × 履歴に比例する（100 ペイン × 5,000 行で約 5 秒）。検証では 30 秒にしている。
- [ ] **ホストがハングから戻ったとき、コンテナが起動し直されるか**: `restart` ポリシー（`unless-stopped` など）と、Docker デーモンの起動順。手で `docker start` する運用なら、その手順。
- [ ] **ホストごと落ちたときのファイルの残り方**: 本番ホストのファイルシステム（overlay2 + ext4 など）で、ハング → 再起動の後に `last` と対応表が壊れていないか、壊れていたら起動時に向け直されるか（ログの `last pointed to a broken save`）。検証では `docker kill` までしか再現できず、ページキャッシュが消える落ち方は試していない。
- [ ] **コンテナを削除しない運用か**: ボリュームを使わないので、コンテナを消す（`docker rm`、イメージの更新での作り直し）と、会話・対応表・tmux の保存がすべて消える。イメージを更新するときの扱いを決める。

## イメージの中身

- [ ] **tmux が 3.8 以上か**: Ubuntu 24.04 の標準パッケージの tmux は 3.4。ホストではなく、本番の**コンテナのイメージ**に入る tmux を確かめる（`docker run --rm <本番イメージ> tmux -V`）。3.8 未満だと entrypoint が起動を止める。
- [ ] **tmux と claude の版を上げたとき**: tmux を 3.9 以降に上げたら、`tmux.conf` のフックが登録されること（`tmux show-hooks -g`）を確かめる。claude の版を上げたら、ログに `unknown option dropped` が出ていないか見る（出ていれば、そのオプションは再開時に外れている）。
- [ ] **必要なコマンドがあるか**: `tmux`、`flock`（util-linux）、`ps`・`pgrep`（procps）、`sync`・`base64`・`stat`・`truncate`（coreutils）、`find`（findutils）、`sed`、`grep`、`awk`、`tar`、`gzip`、`git`（resurrect の取得）。
- [ ] **ユーザー名・パス**: 本番のユーザー（見本では `dev`）と `$HOME`、`/workspace` 以外の作業場所でも動くか（スクリプトは `$HOME` 基準で、固定パスは `/opt/tmux-plugins` と `/usr/local/bin`）。

## 本番の環境に合わせること

- [ ] **環境変数の見直し**: `KEEP_ENV` / `DROP_ENV`（`bin/claude-pane` 冒頭）を本番の変数名に合わせる。秘密を含む変数が残らないこと。
- [ ] **attach のしかた**: 端末（webui など）が `tmux attach -t main` 以外（別のセッション名、`new-session -A` など）で attach するなら、entrypoint の「`main` が無ければ作る」を合わせる。
- [ ] **端末に xterm.js 6.0 を使うとき**: 復元に効く変更は無い。互換性を壊す変更（canvas レンダラーの削除、スクロールバーの作り直し、Alt を Ctrl に読み替える処理の削除）に合わせる。同期出力（DEC 2026）に対応したので、tmux 3.8 との組み合わせで描き直しのちらつきが減る。tmux 3.8 の `clear-on-attach` を off にすると、attach 時に既存の内容が xterm のスクロールバックに残る。
- [ ] **保存の負荷**: 本番の典型的なペイン数・履歴の長さで、ログの `state: saved …, N pane(s) captured in Nms` を見る。
- [ ] **コードレビュー**: `bin/tmux-state`・`bin/claude-pane`・`entrypoint.sh`・`tmux.conf` を、作った人の考えに引きずられない形でレビューする（本番に入れる前）。
