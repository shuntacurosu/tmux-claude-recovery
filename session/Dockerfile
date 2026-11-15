# 見本と検証用のイメージ: tmux の中で claude を動かすコンテナ 1 台ぶん。
# 実際のサンドボックスのイメージには、tmux 3.8 以上・tmux-resurrect・bin/・tmux.conf・managed-settings.d/ と、
# entrypoint.sh の復元の部分を組み込む

# tmux は本番と同じ最新版 (3.8) をソースから作る。Debian bookworm の tmux は 3.3a で、
# 画面の差分の取り込みに使う書式 (pane_output_generation、history_added など) や
# pane-exited・pane-moved などのフックが無い。配布物は sha256 で確かめる。
FROM debian:bookworm AS tmux-build
ARG TMUX_VERSION=3.8
ARG TMUX_SHA256=e79c699c7e949dccd0a4a125e17b8d1261e311b16979dbc8eb34542f3966d82e
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential pkg-config bison libevent-dev libncurses-dev curl ca-certificates \
 && curl -fsSL -o /tmp/tmux.tar.gz https://github.com/tmux/tmux/releases/download/${TMUX_VERSION}/tmux-${TMUX_VERSION}.tar.gz \
 && echo "${TMUX_SHA256}  /tmp/tmux.tar.gz" | sha256sum -c - \
 && tar xzf /tmp/tmux.tar.gz -C /tmp \
 && cd /tmp/tmux-${TMUX_VERSION} && ./configure --prefix=/usr/local >/dev/null && make -j"$(nproc)" >/dev/null && make install >/dev/null

FROM node:22-bookworm-slim

# libevent-core は tmux が実行時に使う
RUN apt-get update \
 && apt-get install -y --no-install-recommends libevent-core-2.1-7 git curl ca-certificates procps less jq locales \
 && sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen \
 && rm -rf /var/lib/apt/lists/*

ARG CLAUDE_VERSION=2.1.322
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_VERSION}

COPY --from=tmux-build /usr/local/bin/tmux /usr/local/bin/tmux
COPY --from=tmux-build /usr/local/share/man/man1/tmux.1 /usr/local/share/man/man1/tmux.1
# イメージを作る時点でも確かめる (entrypoint は 3.8 未満だと起動を止める)
RUN tmux -V && tmux -V | grep -Eq '^tmux (3\.(8|9|[1-9][0-9])|[4-9]\.)'

# tmux の構成・画面の保存と復元。TPM は使わず固定版を置き、/etc/tmux.conf から直接読む
ARG RESURRECT_REV=cff343cf9e81983d3da0c8562b01616f12e8d548
RUN git clone -q https://github.com/tmux-plugins/tmux-resurrect /opt/tmux-plugins/tmux-resurrect \
 && git -C /opt/tmux-plugins/tmux-resurrect checkout -q $RESURRECT_REV
COPY tmux.conf /etc/tmux.conf

# 保存の入口 (tmux-state)、各ペインの claude の会話を記録・復元するスクリプト (claude-pane)、
# それを呼ぶ SessionStart / SessionEnd フック。
# フックは管理者用設定 (/etc/claude-code) に置き、利用者の設定を書き換えても消えないようにする
COPY bin/ /usr/local/bin/
COPY managed-settings.d/ /etc/claude-code/managed-settings.d/
RUN chmod 755 /usr/local/bin/claude-pane /usr/local/bin/tmux-state

RUN useradd -m -s /bin/bash dev && mkdir -p /workspace && chown dev:dev /workspace
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TERM=xterm-256color

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER dev
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["session"]
