#!/bin/bash
# ツール一括インストール + git/エディタ設定(競技開始直後に全サーバーで実行。isucon ユーザーで)。
# 先頭で「触る前のフルバックアップ」を取る(初期データを壊しても戻せる保険。
# mysqld を止めずに固めるので厳密ではないが、開始直後の無負荷なら実用上戻せる)。
set -euo pipefail
# symlink 経由で実行されても lib を見つけられるよう実体のパスから辿る
SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/install-tools.sh"
log_start "触る前のバックアップ + ツール導入 + ログ権限 + git/エディタ/tmux 設定"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ISUCON_HOME=${ISUCON_HOME:-/home/isucon}
[[ -d "$ISUCON_HOME" ]] || { echo "ERROR: invalid ISUCON_HOME: $ISUCON_HOME" >&2; exit 1; }
ISUCON_HOME=$(cd "$ISUCON_HOME" && pwd -P)
[[ "$ISUCON_HOME" != / ]] || { echo "ERROR: ISUCON_HOME must not be the filesystem root" >&2; exit 1; }
BACKUP_DIR="$ISUCON_HOME/local"          # 競技 repo の .gitignore 対象(local/)
NGINX_ACCESS_LOG=${NGINX_ACCESS_LOG:-/var/log/nginx/access.log}
MYSQL_SLOW_LOG=${MYSQL_SLOW_LOG:-/var/log/mysql/mysql-slow.log}

# --- 触る前のフルバックアップ ---
echo "== [1/4] バックアップ(tar は成功している間は無言。mysql データが大きいと数分かかる)=="
backup_before_install

# --- ツール ---
echo "== [2/4] ツールインストール =="
# NEEDRESTART_MODE=a: needrestart の「どのサービスを再起動するか」対話を自動化
# (対象はシステム系サービスのみで nginx / mysql / アプリには影響しない)
apt_with_lock_retry update
# Dpkg::Options: 設定ファイル(conffile)の差し替え確認は DEBIAN_FRONTEND では抑止できず、
# tee 経由だとプロンプトが見えないまま止まり得る。既存の設定を残す側に自動回答させる
apt_with_lock_retry install -y \
  -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
  percona-toolkit graphviz unzip vim dstat htop tmux
# CPU アーキテクチャ自動判定(amd64 / arm64。multipass on Apple Silicon は arm64)。
# 合わないバイナリを入れると「Syntax error: word unexpected」という不可解なエラーになる
ARCH=$(dpkg --print-architecture)
# alp(バージョンは事前に最新を確認しておく)
wget -q "https://github.com/tkuchiki/alp/releases/download/v1.0.21/alp_linux_${ARCH}.zip" -O /tmp/alp.zip
unzip -o /tmp/alp.zip -d /tmp
sudo install /tmp/alp /usr/local/bin/alp
# slp(slow query log 版 alp。pt-query-digest より軽く読める)。
# alp と同じバイナリ配布を使う(go install は環境の Go が古いと失敗する。
# 例: isucon11f は Go 1.17 で、slp の go.mod の toolchain ディレクティブを解釈できない)
if wget -q "https://github.com/tkuchiki/slp/releases/download/v0.2.3/slp_linux_${ARCH}.tar.gz" -O /tmp/slp.tar.gz; then
  mkdir -p /tmp/slp-extract
  tar -xzf /tmp/slp.tar.gz -C /tmp/slp-extract
  SLP_BIN=$(find /tmp/slp-extract -name slp -type f | head -1)
  if [ -n "$SLP_BIN" ]; then
    sudo install "$SLP_BIN" /usr/local/bin/slp
  else
    echo "WARN: slp.tar.gz に slp バイナリが見つからない"
  fi
else
  echo "WARN: slp のダウンロードに失敗(後で入れ直せる)"
fi

# --- ログを isucon ユーザーでも読めるように(alp / slp / pprotein-agent 用)---
echo "== [3/4] ログ読み取り権限 =="
sudo chmod +rx "$(dirname "$NGINX_ACCESS_LOG")" || true
sudo test -f "$NGINX_ACCESS_LOG" && sudo chmod +r "$NGINX_ACCESS_LOG" || true
sudo chmod +rx "$(dirname "$MYSQL_SLOW_LOG")" || true
sudo test -f "$MYSQL_SLOW_LOG" && sudo chmod +r "$MYSQL_SLOW_LOG" || true

# --- git・エディタを vim に固定(nano 事故防止)---
echo "== [4/4] git / エディタ設定 =="
# identity(未設定だと commit が失敗する)。env の init は local 設定なので、
# ここでは s2/s3 を含めた全台の既定値を設定する
git config --global user.email isucon@example.com
git config --global user.name "$(hostname)"
git config --global core.editor vim
# pull 時の「divergent branches をどう解決するか」の質問を止め、履歴を線形に保つ
git config --global pull.rebase true
# 初回 push の「--set-upstream しろ」を省略(git 2.37+ で有効。Ubuntu 22.04 の 2.34 では
# 効かないが無害。古い git では s2/s3 合流手順の `git branch -u origin/main main` が代わり)
git config --global push.autoSetupRemote true
grep -q 'EDITOR=vim' ~/.bashrc || echo 'export EDITOR=vim VISUAL=vim' >> ~/.bashrc
sudo update-alternatives --set editor /usr/bin/vim.basic || true
cat > ~/.vimrc <<'EOF'
set number
set tabstop=4 shiftwidth=4 expandtab
set hlsearch incsearch ignorecase smartcase
syntax on
EOF

# tmux(prefix は C-b から C-q に変更。C-b はシェルのカーソル移動と衝突するため)
cat > ~/.tmux.conf <<'EOF'
set -g prefix C-q
unbind C-b
bind C-q send-prefix
set -g mouse on
set -g history-limit 50000
setw -g mode-keys vi
# ペイン分割を直感的なキーに(| で縦、- で横)
bind | split-window -h
bind - split-window -v
# 全ペイン録画: 新しいウィンドウ/ペインは util-linux の script 経由で起動し、タイミング付きで記録する。
# 保存先 ~/local/tmux-rec は競技 repo で gitignore 済み。旧 util-linux でも使える timing 形式で記録する。
# 録画の起動に失敗したら素の bash にする。
# 画面に出たものは全部残る(秘密を画面に出さない)。録画しないペインは prefix : new-window bash
set -g default-command 'd=$HOME/local/tmux-rec; mkdir -p "$d"; f="$d/$(hostname -s)-$(date +%Y%m%d-%H%M%S)-p${TMUX_PANE#%}"; script -q -f --timing="$f.tm" -c "exec bash -l" "$f.out" || exec bash -l'
EOF

{ set +x; } 2>/dev/null
echo "== done =="
