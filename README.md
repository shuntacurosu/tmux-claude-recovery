# tmux-claude-recovery

コンテナ（サンドボックス）が落ちて起動し直したとき、tmux の画面と、各ペインで動いていた Claude Code の会話を、落ちる直前の状態に戻す仕組みです。

## 何を解決するか

ホストがハングしてコンテナごと止まると、tmux のセッション・ウィンドウ・ペインの並び、各ペインの作業ディレクトリと画面の文字、そして「どのペインでどの Claude の会話をしていたか」がすべて消えます。会話そのものは Claude Code が保存しているので `claude --resume <id>` で再開できますが、どのペインがどの会話だったかは手で思い出すしかありません。

この仕組みを入れると、**止まったコンテナを `docker start` で起動し直すだけで**:

- セッション・ウィンドウ・ペインが同じ並び・同じ作業ディレクトリで戻る
- 各ペインに表示されていた文字が戻る
- Claude が動いていたペインでは、**そのペインの会話**が元の起動オプション付きで再開される（同じディレクトリで複数並べていても取り違えない。`/clear`・`/resume` で切り替えた後の会話に追従する）

自分で閉じたもの（`/exit` した Claude、閉じたペイン）は戻しません。最初のプロンプト（`claude "…"`）が再送されることもありません。webui などのランチャーには依存せず、コンテナの中だけで完結します。

## 仕組み

保存するものは 3 つです。

| 保存するもの | 中身 | いつ | 担当 |
|---|---|---|---|
| 構成 | セッション・ウィンドウ・ペインの並び、作業ディレクトリ、名前 | 変わったとき（作る・閉じるはその場で、`cd` などは 1 秒以内） | `bin/tmux-state` |
| 画面の文字 | 各ペインに表示されていた文字（スクロールで見える過去の行も含む） | 出力があったペインの増えた行だけ、毎秒 | `bin/tmux-state` |
| Claude の対応表 | 「この位置のペインでは、この会話を、このオプションで開いていた」 | Claude が起動したとき・会話が切り替わったとき | `bin/claude-pane`（Claude Code の SessionStart / SessionEnd フック） |

起動し直すと、entrypoint が tmux-resurrect で構成と画面の文字を作り直し、対応表を見て、Claude が動いていたペインで `claude <元のオプション> --resume <id>` を実行します。

落ちたときに失うのは、普段は直近 1 秒程度です（1 秒に数万行が流れ続けるような極端な負荷のときは、保存の CPU を抑えるために間隔を空けるので、最大 5 秒程度）。

主な工夫:

- 保存は「書き終わってから 1 回で切り替える」ので、保存の途中で落ちても前の正しい保存が残る。画面の文字の保存が壊れていても、構成と Claude の再開は成功する
- 復元中・停止中は保存しない。`docker stop`（SIGTERM）では、止まる直前に 1 回だけ保存してから終わる
- Claude が動いているのに対応表の記録が付かない（フックが動いていない）ペインがあれば、tmux のステータス行に赤い警告を出す
- 保存する環境変数は名前を決めたものだけ（`bin/claude-pane` 冒頭の `KEEP_ENV` / `DROP_ENV`）。トークン類は残さない

## 構成

```
session/
  Dockerfile                          見本と検証用のイメージ (tmux 3.8 をソースからビルド)
  entrypoint.sh                       起動時の復元、毎秒の保存と見張り、SIGTERM での停止直前の保存 (見本)
  tmux.conf                           /etc/tmux.conf。tmux-resurrect の読み込みと、構成の変化ですぐ保存する tmux フック
  bin/tmux-state                      構成と画面の文字の保存
  bin/claude-pane                     Claude の対応表と再開
  managed-settings.d/50-claude-pane.json  Claude のフックの登録 (/etc/claude-code/managed-settings.d/)
test.sh                               テスト (23 の場面、確認項目 110)
docs/verification-notes.md            検証の経緯・決定事項・結果・本番のチェックリスト
```

## 必要なもの

- tmux **3.8 以上**（ペインごとの出力の番号・履歴の行数の書式と、`pane-exited` などのフックを使う。3.8 未満だと entrypoint が起動を止める）
- tmux-resurrect（復元にだけ使う。保存は `tmux-state` が resurrect と同じ形式で書く）
- bash、coreutils、util-linux（`flock`）、procps（`ps`・`pgrep`）
- Claude Code（フックは管理者用設定 `/etc/claude-code/managed-settings.d/` に置く。利用者が自分の設定を変えても消えない）

実際のサンドボックスのイメージに組み込むときは、`session/Dockerfile` と `session/entrypoint.sh` を見本として、上のファイルと entrypoint の復元の部分を組み込みます。本番で確かめることは `docs/verification-notes.md` の「本番コンテナで確認が必要な項目（チェックリスト）」にあります。

## テストを流す

```bash
cp .env.example .env            # CLAUDE_CODE_OAUTH_TOKEN= の行に書く (.env は git に入れない)。環境変数で渡してもよい
./test.sh 2>&1 | tee test.log   # イメージのビルドから、テスト専用コンテナの作成・削除まで自動。全体で約 45 分
```

- テスト専用のコンテナ（既定 `claude-pane-test`）を `session/` のイメージから作り、ボリュームは付けません。主な場面は「`docker kill` → 同じコンテナを `docker start` → 復元される」です。
- Claude は haiku で 1 往復ずつ呼びます。
- `./test.sh t1 t13` で一部だけ、`KEEP=1` でコンテナを残す、`REUSE=1` で残したコンテナを使う、`STRESS_ITER=50` でストレステストの回数を変える、`TMUX_STATE_DEBUG=1` で画面の取り込みの記録（`~/.local/state/claude-pane/capture.trace`）を出す。
- Linux（Ubuntu 24.04）と Windows の Git Bash の両方で動きます。手順の詳細は `docs/verification-notes.md` の「Ubuntu 24.04 で再テストする手順」。
