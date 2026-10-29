#!/bin/bash
# 【手元 PC で実行】競技サーバーの初期状態を手元にバックアップする(何かを触る前、最初に実行)。
# サーバー上のバックアップ(env init のアーカイブ / 30 の tar)はサーバーごと壊れると失うので、その保険。
# ssh 越しの tar で取る(scp -r より速く、権限・symlink 等の扱いも安定)。
#
# 使い方(引数は ~/.ssh/config の Host 名):
#   ./00-local-backup.sh isu1 isu2 isu3
#   OUT_DIR=~/isucon-backup ./00-local-backup.sh isu1   # 出力先を変える場合(既定はこのスクリプトと同じ場所の backup/)
#   REMOTE_HOME=/srv/isucon ./00-local-backup.sh isu1   # バックアップ元を変える場合
#
# 出力: <OUT_DIR>/<host>-<時刻>-home-isucon.tar.gz と <host>-<時刻>-etc.tar.gz
# macOS の bash 3.2 でも動くように書く(連想配列・GNU 拡張の date/stat は使わない)。
# backup/ は git 管理しない(.gitignore 済み)。中身にデプロイ秘密鍵等も含まれ得るので共有しない
set -uo pipefail
# 中身に env.sh・debian.cnf・authorized_keys 等が入るので、自分だけが読めるように作る
umask 077

if [ $# -lt 1 ]; then
  echo "usage: $0 <host> [<host> ...]   例: $0 isu1 isu2 isu3"
  exit 1
fi

REMOTE_HOME=${REMOTE_HOME:-/home/isucon}
if [[ ! "$REMOTE_HOME" =~ ^/[A-Za-z0-9_./:@+-]+$ ]]; then
  echo "ERROR: REMOTE_HOME must be an absolute path using ASCII letters, digits or _./:@+-" >&2
  exit 2
fi
for host in "$@"; do
  case "$host" in
    ""|-*|*/*) echo "ERROR: invalid SSH host: $host" >&2; exit 2 ;;
  esac
done
# The restricted path alphabet above permits safe single quoting in the remote shell.
HOME_COMMAND="requested_home='$REMOTE_HOME'
"$(cat <<'REMOTE'
target=$(cd "$requested_home" && pwd -P) || exit 2
[ "$target" != / ] || { echo "ERROR: remote home must not be the filesystem root" >&2; exit 2; }
parent=${target%/*}
name=${target##*/}
[ -n "$parent" ] || parent=/
if sudo -n true 2>/dev/null; then
  sudo -n tar -czf - -C "$parent" -- "$name"
else
  tar -czf - -C "$parent" -- "$name"
fi
REMOTE
)
OUT_DIR=${OUT_DIR:-$(cd "$(dirname "$0")" && pwd)/backup}
TS=$(date +%Y%m%d-%H%M%S)
# BatchMode: パスワード入力待ちで止まらないように。当日の新しい IP は host key を自動で受け入れる
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
mkdir -p "$OUT_DIR"

FAILED=()
WARNED=()

# tar の exit 2 は「読めないファイルがあった」でも出る。gzip として完結していれば
# 部分バックアップとして残す(無いよりまし)。空・壊れているなら失敗扱いで消す
keep_or_remove() {
  local out=$1 label=$2 rc=$3
  if [ -s "$out" ] && gzip -t "$out" 2>/dev/null; then
    WARNED+=("$label: tar が exit ${rc}。読めないファイルがあった可能性。部分バックアップとして残す($out)")
  else
    FAILED+=("$label の取得失敗(exit $rc)")
    rm -f "$out"
  fi
}
i=0
for host in "$@"; do
  i=$((i + 1))
  echo "== [$i/$#] $host =="

  if ! ssh "${SSH_OPTS[@]}" "$host" true; then
    echo "ERROR: $host に ssh できない(~/.ssh/config の Host / IP / 鍵を確認)"
    FAILED+=("$host: ssh 接続失敗")
    continue
  fi

  # 競技ホーム。root 所有のファイルが混じっていても取れるよう、sudo が非対話で使えれば sudo で
  out="$OUT_DIR/$host-$TS-home-isucon.tar.gz"
  echo "  - $REMOTE_HOME -> $out"
  ssh "${SSH_OPTS[@]}" "$host" "$HOME_COMMAND" \
    > "$out"
  rc=$?
  # GNU tar の exit 1 は「読んでいる間にファイルが変わった」等で、アーカイブ自体は使える
  if [ "$rc" -eq 1 ]; then
    WARNED+=("$host: $REMOTE_HOME の tar が警告付きで終了(exit 1。一部ファイルが読み取り中に変化)")
  elif [ "$rc" -ne 0 ]; then
    keep_or_remove "$out" "$host: $REMOTE_HOME" "$rc"
  fi

  # /etc 配下の設定(sudo が要る。存在するものだけ渡す。MariaDB 環境等で /etc/mysql が無いこともある)
  out="$OUT_DIR/$host-$TS-etc.tar.gz"
  if ssh "${SSH_OPTS[@]}" "$host" 'sudo -n true' 2>/dev/null; then
    echo "  - /etc/nginx /etc/mysql /etc/systemd/system -> $out"
    ssh "${SSH_OPTS[@]}" "$host" \
      'p=""; for d in etc/nginx etc/mysql etc/systemd/system; do [ -e "/$d" ] && p="$p $d"; done; sudo -n tar -czf - -C / $p' \
      > "$out"
    rc=$?
    if [ "$rc" -eq 1 ]; then
      WARNED+=("$host: /etc の tar が警告付きで終了(exit 1)")
    elif [ "$rc" -ne 0 ]; then
      keep_or_remove "$out" "$host: /etc" "$rc"
    fi
  else
    WARNED+=("$host: sudo が非対話で使えないため /etc の取得をスキップ")
  fi
done

echo "== 取得したファイル =="
ls -lh "$OUT_DIR"/*-"$TS"-*.tar.gz 2>/dev/null || echo "(なし)"

if [ "${#WARNED[@]}" -gt 0 ]; then
  echo "== WARN =="
  for m in "${WARNED[@]}"; do echo "  $m"; done
fi
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "== 失敗したホスト =="
  for m in "${FAILED[@]}"; do echo "  $m"; done
  exit 1
fi
echo "== done =="
