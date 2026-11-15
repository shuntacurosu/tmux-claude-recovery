#!/usr/bin/env bash
# tmux + Claude Code の会話の復元を確かめる。中身と期待値は docs/verification-notes.md の「ステップ3: テストケース」。
#
# テスト専用のコンテナ (既定 claude-pane-test) を session/ のイメージから作って使う。
# 本番と同じく、ボリュームは付けない (コンテナを消さない限り中のファイルが残ることに頼る)。
# 主シナリオは「docker kill → 同じコンテナを docker start → 復元される」。
#
#   ./test.sh            イメージを作り、新しいコンテナで全部
#   ./test.sh t1 t13     指定したものだけ (t3 以降は t1 の状態を使うので t1 を先に)
#   KEEP=1 ./test.sh     終わってもコンテナを消さない (中を調べるとき)
#   REUSE=1 ./test.sh t13  前回 KEEP=1 で残したコンテナをそのまま使う
#
# 必要なもの: docker、bash、GNU coreutils (md5sum・mktemp)、tar。Linux (Ubuntu 24.04) と Windows の Git Bash の両方で動く。
# モデルを呼ぶ (既定 haiku で 1 往復ずつ)。CLAUDE_CODE_OAUTH_TOKEN を環境変数か、このフォルダの .env に置く。
set -u
export MSYS_NO_PATHCONV=1 # Windows の Git Bash が docker に渡すパスを書き換えないように (Linux では意味を持たない)

DIR=$(cd "$(dirname "$0")" && { pwd -W 2>/dev/null || pwd; }) # Git Bash では D:/... の形 (docker が読める形) にする
C=${C:-claude-pane-test}
IMAGE=${IMAGE:-claude-pane-test}
MODEL=${TEST_MODEL:-haiku}
HUB_TOKEN=test-hub-token-must-not-be-saved # 残さない環境変数の例 (RC_* に一致するが名前に TOKEN を含む)
GRACE=20 # 記録の付かない claude を警告するまでの秒数 (テスト用に短く)
PASS=0 FAIL=0 FAILED=()

