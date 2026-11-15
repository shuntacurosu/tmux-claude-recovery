# tmux-claude-recovery

コンテナ（サンドボックス）が落ちて起動し直したとき、tmux の画面と、各ペインで動いていた Claude Code の会話を、落ちる直前の状態に戻す仕組みです。

## 何が戻るか

ホストがハングしてコンテナごと止まると、tmux のセッション・ウィンドウ・ペインの並び、各ペインの作業ディレクトリと画面の文字、そして「どのペインでどの Claude の会話をしていたか」がすべて消えます。会話そのものは Claude Code が保存しているので `claude --resume <id>` で再開できますが、どのペインがどの会話だったかは手で思い出すしかありません。

この仕組みを入れると、**止まったコンテナを `docker start` で起動し直すだけで**:

- セッション・ウィンドウ・ペインが同じ並び・同じ作業ディレクトリ・同じ名前で戻る
- 各ペインに表示されていた文字（スクロールで見える過去の行も含む）が戻る
- Claude が動いていたペインでは、**そのペインの会話**が元の起動オプション付きで再開される（同じディレクトリで複数並べていても取り違えない。`/clear`・`/resume` で切り替えた後の会話に追従する）

戻らないもの:

- 自分で閉じたもの（`/exit` した Claude、閉じたペイン・ウィンドウ）
- 最初のプロンプト（`claude "…"` の `"…"`）。再送はされません
- `claude -p` などの非対話の実行、`--continue`・`--worktree` など会話や作業場所を新しく作るオプション
- 落ちる直前、普段は 1 秒程度の変化（出力が非常に多いときは最大 5 秒程度）

保存はすべてコンテナの中（`$HOME` の下）に置きます。ボリュームは要りませんが、**コンテナを削除すると保存も消えます**（後述「運用の前提」）。

## 必要なもの

- tmux **3.8 以上**（3.8 未満だと起動時に止まります。Ubuntu 24.04 の標準パッケージは 3.4 なので、ソースからのビルドなどが必要）
- tmux-resurrect
- bash、coreutils、util-linux（`flock`）、procps（`ps`・`pgrep`）、findutils（`find`）、sed、grep、awk、tar、gzip（最小構成のイメージでは抜けていることがあります）
- Claude Code

## イメージへの組み込み

`session/Dockerfile` と `session/entrypoint.sh` が見本です。次のファイルを置き、entrypoint に 3 つの処理を組み込みます。

| ファイル | 置き場所 |
|---|---|
| `session/bin/tmux-state`、`session/bin/claude-pane` | `/usr/local/bin/`（実行権限付き） |
| `session/tmux.conf` | `/etc/tmux.conf`（既存の設定があれば中身を足す。`set -g exit-empty off` は落とさない。これが無いとセッションが無いときに tmux サーバーが終わり、復元できません） |
| `session/managed-settings.d/50-claude-pane.json` | `/etc/claude-code/managed-settings.d/` |
| tmux-resurrect | `/opt/tmux-plugins/tmux-resurrect` |

entrypoint に入れる処理（見本の `entrypoint.sh` の該当部分をそのまま使えます）:

1. **起動時の復元**: `tmux start-server` で tmux サーバーを起動し、保存があれば `tmux-state prepare-restore` の後に `tmux run-shell /opt/tmux-plugins/tmux-resurrect/scripts/restore.sh` を実行する。restore.sh はシェルから直接呼ばず、必ず `tmux run-shell` 経由で呼ぶ（tmux の中で動く前提のスクリプトです）。tmux-continuum の自動復元は使わない
2. **毎秒の保存と見張り**: tmux サーバーが生きている間、`tmux-state save` を毎秒、`claude-pane save` と `claude-pane check` を 10 秒ごとに呼ぶ
3. **停止直前の保存**: SIGTERM を受けたら `tmux-state final-save` してから `tmux kill-server`

Claude Code のフックは管理者用設定（`/etc/claude-code/managed-settings.d/`）に置くので、利用者が自分の設定を変えても消えません。

見本の entrypoint は、初回起動時にセッション `main` を作って `claude` を起動します。モデルと追加の引数は環境変数 `CLAUDE_MODEL`・`CLAUDE_EXTRA_ARGS` で渡せます。webui などが別の名前のセッションに attach する場合は、そこを合わせてください。

本番に入れる前に確かめることは [`docs/production-checklist.md`](docs/production-checklist.md) にまとめてあります。

## 運用の前提

