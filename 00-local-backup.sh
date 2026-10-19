#!/bin/bash
# 【手元 PC で実行】競技サーバーの初期状態を手元にバックアップする(何かを触る前、最初に実行)。
# サーバー上のバックアップ(20 のアーカイブ / 30 の tar)はサーバーごと壊れると失うので、その保険。
# ssh 越しの tar で取る(scp -r より速く、権限・symlink 等の扱いも安定)。
#
# 使い方(引数は ~/.ssh/config の Host 名):
#   ./00-local-backup.sh isu1 isu2 isu3
#   OUT_DIR=~/isucon-backup ./00-local-backup.sh isu1   # 出力先を変える場合(既定 ./backup)
#
# 出力: <OUT_DIR>/<host>-<時刻>-home-isucon.tar.gz と <host>-<時刻>-etc.tar.gz
# macOS の bash 3.2 でも動くように書く(連想配列・GNU 拡張の date/stat は使わない)。
# backup/ は git 管理しない(.gitignore 済み)。中身にデプロイ秘密鍵等も含まれ得るので共有しない
set -uo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <host> [<host> ...]   例: $0 isu1 isu2 isu3"
  exit 1
fi

OUT_DIR=${OUT_DIR:-./backup}
TS=$(date +%Y%m%d-%H%M%S)
# BatchMode: パスワード入力待ちで止まらないように。当日の新しい IP は host key を自動で受け入れる
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
mkdir -p "$OUT_DIR"

FAILED=()
WARNED=()
i=0
for host in "$@"; do
  i=$((i + 1))
  echo "== [$i/$#] $host =="

  if ! ssh "${SSH_OPTS[@]}" "$host" true; then
    echo "ERROR: $host に ssh できない(~/.ssh/config の Host / IP / 鍵を確認)"
    FAILED+=("$host: ssh 接続失敗")
    continue
  fi

  # /home/isucon。root 所有のファイルが混じっていても取れるよう、sudo が非対話で使えれば sudo で
  out="$OUT_DIR/$host-$TS-home-isucon.tar.gz"
  echo "  - /home/isucon -> $out"
  ssh "${SSH_OPTS[@]}" "$host" \
    'if sudo -n true 2>/dev/null; then sudo -n tar -czf - -C /home isucon; else tar -czf - -C /home isucon; fi' \
    > "$out"
  rc=$?
  # GNU tar の exit 1 は「読んでいる間にファイルが変わった」等で、アーカイブ自体は使える
  if [ "$rc" -eq 1 ]; then
    WARNED+=("$host: /home/isucon の tar が警告付きで終了(exit 1。一部ファイルが読み取り中に変化)")
  elif [ "$rc" -ne 0 ]; then
    FAILED+=("$host: /home/isucon の取得失敗(exit $rc)")
    rm -f "$out"
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
      FAILED+=("$host: /etc の取得失敗(exit $rc)")
      rm -f "$out"
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
