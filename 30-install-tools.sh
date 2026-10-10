#!/bin/bash
# ツール一括インストール + git/エディタ設定(競技開始直後に全サーバーで実行。isucon ユーザーで)。
# 先頭で「触る前のフルバックアップ」を取る(初期データを壊しても戻せる保険。
# mysqld を止めずに固めるので厳密ではないが、開始直後の無負荷なら実用上戻せる)。
set -euo pipefail

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR=/home/isucon/local          # 競技 repo の .gitignore 対象(local/)
NGINX_ACCESS_LOG=/var/log/nginx/access.log
MYSQL_SLOW_LOG=/var/log/mysql/mysql-slow.log

# --- 触る前のフルバックアップ ---
echo "== 1/4 バックアップ(tar は成功している間は無言。mysql データが大きいと数分かかる)=="
mkdir -p "$BACKUP_DIR"
echo "  - mysql ..."
sudo tar -czf "$BACKUP_DIR/backup-$TIMESTAMP-mysql.tar.gz"   -C / var/lib/mysql       || true
echo "  - nginx / systemd / webapp ..."
sudo tar -czf "$BACKUP_DIR/backup-$TIMESTAMP-nginx.tar.gz"   -C / etc/nginx           || true
sudo tar -czf "$BACKUP_DIR/backup-$TIMESTAMP-systemd.tar.gz" -C / etc/systemd/system  || true
sudo tar -czf "$BACKUP_DIR/backup-$TIMESTAMP-webapp.tar.gz"  -C / home/isucon/webapp  || true
# 取れたかを目視確認(上は || true なので空振りしても止まらない)
ls -lh "$BACKUP_DIR"

# --- ツール ---
echo "== 2/4 ツールインストール =="
# NEEDRESTART_MODE=a: needrestart の「どのサービスを再起動するか」対話を自動化
# (対象はシステム系サービスのみで nginx / mysql / アプリには影響しない)
sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update
sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y percona-toolkit graphviz unzip vim dstat htop tmux
# alp(バージョンは事前に最新を確認しておく)
# ⚠️ amd64 決め打ち。arm 環境の年なら alp_linux_arm64.zip に差し替える
wget -q https://github.com/tkuchiki/alp/releases/download/v1.0.21/alp_linux_amd64.zip -O /tmp/alp.zip
unzip -o /tmp/alp.zip -d /tmp
sudo install /tmp/alp /usr/local/bin/alp
# slp(slow query log 版 alp。pt-query-digest より軽く読める)。
# alp と同じバイナリ配布を使う(go install は環境の Go が古いと失敗する。
# 例: isucon11f は Go 1.17 で、slp の go.mod の toolchain ディレクティブを解釈できない)
if wget -q https://github.com/tkuchiki/slp/releases/download/v0.2.3/slp_linux_amd64.tar.gz -O /tmp/slp.tar.gz; then
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
echo "== 3/4 ログ読み取り権限 =="
sudo chmod +rx /var/log/nginx || true
sudo test -f "$NGINX_ACCESS_LOG" && sudo chmod +r "$NGINX_ACCESS_LOG" || true
sudo chmod +rx /var/log/mysql || true
sudo test -f "$MYSQL_SLOW_LOG" && sudo chmod +r "$MYSQL_SLOW_LOG" || true

# --- git・エディタを vim に固定(nano 事故防止)---
echo "== 4/4 git / エディタ設定 =="
git config --global core.editor vim
grep -q 'EDITOR=vim' ~/.bashrc || echo 'export EDITOR=vim VISUAL=vim' >> ~/.bashrc
sudo update-alternatives --set editor /usr/bin/vim.basic || true
cat > ~/.vimrc <<'EOF'
set number
set tabstop=4 shiftwidth=4 expandtab
set hlsearch incsearch ignorecase smartcase
syntax on
EOF

echo "== done =="