- **コンテナは削除せず、止まったものを `docker start` で起動し直す**。`docker rm` やイメージ更新での作り直しをすると、会話・tmux の保存がすべて消えます。イメージを更新するときの扱いは別に決めてください
- **停止の猶予を十分に取る**。`docker stop` では停止直前に 1 回保存してから終わります。かかる時間はペイン数と履歴の長さに比例します（100 ペイン × 5,000 行で約 5 秒）。`docker stop -t`、compose の `stop_grace_period` などをそれより長くしてください
- **PID 1 に SIGTERM が届くこと**。`tini`・`dumb-init`・シェルのラッパーを挟む場合、entrypoint まで SIGTERM が届くか確かめてください
- ホストが戻ったときにコンテナを自動で起動し直すなら、`restart` ポリシー（`unless-stopped` など）を設定します

## 落ちたとき

止まったコンテナを起動し直すだけです。

```bash
docker start <コンテナ名>
```

起動すると構成と画面の文字が戻り、Claude が動いていたペインでは `claude <元のオプション> --resume <id>` が自動で打ち込まれます。復元中は保存を止め、終わったら再開します。

- 会話ファイルが見つからない（起動しただけで何もしていなかった）ペインは、新しい会話で Claude を起動します
- `/clear` した直後に落ちた場合は、空の会話で再開します
- 復元のたびに、ペインの画面の文字はその前の内容の後ろに積み重なります（既知の挙動）
- 端末の幅が保存時と違うと、長い行は折り返された形で表示されます

手で今すぐ保存したいときは prefix + C-s です（普段は自動で保存されるので不要です）。

## 状態の確かめ方

ログは `~/.local/state/claude-pane/log` にあります（2,000 行を超えると古い行を削り、最新の 1,000 行を残します）。

| ログ | 意味 |
|---|---|
| `hook: %N source=startup sid=…` | ペインの Claude の会話を記録した（`source=resume`・`clear` は再開・切り替え） |
| `state: saved layout, N pane(s) captured in Nms` | 構成を保存した。`(final)` が付くのは停止直前の保存 |
| `restore: <位置>: started sid=… (resume)` | 復元で、そのペインの会話を再開した |
| `restore: <位置>: no transcript for …` | 会話ファイルが無いので新しい会話で起動した |
| `WARN: <位置>: claude … without a SessionStart record` | フックが動いておらず、その Claude の会話は戻らない |
| `restore: unknown option dropped: …` | 知らない起動オプションを、再開時に外した |
| `state: last pointed to a broken save …` | 最新の保存が途中で切れていたので、中身のある保存のうち最も新しいものから戻した |

フックが動いていない Claude があると、tmux のステータス行の右に赤く `claude 未記録: <位置>` と出ます。そのときは:

- Claude で `/status` を開き、`Setting sources` に `Enterprise managed settings` が出ているか（`managed-settings.json` も置いている環境では `(file + drop-ins)` と出ることを確認済み。drop-in だけの環境での表示は未確認）
- 組織の `managed-settings.json` に `disableAllHooks: true` が無いか、`/etc/claude-code/managed-settings.d/` が配布で消えていないか
- `claude --bare` など、フックを読まない起動のしかたをしていないか

## 設定

| 何を | どこで | 既定 |
|---|---|---|
| 保存して復元時に戻す環境変数 | `bin/claude-pane` 冒頭の `KEEP_ENV`（名前の正規表現） | `RC_*`、`CLAUDE_MODEL`、`CLAUDE_CONFIG_DIR` |
| 上のうち保存しないもの | `bin/claude-pane` 冒頭の `DROP_ENV` | 名前に TOKEN・SECRET・PASSWORD・PASSWD・KEY・CREDENTIAL を含むもの |
| フック未動作の警告を出すまでの秒数 | 環境変数 `CLAUDE_PANE_CHECK_GRACE` | 60 |
| 残す構成の保存ファイルの数 | 環境変数 `TMUX_STATE_KEEP` | 120 |
| 保存の間隔の上限（負荷が高いとき） | `entrypoint.sh` の `SAVE_MAX_GAP` | 5 秒 |

環境変数の値は保存先に平文で残ります。**トークンなどの秘密を `KEEP_ENV` に入れないでください。**

## 保存先

| 場所 | 中身 |
|---|---|
| `~/.local/share/tmux/resurrect/` | 構成の保存（`tmux_resurrect_*.txt`）と、最新を指す `last` |
| `~/.local/state/claude-pane/` | ペインと会話の対応表（`map`）、画面の文字、ログ |
| `~/.claude/` | Claude Code の会話そのもの |
| `~/.claude.json` | Claude Code の設定（ディレクトリの信頼など） |

## ライセンス

MIT（[LICENSE](LICENSE)）