if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -f "$DIR/.env" ]; then
  CLAUDE_CODE_OAUTH_TOKEN=$(sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p' "$DIR/.env" | tail -n1 | tr -d '\r"'"'")
fi
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "CLAUDE_CODE_OAUTH_TOKEN を環境変数か $DIR/.env に置いてください" >&2
  exit 2
fi
export CLAUDE_CODE_OAUTH_TOKEN # docker run -e で名前だけ渡す (コマンド行に値を出さない)

X() { docker exec "$C" "$@"; }
XB() { docker exec "$C" bash -c "$1"; }
XR() { docker exec -u root "$C" "$@"; }
opt() { X tmux show -pqv -t "$1" "$2" 2>/dev/null; }
gopt() { X tmux show -gqv "$1" 2>/dev/null; }
cur() { X tmux display -p -t "$1" '#{pane_current_command}' 2>/dev/null; }
send() { X tmux send-keys -t "$1" -l "$2"; sleep 0.5; X tmux send-keys -t "$1" Enter; }
wait_until() { # 秒 コマンド...
  local t=$1 i
  shift
  for ((i = 0; i < t; i++)); do "$@" && return 0; sleep 1; done
  return 1
}
ok() { PASS=$((PASS + 1)); echo "  PASS $*"; }
ng() { FAIL=$((FAIL + 1)); FAILED+=("$CURRENT: $*"); echo "  FAIL $*"; }
info() { echo "  INFO $*"; }
check() { # 説明 コマンド...
  local d=$1
  shift
  if "$@"; then ok "$d"; else ng "$d"; fi
}

LOG=/home/dev/.local/state/claude-pane/log
MAP=/home/dev/.local/state/claude-pane/map
RDIR=/home/dev/.local/share/tmux/resurrect
log_lines() { XB "wc -l < $LOG"; }
log_since() { XB "tail -n +$(($1 + 1)) $LOG"; } # 行番号 → それより後のログ

transcript() { XB "find ~/.claude/projects -name '$1.jsonl' | head -n1"; }
count_in_transcript() { # sid jq-filter
  local f
  f=$(transcript "$1")
  [ -n "$f" ] || { echo 0; return; }
  XB "jq -c '$2' '$f' 2>/dev/null | wc -l"
}
n_assistant() { count_in_transcript "$1" 'select(.type=="assistant")'; }
export -f n_assistant count_in_transcript transcript XB
export C

# claude が動いていて、記録済み (@claude_pid あり) か
claude_up() { [ "$(cur "$1")" = claude ] && [ -n "$(opt "$1" @claude_pid)" ]; }
wait_claude() { wait_until 40 claude_up "$1"; }
start_claude() { # pane [起動コマンド]
  send "$1" "${2:-claude --model $MODEL}"
  wait_claude "$1" || echo "  (warn) claude did not start in $1"
}
ask() { # pane text  — 1 往復して返答が会話ファイルに入るまで待つ
  local sid n0
  sid=$(opt "$1" @claude_sid)
  n0=$(n_assistant "$sid")
  send "$1" "$2"
  wait_until 90 bash -c "[ \"\$(n_assistant $sid)\" -gt $n0 ]" || echo "  (warn) no reply in $1"
  sleep 2
}

save() { X tmux-state save; sleep 1; }
last_name() { XB "readlink $RDIR/last"; }

wait_restored() {
  wait_until 120 bash -c "[ \"\$(docker exec $C tmux show -gqv @restore-finished 2>/dev/null)\" = 1 ]"
}
crash() { # ハング相当: コンテナごと SIGKILL → 同じコンテナを起動 → 復元完了まで待つ
  docker kill "$C" >/dev/null
  sleep 1
  docker start "$C" >/dev/null
  wait_restored || echo "  (warn) restore did not finish"
}

claude_count() { # pane → そのペインの下で動いている claude の数
  local pp
  pp=$(X tmux display -p -t "$1" '#{pane_pid}')
  XB "ps -o comm= --ppid $pp | grep -c '^claude$'"
}
cmdline() { # pane → 動いている claude の引数 (| 区切り)
  XB "tr '\\0' '|' < /proc/$(opt "$1" @claude_pid)/cmdline"
}
reset_session() { # name
  X tmux kill-session -t "$1" 2>/dev/null
  X tmux new-session -d -s "$1" -x 200 -y 50 -c /workspace
}

# 止まっているコンテナから、最新の保存 (last が指すファイル) の中身を読む
stopped_last() {
  local tar link
  tar=$(mktemp)
  docker cp "$C:$RDIR" - >"$tar" 2>/dev/null
  link=$(tar -tvf "$tar" | sed -n 's#.* resurrect/last -> ##p')
  tar -xOf "$tar" "resurrect/$link"
  rm -f "$tar"
}

setup() {
  if [ -n "${REUSE:-}" ]; then
    docker start "$C" >/dev/null 2>&1
    return
  fi
  echo "== setup: build $IMAGE, start $C"
  docker build -q -t "$IMAGE" "$DIR/session" >/dev/null || exit 1
  docker rm -f "$C" >/dev/null 2>&1
  docker run -d --name "$C" --hostname test-host \
    -e CLAUDE_CODE_OAUTH_TOKEN -e CLAUDE_MODEL="$MODEL" \
    -e RC_AGENT_NAME=test -e RC_HOST_NAME=test-host -e RC_HUB_URL=http://127.0.0.1:9 -e RC_HUB_TOKEN="$HUB_TOKEN" \
    -e CLAUDE_PANE_CHECK_GRACE="$GRACE" -e TMUX_STATE_DEBUG="${TMUX_STATE_DEBUG:-}" \
    "$IMAGE" >/dev/null || exit 1
  wait_until 60 claude_up main:0.0 || echo "  (warn) main の claude が起動しない"
}
teardown() {
  [ -n "${KEEP:-}" ] && { echo "(コンテナ $C を残した)"; return; }
  docker rm -f "$C" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------

t1() { # 複数セッション・複数ペイン、同じディレクトリで並行 (テスト 1・2・9)
  reset_session t1
  X tmux split-window -t t1:0 -h -c /workspace
  X tmux new-window -t t1:1 -c /workspace
  reset_session t1b
  local p
  for p in t1:0.0 t1:0.1 t1:1.0 t1b:0.0; do start_claude "$p"; done
  for p in t1:0.0 t1:0.1 t1:1.0 t1b:0.0; do ask "$p" "Reply with only the text: hello from $p"; done
  declare -gA SID
  for p in t1:0.0 t1:0.1 t1:1.0 t1b:0.0; do SID[$p]=$(opt "$p" @claude_sid); done
  check "4 つの会話がすべて別" [ "$(printf '%s\n' "${SID[@]}" | sort -u | wc -l)" = 4 ]
  save
  crash
  for p in t1:0.0 t1:0.1 t1:1.0 t1b:0.0; do
    wait_claude "$p"
    check "$p が元の会話 ${SID[$p]:0:8} で再開" [ "$(opt "$p" @claude_sid)" = "${SID[$p]}" ]
    check "$p の起動オプション (--model $MODEL) が戻る" bash -c "[[ '$(cmdline "$p")' == *'|--model|$MODEL|'* ]]"
  done
  check "再開はフック上も resume" XB "grep -q 'source=resume sid=${SID[t1:0.0]}' $LOG"
}

t3() { # /clear して数ターン → 保存を待たずに kill
  local p=t1:0.0 old new
  old=$(opt $p @claude_sid)
  send $p /clear
  wait_until 20 bash -c "[ \"\$(docker exec $C tmux show -pqv -t $p @claude_sid)\" != '$old' ]"
  new=$(opt $p @claude_sid)
  ask $p "Reply with only the text: after clear"
  ask $p "Reply with only the text: second turn"
  check "/clear で id が変わる" [ "$new" != "$old" ]
  crash
  wait_claude $p
  check "/clear 後の新しい会話で再開" [ "$(opt $p @claude_sid)" = "$new" ]
}

t4() { # /clear 直後 (発言なし) に kill
  local p=t1:0.1 old new
  old=$(opt $p @claude_sid)
  send $p /clear
  wait_until 20 bash -c "[ \"\$(docker exec $C tmux show -pqv -t $p @claude_sid)\" != '$old' ]"
  new=$(opt $p @claude_sid)
  crash
  check "エラーで止まらず claude が動いている" wait_claude $p
  check "発言なしの会話 (id ${new:0:8}) で再開" [ "$(opt $p @claude_sid)" = "$new" ]
}

t5() { # /resume で別の会話に切り替え → kill
  local p=t1:1.0 target
  target=${SID[t1b:0.0]}
  send $p "/resume $target"
  wait_until 20 bash -c "[ \"\$(docker exec $C tmux show -pqv -t $p @claude_sid)\" = '$target' ]"
  crash
  wait_claude $p
  check "/resume 後の会話 ${target:0:8} で再開" [ "$(opt $p @claude_sid)" = "$target" ]
}

t6() { # 手前のペインを閉じて番号をずらす → 保存 → 復元
  local moved
  moved=$(opt t1:0.1 @claude_sid)
  X tmux kill-pane -t t1:0.0
  check "閉じた後、右のペインが t1:0.0 になる" [ "$(opt t1:0.0 @claude_sid)" = "$moved" ]
  save
  crash
  wait_claude t1:0.0
  check "ずれた位置 t1:0.0 で正しい会話に戻る" [ "$(opt t1:0.0 @claude_sid)" = "$moved" ]
  check "閉じたペインは戻らない (t1:0 のペインは 1 つ)" [ "$(X tmux list-panes -t t1:0 | wc -l)" = 1 ]
}

t7() { # /exit で終了 → 保存 → 復元
  local p=t1b:0.0
  send $p /exit
  wait_until 20 bash -c "[ \"\$(docker exec $C tmux display -p -t $p '#{pane_current_command}')\" = bash ]"
  save
  crash
  sleep 5
  check "/exit したペインはシェルのまま" [ "$(cur $p)" = bash ]
  check "対応表に載っていない" XB "! grep -q '^$p' $MAP"
}

t8() { # 新しいペインで claude を起動 → 明示の保存なしですぐ kill (tmux フックの即保存で戻る)
  X tmux new-window -t t1:5 -c /workspace
  start_claude t1:5
  crash
  check "新しく作ったペインが戻る" X tmux display -p -t t1:5 ''
  check "そのペインで claude が動いている" wait_claude t1:5
  X tmux kill-window -t t1:5
}

t10() { # docker stop: 停止直前の構成を 1 回だけ保存し、停止途中の構成で上書きしない
  local n0 after mark
  X tmux rename-window -t t1:1 renamed-before-stop
  X tmux new-window -t t1:7 -n marker -c /workspace
  sleep 1.5
  n0=$(log_lines)
  # 停止の直前 (毎秒の見回りが拾う前) に画面へ出したものも、停止時の保存で残る
  X tmux send-keys -t t1:7 'echo MARK-BEFORE-STOP' Enter
  docker stop -t 30 "$C" >/dev/null
  after=$(stopped_last)
  # 画面の文字は、ペインごとに履歴 (hist-) と見えている画面 (screen-) に分けて置いてある
  mark=$(docker cp "$C:/home/dev/.local/state/claude-pane/pane_contents" - 2>/dev/null | tar -xO --wildcards '*-t1:7.0.*' 2>/dev/null)
  check "停止時の保存に直前の変更 (ウィンドウ名) が入っている" grep -q $'\t:renamed-before-stop\t' <<<"$after"
  check "停止の直前に画面へ出した文字も保存されている" grep -q 'MARK-BEFORE-STOP' <<<"$mark"
  check "停止時の保存で claude のペインは claude のまま (終わっていく途中ではない)" \
    bash -c "[ \$(grep -c \$'^pane\tt1\t.*\tclaude\t' <<<\"\$1\") -ge 2 ]" _ "$after"
  docker start "$C" >/dev/null
  wait_restored
  local logs
  logs=$(log_since "$n0")
  check "停止時の保存 (final) は 1 回" [ "$(grep -c 'state: saved.*(final)' <<<"$logs")" = 1 ]
  check "final の後、tmux が終わるまで保存していない" bash -c "! sed -n '/(final)/,/pre-restore/p' <<<\"\$1\" | grep -v '(final)' | grep -q 'state: saved'" _ "$logs"
  info "停止時の SessionEnd: $(grep -o 'end: .* reason=[a-z_]*' <<<"$logs" | sed 's/.*reason=//' | sort | uniq -c | tr '\n' ' ')"
  check "停止 → 起動で t1:0.0 の claude が戻る" wait_claude t1:0.0
  check "ウィンドウ名も戻る" [ "$(X tmux display -p -t t1:1 '#{window_name}')" = renamed-before-stop ]
  check "停止の直前に出した文字が画面に戻る" bash -c "docker exec $C tmux capture-pane -p -t t1:7 -S - | grep -q MARK-BEFORE-STOP"
  X tmux kill-window -t t1:7
}

t11() { # 復元を 2 回続けて実行
  local p
  X tmux run-shell /opt/tmux-plugins/tmux-resurrect/scripts/restore.sh
  sleep 8
  for p in t1:0.0 t1:1.0; do
    check "$p の claude は 1 つだけ" [ "$(claude_count $p)" = 1 ]
  done
}

t12() { # 保存処理の途中で docker kill
  local d
  for d in 0.05 0.15 0.3 0.6; do
    X tmux rename-window -t t1:0 "w$d" # 中身を変えて、新しい保存ファイルが作られるようにする
    docker exec -d "$C" tmux-state save
    sleep "$d"
    crash
    check "保存開始 ${d}s 後に kill → t1:0.0 が戻る" wait_claude t1:0.0
    check "保存開始 ${d}s 後に kill → last が中身のあるファイルを指す" XB "grep -q ^pane $RDIR/last && tail -n1 $RDIR/last | grep -q ^state"
  done
}

t13() { # 最初のプロンプトが再送されない。空白・; を含む引数、環境変数の扱い
  local p=t13:0.0 sid n pid
  reset_session t13
  X mkdir -p "/workspace/a b"
  # プロンプトは先頭に置く。--add-dir のように値を続けて取るオプションの後ろに置くと、claude 自身がそれを値として読む
  send $p "RC_TEST_VAR='x y' OTHER_VAR=z RC_TEST_TOKEN=leak claude 'Reply with only the text: PING13' --model $MODEL --verbose --append-system-prompt 'Be brief; really.' --add-dir '/workspace/a b'"
  wait_claude $p
  sid=$(opt $p @claude_sid)
  wait_until 90 bash -c "[ \"\$(n_assistant $sid)\" -ge 1 ]"
  sleep 2
  save
  crash
  wait_claude $p
  crash
  wait_claude $p
  sleep 5
  check "同じ会話で再開" [ "$(opt $p @claude_sid)" = "$sid" ]
  n=$(count_in_transcript "$sid" 'select(.type=="user" and ((.message.content|tostring)|test("PING13")))')
  check "PING13 は 1 回だけ (2 回復元しても再送されない。実際 $n 回)" [ "$n" = 1 ]
  check "引数にプロンプトが無い" bash -c "[[ '$(cmdline $p)' != *PING13* ]]"
  check "空白を含む引数がそのまま戻る" bash -c "[[ '$(cmdline $p)' == *'|--add-dir|/workspace/a b|'* ]]"
  check "; を含む引数がそのまま戻る" bash -c "[[ '$(cmdline $p)' == *'|--append-system-prompt|Be brief; really.|'* ]]"
  pid=$(opt $p @claude_pid)
  check "RC_TEST_VAR が戻る" XB "tr '\\0' '\\n' < /proc/$pid/environ | grep -qx 'RC_TEST_VAR=x y'"
  check "OTHER_VAR は戻らない" XB "! tr '\\0' '\\n' < /proc/$pid/environ | grep -q '^OTHER_VAR='"
  check "RC_TEST_TOKEN は戻らない" XB "! tr '\\0' '\\n' < /proc/$pid/environ | grep -q '^RC_TEST_TOKEN='"
}

t14() { # トークン類が保存先に残らない
  local tok where
  tok=$(XB 'printf %s "$CLAUDE_CODE_OAUTH_TOKEN"')
  check "CLAUDE_CODE_OAUTH_TOKEN が環境にある (前提)" [ ${#tok} -gt 20 ]
  # ペインオプションの記録 (base64) を戻したもの
  local opts='for id in $(tmux list-panes -a -F "#{pane_id}"); do tmux show -p -t $id; done |
    sed -n "s/^@claude_\(cwd\|args\|env\) //p" | while read -r v; do printf %s "$v" | base64 -d; echo; done'
  check "ペインオプションに env の記録がある (前提)" XB "{ $opts; } | grep -q RC_AGENT_NAME="
  check "ペインオプションに OAuth トークンが無い" XB "! { $opts; } | grep -qF -- \"\$CLAUDE_CODE_OAUTH_TOKEN\""
  check "ペインオプションに RC_HUB_TOKEN・RC_TEST_TOKEN が無い" XB "! { $opts; } | grep -qE 'RC_HUB_TOKEN|RC_TEST_TOKEN|$HUB_TOKEN'"
  check "対応表・ログ・resurrect の保存に OAuth トークンが無い" XB "! grep -rqF -- \"\$CLAUDE_CODE_OAUTH_TOKEN\" ~/.local/state/claude-pane $RDIR"
  check "対応表に RC_HUB_TOKEN・RC_TEST_TOKEN が無い" XB "! grep -qE 'RC_HUB_TOKEN|RC_TEST_TOKEN|$HUB_TOKEN' $MAP"
  where=$(XB "grep -rlF -e \"\$CLAUDE_CODE_OAUTH_TOKEN\" -e '$HUB_TOKEN' /home/dev /workspace /tmp 2>/dev/null")
  if [ -z "$where" ]; then ok "\$HOME・/workspace・/tmp のどこにも OAuth トークン・hub のトークンが無い"; else ng "トークンが見つかった: $where"; fi
}

t15() { # 古い記録が新しいペインに当たらない
  # 記録はペインオプション (tmux サーバーと一緒に消える) なので、起動直後は対応表から戻したペインにしか無い
  local n_opts n_map
  crash
  n_map=$(XB "wc -l < $MAP")
  n_opts=$(X tmux list-panes -a -F '#{@claude_sid}' | grep -c .)
  check "記録のあるペイン ($n_opts) は対応表の行 ($n_map) と同じ数" [ "$n_opts" = "$n_map" ]
}

t16() { # 復元中の旗が立っている間は保存しない (直接・tmux フック・対応表)。旗は 10 分で期限切れ
  local l0 m0
  l0=$(last_name)
  m0=$(XB "md5sum < $MAP")
  XB 'tmux set -g @claude_pane_restoring "$(date +%s)"'
  X tmux-state save
  X claude-pane save
  X tmux new-window -t t1 -n flagprobe -c /workspace # tmux フックからの保存も走る
  sleep 4
  check "旗あり: 直接・tmux フックからの保存は走らない" [ "$(last_name)" = "$l0" ]
  check "旗あり: 対応表は書き直されない" [ "$(XB "md5sum < $MAP")" = "$m0" ]
  XB 'tmux set -g @claude_pane_restoring "$(( $(date +%s) - 700 ))"'
  X tmux-state save
  sleep 1
  check "旗が 10 分より古ければ保存される" XB "grep -q flagprobe $RDIR/last"
  X tmux set -gu @claude_pane_restoring
  X tmux kill-window -t t1:flagprobe
  sleep 2
  check "旗を下ろせば tmux フックで即保存される (閉じたウィンドウが保存から消える)" XB "! grep -q flagprobe $RDIR/last"
}

t17() { # SessionEnd: 自分で終了したときだけ記録を消す。/clear・/resume・シグナルでは消さない
  local p=t17:0.0 n0 sid old pid
  reset_session t17
  start_claude $p
  ask $p "Reply with only the text: t17"
  sid=$(opt $p @claude_sid)
  # /clear: 記録は新しい id に差し替わるだけ
  n0=$(log_lines)
  send $p /clear
  wait_until 20 bash -c "[ \"\$(docker exec $C tmux show -pqv -t $p @claude_sid)\" != '$sid' ]"
  check "/clear: SessionEnd は reason=clear で記録を残す" bash -c "grep -q 'end: .* reason=clear .*(kept)' <<<\"\$1\"" _ "$(log_since "$n0")"
  check "/clear: 記録がある" [ -n "$(opt $p @claude_sid)" ]
  # /resume: 移った先の id に差し替わるだけ
  n0=$(log_lines)
  send $p "/resume $sid"
  wait_until 20 bash -c "[ \"\$(docker exec $C tmux show -pqv -t $p @claude_sid)\" = '$sid' ]"
  check "/resume: SessionEnd は reason=resume で記録を残す" bash -c "grep -q 'end: .* reason=resume .*(kept)' <<<\"\$1\"" _ "$(log_since "$n0")"
  check "/resume: 記録が移った先の会話" [ "$(opt $p @claude_sid)" = "$sid" ]
  # シグナル: 記録を残す (落ちたのであって、利用者が閉じたのではない)
  n0=$(log_lines)
  pid=$(opt $p @claude_pid)
  X kill -HUP "$pid"
  wait_until 20 bash -c "[ \"\$(docker exec $C tmux display -p -t $p '#{pane_current_command}')\" = bash ]"
  sleep 1
  check "SIGHUP: SessionEnd は記録を消さない" bash -c "! grep -q 'end: .*(record removed)' <<<\"\$1\"" _ "$(log_since "$n0")"
  info "SIGHUP の SessionEnd: $(log_since "$n0" | grep -o 'reason=[a-z_?]*' | tr '\n' ' ')"
  check "SIGHUP: ペインの記録は残る" [ "$(opt $p @claude_sid)" = "$sid" ]
  # /exit: 記録を消し、保存を待たずに落ちても claude は戻らない
  start_claude $p
  n0=$(log_lines)
  send $p /exit
  wait_until 20 bash -c "[ \"\$(docker exec $C tmux display -p -t $p '#{pane_current_command}')\" = bash ]"
  sleep 1
  check "/exit: SessionEnd は reason=prompt_input_exit で記録を消す" bash -c "grep -q 'end: .* reason=prompt_input_exit .*(record removed)' <<<\"\$1\"" _ "$(log_since "$n0")"
  check "/exit: ペインの記録が無い" [ -z "$(opt $p @claude_sid)" ]
  check "/exit: 対応表に載っていない" XB "! grep -q '^$p' $MAP"
  crash
  sleep 5
  check "/exit 直後に kill → シェルのまま" [ "$(cur $p)" = bash ]
}

t18() { # 保存は重ならない。続けて頼まれたら 1 回にまとめる
  local try starts=0 bad=0 ok_seen=0 st
  # docker exec の起動は保存 1 回より遅いので、同時に頼むのはコンテナの中で行う。
  # TMUX_STATE_TRACE に保存の開始・終了の時刻が出るので、区間が重ならないことと回数を見る。
  # (毎秒の見回りがちょうどロックを持っていると 6 回とも抜けて 0 回になるので、3 回まで試す)
  for try in 1 2 3; do
    st=$(XB 'rm -f /tmp/trace; for k in 1 2 3 4 5 6; do tmux rename-window -t main:0 "conc$k$RANDOM"; TMUX_STATE_TRACE=/tmp/trace tmux-state save & done; wait
      [ -f /tmp/trace ] || { echo "0 0"; exit; }
      awk '"'"'$1=="start"{if(open)bad=1; open=1; n++} $1=="end"{open=0} END{print n+0, bad+0}'"'"' /tmp/trace')
    read -r starts bad <<<"$st"
    [ "$bad" = 0 ] || break
    [ "$starts" -gt 0 ] && { ok_seen=1; break; }
  done
  check "保存の区間を書き出せた (前提)" [ "$ok_seen" = 1 ]
  check "保存の区間が重ならない" [ "$bad" = 0 ]
  check "6 回頼んで、保存は 1〜2 回にまとまる (実際 $starts 回)" bash -c "[ $starts -ge 1 ] && [ $starts -le 2 ]"
  # 中身を変えながら続けて保存しても、last の指す先が消えない (同じ秒に 2 回保存したときの resurrect の欠陥)
  XB 'for k in 1 2 3 4 5 6 7 8; do tmux rename-window -t main:0 "burst$k"; tmux-state save; done'
  check "続けて保存しても last の指す先がある" XB "[ -e $RDIR/last ] && grep -q burst8 $RDIR/last"
  X tmux set-window-option -t main:0 automatic-rename on
}

t19() { # ほぼリアルタイム: 構成 (cd・ウィンドウ名) も画面の文字も、変えた 2 秒後に kill して戻る。変わらなければ書かない
  local a b
  X tmux new-window -t t1:8 -c /workspace
  sleep 2
  a=$(XB "ls $RDIR/tmux_resurrect_*.txt | wc -l; readlink $RDIR/last")
  sleep 5
  b=$(XB "ls $RDIR/tmux_resurrect_*.txt | wc -l; readlink $RDIR/last")
  check "何も変えない 5 秒間、構成のファイルは書かれない" [ "$a" = "$b" ]
  X tmux send-keys -t t1:8 'cd /var/log && echo MARK-REALTIME' Enter
  X tmux rename-window -t t1:8 renamed-realtime
  sleep 2
  crash
  check "2 秒前の cd が戻る" [ "$(X tmux display -p -t t1:8 '#{pane_current_path}')" = /var/log ]
  check "2 秒前のウィンドウ名が戻る" [ "$(X tmux display -p -t t1:8 '#{window_name}')" = renamed-realtime ]
  check "2 秒前に出した文字が画面に戻る" bash -c "docker exec $C tmux capture-pane -p -t t1:8 -S - | grep -q MARK-REALTIME"
  info "毎秒の保存 1 回の所要時間: $(XB 'cat ~/.local/state/claude-pane/save.ms')ms (ペイン $(X tmux list-panes -a | wc -l) 個)"
  X tmux kill-window -t t1:8
}

t20() { # 壊れた保存 (ホストごと落ちて途中までしか書けていない) を last が指していたら、中身のある保存に向け直す
  local good
  good=$(last_name)
  XB "cd $RDIR && head -n 2 $good > tmux_resurrect_99991231T000000.txt && ln -sfn tmux_resurrect_99991231T000000.txt last"
  crash
  check "壊れた保存から向け直したと記録される" XB "grep -q 'last pointed to a broken save' $LOG"
  check "向け直した保存から復元され、t1:0.0 の claude が戻る" wait_claude t1:0.0
  XB "rm -f $RDIR/tmux_resurrect_99991231T000000.txt"
  # 消えたファイルを指す last (同じ秒に 2 回保存したときの resurrect の欠陥で起きる)
  XB "ln -sfn tmux_resurrect_00000000T000000.txt $RDIR/last"
  crash
  check "消えたファイルを指す last も向け直して復元する" wait_claude t1:0.0
}

t21() { # フックが動いていない (管理者用設定が無視された) ことに気づける
  local p=t21:0.0
  XR mv /etc/claude-code/managed-settings.d/50-claude-pane.json /tmp/50-claude-pane.json
  reset_session t21
  send $p "claude --model $MODEL"
  wait_until 30 bash -c "[ \"\$(docker exec $C tmux display -p -t $p '#{pane_current_command}')\" = claude ]"
  sleep 2
  check "フックが無いので記録は付かない (前提)" [ -z "$(opt $p @claude_pid)" ]
  wait_until $((GRACE + 70)) bash -c "docker exec $C grep -q 'WARN: $p' $LOG"
  check "${GRACE} 秒 + 見張りの間隔のうちにログに警告が出る" XB "grep -q 'WARN: $p' $LOG"
  check "ステータス行用の @claude_pane_warn に位置が入る" bash -c "[[ ' $(gopt @claude_pane_warn) ' == *' $p '* ]]"
  XR mv /tmp/50-claude-pane.json /etc/claude-code/managed-settings.d/50-claude-pane.json
  send $p /exit
  wait_until 20 bash -c "[ \"\$(docker exec $C tmux display -p -t $p '#{pane_current_command}')\" = bash ]"
  start_claude $p
  wait_until 45 bash -c "[ -z \"\$(docker exec $C tmux show -gqv @claude_pane_warn)\" ]"
  check "フックを戻して起動し直すと警告が消える" [ -z "$(gopt @claude_pane_warn)" ]
}

t22() { # 画面の文字は差分で取り込む: 出力し続けている最中に kill しても、抜け・重複なく戻る
  local r
  X tmux new-window -t t1:9 -c /tmp
  X tmux send-keys -t t1:9 'for i in $(seq 1 6000); do echo $i; sleep 0.002; done' Enter
  sleep 6
  crash
  r=$(XB "d=\$(mktemp -d) && tar xzf $RDIR/pane_contents.tar.gz -C \$d && grep -E '^[0-9]+\$' \$d/pane_contents/pane-t1:9.0 |
    awk 'NR==1{f=\$1} NR>1 && \$1!=p+1 {bad++} {p=\$1} END {print f+0, p+0, bad+0}'")
  read -r first last bad <<<"$r"
  check "出力の途中で kill → 復元した画面の文字は 1 から $last まで抜け・重複なし (不連続 $bad)" bash -c "[ '$first' = 1 ] && [ '$last' -gt 100 ] && [ '$bad' = 0 ]"
  check "復元したペインに同じ文字が出ている" bash -c "docker exec $C tmux capture-pane -p -t t1:9 -S - | grep -qx '$last'"
  X tmux kill-window -t t1:9
}

t23() { # ペインを exit で閉じたら、tmux のフック (pane-exited) ですぐ保存される: 直後に kill しても戻らない
  X tmux new-window -t t1:9 -c /tmp
  X tmux split-window -t t1:9 -c /tmp
  sleep 2
  X tmux send-keys -t t1:9.1 exit Enter
  sleep 0.8
  crash
  check "exit で閉じたペインは戻らない (t1:9 のペインは 1 つ)" [ "$(X tmux list-panes -t t1:9 | wc -l)" = 1 ]
  X tmux kill-window -t t1:9
}

t24() { # 負荷をかけて、出力の途中で kill を何度も繰り返す
  # STRESS_ITER 回 (既定 30)。毎回、3 つのペインで速く出力させ、別の 2 つのペインで CPU を回し、
  # 2〜9.9 秒のどこかで kill する。復元に使った画面の文字で、設計が保証していることを直接確かめる:
  #   抜け・重複      各ペインの連番が途切れていない (1 件でもあれば失敗)
  #   失われた出力    kill の 5 秒前の時点で画面に出ていた行 (= 5 秒より前の出力) がすべて保存されている (欠けていれば失敗)
  #                   (保存の間隔は最大 5 秒。厳密には「5 秒 + 保存 1 回の所要時間」より前が保証される。
  #                    5 秒前の行を控える docker exec の時間が、その分の余裕になる)
  # kill までに新しい出力が 1 行も保存されなかったペインの数は、参考として報告するだけ
  local n=${STRESS_ITER:-30} k p r first last bad at d five fails=0 lost=0 checked=0 unsaved=0 notstarted=0 total=0
  local -A old=()
  X tmux kill-session -t st 2>/dev/null
  X tmux new-session -d -s st -x 160 -y 40 -c /tmp
  X tmux split-window -t st:0 -c /tmp
  X tmux split-window -t st:0 -c /tmp
  X tmux new-window -t st:1 -c /tmp
  X tmux split-window -t st:1 -c /tmp
  # 画面に出ている it<k>-p<p>- の行のうち、最後の 1 行 (書きかけかもしれない) を除いた最後の番号
  live_last() { X tmux capture-pane -p -t "st:0.$2" | grep -o "^it$1-p$2-[0-9]*\$" | sed 's/.*-//' | sed '$d' | tail -n1; }
  for k in $(seq "$n"); do
    # 負荷 (復元のたびにシェルに戻るので毎回起動し直す)
    for p in st:1.0 st:1.1; do X tmux send-keys -t "$p" 'while :; do :; done' Enter; done
    for p in 0 1 2; do
      X tmux send-keys -t "st:0.$p" "for i in \$(seq 1 200000); do echo it$k-p$p-\$i; done" Enter
    done
    # 2〜9.9 秒のどこかで kill。5 秒を超えるときは、kill の 5 秒前に各ペインの最後の番号を控える
    d=$((20 + RANDOM % 80)) # 0.1 秒単位
    for p in 0 1 2; do old[$p]=0; done
    if [ "$d" -gt 50 ]; then
      sleep "$(((d - 50) / 10)).$(((d - 50) % 10))"
      for p in 0 1 2; do five=$(live_last "$k" "$p"); old[$p]=${five:-0}; done
      sleep 5
    else
      sleep "$((d / 10)).$((d % 10))"
    fi
    # kill の直前に、各ペインで出力が始まっていたか (画面に it$k-p<n>- の行があるか) を見ておく
    local started=""
    for p in 0 1 2; do
      X tmux capture-pane -p -t "st:0.$p" | grep -q "^it$k-p$p-[0-9]" && started+=" $p"
    done
    crash
    for p in 0 1 2; do
      # 最後の行は、kill の瞬間に書きかけだった行かもしれない (it3-p0-12345 を書いている途中の it3-p0-12) ので判定から外す
      r=$(XB "d=\$(mktemp -d) && tar xzf $RDIR/pane_contents.tar.gz -C \$d && grep -o '^it$k-p$p-[0-9]*\$' \$d/pane_contents/pane-st:0.$p | sed 's/.*-//' | sed '\$d' |
        awk 'NR==1{f=\$1} NR>1 && \$1!=q+1 {bad++; if (bad<=3) at=at q \"->\" \$1 \",\"} {q=\$1} END {print f+0, q+0, bad+0, at}'")
      read -r first last bad at <<<"$r"
      total=$((total + 1))
      # 最初の行は、履歴の上限 (history-limit) で捨てられていれば 1 でなくてよい。途中の抜け・重複だけを見る
      if [ "$bad" != 0 ]; then
        fails=$((fails + 1))
        echo "  (iter $k st:0.$p) 不連続 $bad、$first..$last ${at:-}"
        XB "d=\$(mktemp -d) && tar xzf $RDIR/pane_contents.tar.gz -C \$d && cp \$d/pane_contents/pane-st:0.$p /tmp/fail-it$k-p$p; cp ~/.local/state/claude-pane/log /tmp/fail-it$k-log; cp ~/.local/state/claude-pane/capture.trace /tmp/fail-it$k-trace 2>/dev/null"
      fi
      [ "${old[$p]}" -gt 0 ] && checked=$((checked + 1))
      if [ "${old[$p]}" -gt 0 ] && [ "$last" -lt "${old[$p]}" ]; then
        lost=$((lost + 1))
        echo "  (iter $k st:0.$p) 5 秒より前の出力が欠けている: kill の 5 秒前に $((old[$p])) まで出ていたが、保存は $last まで"
        XB "cp ~/.local/state/claude-pane/log /tmp/lost-it$k-log; cp ~/.local/state/claude-pane/capture.trace /tmp/lost-it$k-trace 2>/dev/null"
      fi
      if [ "$last" -lt 1 ] && [[ " $started " != *" $p "* ]]; then
        notstarted=$((notstarted + 1))
      elif [ "$last" -lt 1 ]; then
        unsaved=$((unsaved + 1))
      fi
    done
  done
  check "負荷をかけて $n 回 kill → 全 $total ペインで画面の文字に抜け・重複なし (崩れたもの $fails)" [ "$fails" = 0 ]
  check "kill の 5 秒より前の出力がすべて保存されている (確かめたペイン $checked / $total、欠けたもの $lost)" [ "$lost" = 0 ]
  info "kill までに新しい出力が 1 行も保存されなかったペイン: $unsaved / $total (参考。直近 5 秒以内の出力だけのもの)。出力が始まる前に kill したもの: $notstarted"
  X tmux kill-session -t st
}

t25() { # 画面の文字の保存が壊れていても、ペインの構成の復元と claude の再開は成功する
  local S=/home/dev/.local/state/claude-pane case sid
  sid=$(opt t1:0.0 @claude_sid)
  for case in idx-garbage files-missing hist-truncated dir-missing archive-garbage; do
    sleep 2 # 直前の保存を済ませる
    case $case in
      idx-garbage) # 索引をでたらめな中身にする
        XB "head -c 4096 /dev/urandom > $S/pane_contents.idx" ;;
      files-missing) # 履歴と画面のファイルを消す (索引は残る)
        XB "rm -f $S/pane_contents/hist-* $S/pane_contents/screen-*" ;;
      hist-truncated) # 履歴のファイルを、索引に書いた長さより短く切る
        XB "for f in $S/pane_contents/hist-*; do truncate -s 3 \"\$f\"; done" ;;
      dir-missing) # 保存のフォルダと索引ごと消す
        XB "rm -rf $S/pane_contents $S/pane_contents.idx" ;;
      archive-garbage) # 復元に使うまとめのファイルを壊し、組み立て直しの元 (フォルダ) も消す
        XB "rm -rf $S/pane_contents $S/pane_contents.idx; head -c 4096 /dev/urandom > $RDIR/pane_contents.tar.gz" ;;
    esac
    # 保存が走って壊したものを直してしまう前に落とす
    docker kill "$C" >/dev/null
    sleep 1
    docker start "$C" >/dev/null
    if wait_restored; then ok "[$case] 復元が終わる"; else ng "[$case] 復元が終わらない"; fi
    check "[$case] ペインの構成が戻る (t1:0 と t1:1 がある)" bash -c "docker exec $C tmux display -p -t t1:0.0 '' >/dev/null && docker exec $C tmux display -p -t t1:1.0 '' >/dev/null"
    wait_claude t1:0.0
    check "[$case] t1:0.0 の claude が同じ会話で再開する" [ "$(opt t1:0.0 @claude_sid)" = "$sid" ]
    # 起動直後は claude の再開と全ペインの取り込み直しが重なるので、ペインが多いと数秒かかる。最大 30 秒待つ
    check "[$case] その後の保存が元に戻る (索引と画面のファイルが作り直される)" \
      wait_until 30 bash -c "docker exec $C bash -c \"grep -q '^t1:0.0' $S/pane_contents.idx && ls $S/pane_contents/screen-t1:0.0.* >/dev/null 2>&1\""
  done
}

# ---------------------------------------------------------------------------

ALL=(t1 t3 t4 t5 t6 t7 t8 t10 t11 t12 t13 t14 t15 t16 t17 t18 t19 t20 t22 t23 t24 t25 t21)
[ $# -gt 0 ] && ALL=("$@")
setup
for CURRENT in "${ALL[@]}"; do
  echo "== $CURRENT"
  "$CURRENT"
done
teardown
echo
echo "PASS $PASS / FAIL $FAIL"
for f in "${FAILED[@]}"; do echo "  - $f"; done
[ "$FAIL" = 0 ]
