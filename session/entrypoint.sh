#!/bin/bash
# セッションコンテナの入口。
#   session (既定): tmux サーバーを起動し、保存があれば tmux-resurrect で復元して常駐する。
#                   毎秒、変わったところを保存し、docker stop では停止直前に 1 回保存してから終わる。
#                   復元するものが無ければ (初回起動) セッション "main" を作って claude を起動する。
#   それ以外       : 渡されたコマンドをそのまま実行
#
# 保存先 (~/.claude、~/.claude.json、tmux-resurrect の保存、~/.local/state/claude-pane) はどれも $HOME の下にある。
# ボリュームは使わず、コンテナを消さない限り中のファイルが残ることに頼る (止まったコンテナを docker start で起動し直す)。
# このファイルは見本: 復元に必要なのは「起動時の復元」「毎秒の保存と見張り」「SIGTERM での停止直前の保存」の 3 つで、
# 実際のイメージの entrypoint にはそれを組み込む。オンボーディングの省略や main セッションの作成は、この見本の都合。
set -e

# 対話起動時にログイン/テーマ選択/信頼ダイアログで止まらないようにする
if [ ! -f "$HOME/.claude.json" ]; then
  cat > "$HOME/.claude.json" <<'JSON'
{
  "hasCompletedOnboarding": true,
  "bypassPermissionsModeAccepted": true,
  "theme": "dark",
  "projects": {
    "/workspace": {
      "hasTrustDialogAccepted": true,
      "hasCompletedProjectOnboarding": true
    }
  }
}
JSON
fi
mkdir -p "$HOME/.claude"
if [ ! -f "$HOME/.claude/settings.json" ]; then
  echo '{"skipDangerousModePermissionPrompt": true}' > "$HOME/.claude/settings.json"
fi

if [ "$1" != "session" ]; then
  exec "$@"
fi

# tmux 3.8 以降が要る (画面の差分の取り込みに使う書式と、pane-exited・pane-moved などのフック)。
# 古い tmux のまま黙って動くと、画面の文字が保存されないので、ここではっきり止める
TMUX_MIN=3.8
tv=$(tmux -V 2>/dev/null | sed -n 's/^tmux \([0-9][0-9.]*\).*/\1/p')
if [ -z "$tv" ] || [ "$(printf '%s\n%s\n' "$TMUX_MIN" "$tv" | sort -V | head -n1)" != "$TMUX_MIN" ]; then
  echo "entrypoint: ERROR: tmux ${tv:-?} found ($(tmux -V 2>&1)); session recovery needs tmux >= $TMUX_MIN" >&2
  exit 1
fi

RESURRECT_LAST="$HOME/.local/share/tmux/resurrect/last"
# 毎秒、変わったところだけを保存する (構成は変わったら書く。画面は出力があったペインの増えた分だけ取り込む)。
# 保存に時間がかかるときは、かかった時間の SAVE_BACKOFF 倍まで間を空ける (保存に使う時間を全体の 1 割までにする)
SAVE_TICK=1
SAVE_BACKOFF=10
SAVE_MAX_GAP=5 # 間を空けるのはここまで (落ちたときに失うのを最大この秒数にとどめる)
# 「記録の付かない claude」の見張りと、SessionEnd を出さずに死んだ claude を対応表から外すのは、この秒数ごと
SLOW_EVERY=10
STATE="${CLAUDE_PANE_STATE:-$HOME/.local/state/claude-pane}"

# docker stop (SIGTERM) で: 以後の保存を止め、停止直前の構成を 1 回だけ保存してから tmux を終わらせる。
# 先に保存を止めるのは、claude やシェルが終わっていく途中の構成で、良い保存を上書きしないため。
# PID 1 の bash はトラップが無いと SIGTERM を無視する (docker は猶予の後に SIGKILL する)。
on_term() {
  trap - TERM INT
  tmux-state final-save || true
  tmux kill-server 2>/dev/null
  exit 0
}
trap on_term TERM INT

tmux start-server

# 保存があれば復元する。tmux-continuum の自動復元は使わない:
# 起動直後に tmux のプロセスが他に 1 つでもあると「別の tmux サーバーが居る」とみなして復元をやめるため、
# 起動と同時に webui が attach したり、この entrypoint が tmux に問い合わせたりすると黙って復元されない。
# run-shell はコマンドが終わるまで戻らない。復元中の旗と claude の再開は resurrect のフック (claude-pane) が行う。
# 先に prepare-restore で、last が空・途中まで・消えたファイルを指していたら (ホストごと落ちた等) 中身のある
# 最新の保存に向け直し、ペインごとに保存してある画面の文字を resurrect が読む形にまとめる。
# 指す先が消えた last は -e が偽になるので -L でも見る。
if [ -L "$RESURRECT_LAST" ] || [ -e "$RESURRECT_LAST" ]; then
  tmux-state prepare-restore || true
  [ -e "$RESURRECT_LAST" ] && { timeout 300 tmux run-shell /opt/tmux-plugins/tmux-resurrect/scripts/restore.sh || true; }
fi

# 見本の都合: "main" が無ければ (初回起動、または保存に無かった) 作り、claude を起動する。
# (webui が別の名前のセッションに attach するなら、そちらに合わせる)
# claude はペインのシェルから起動する (利用者が打ったのと同じ親子関係にするため)。
if ! tmux has-session -t main 2>/dev/null; then
  tmux new-session -d -s main -x 200 -y 50 -c /workspace
  tmux send-keys -t main \
    "claude --dangerously-skip-permissions ${CLAUDE_MODEL:+--model $CLAUDE_MODEL} ${CLAUDE_EXTRA_ARGS:-}" Enter
fi

# tmux サーバーが生きている間コンテナを生かし、保存と見張りをする。
# 保存は前の保存が終わってから次の時刻を決めるので重ならない (tmux フックからの保存とは tmux-state のロックで排他)。
# sleep を & と wait にしているのは、SIGTERM を受けたらすぐトラップに入るため (前景の sleep が終わるのを待たない)。
next=0
slow=0
while tmux show -gqv exit-empty >/dev/null 2>&1; do
  printf -v now '%(%s)T' -1 # 毎秒回すので、時刻やファイルの読み込みに外部コマンドを使わない
  if [ "$now" -ge "$next" ]; then
    tmux-state save || true
    ms=0
    # save.ms は末尾に改行が無いので read は 1 を返す (set -e で落ちないよう || true)
    [ -f "$STATE/save.ms" ] && { read -r ms <"$STATE/save.ms" || true; }
    gap=$((${ms:-0} * SAVE_BACKOFF / 1000))
    [ "$gap" -lt "$SAVE_TICK" ] && gap=$SAVE_TICK
    [ "$gap" -gt "$SAVE_MAX_GAP" ] && gap=$SAVE_MAX_GAP
    printf -v next '%(%s)T' -1
    next=$((next + gap))
  fi
  if [ "$now" -ge "$slow" ]; then
    claude-pane save || true
    claude-pane check || true
    slow=$((now + SLOW_EVERY))
  fi
  sleep "$SAVE_TICK" &
  wait $!
done
