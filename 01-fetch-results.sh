#!/bin/bash
# 【手元 PC で実行】各サーバーの解析結果(make analyze の analysis/ と make pprof-record の pprof/)を
# 手元にコピーする。手元で動かす AI エージェントや自分で読むため。
# サーバーからは読み取るだけ(エージェントに競技サーバーへの ssh を渡さずに済むようにする)。
# 生ログ(access.log / slow log)は数百 MB になり読みにくいので取らない。先に make analyze で要約する。
#
# 使い方(引数は ~/.ssh/config の Host 名。何度実行しても差分だけ取る):
#   ./01-fetch-results.sh isu1 isu2 isu3
#   FETCH_DIR=~/isucon-fetched ./01-fetch-results.sh isu1   # 出力先を変える場合(既定はこのスクリプトと同じ場所の fetched/)
#
# 出力: <FETCH_DIR>/<host>/analysis/<時刻>/{alp.txt,slow-query.txt,alp.dump}
#       <FETCH_DIR>/<host>/pprof/*.pb.gz(手元に go があれば、横に要約テキスト *.top.txt も作る)
# macOS の bash 3.2 でも動くように書く。fetched/ は git 管理しない(.gitignore 済み)
set -uo pipefail
# 解析結果には実際のクエリやデータが含まれるので、自分だけが読めるように作る
umask 077

if [ $# -lt 1 ]; then
  echo "usage: $0 <host> [<host> ...]   例: $0 isu1 isu2 isu3"
  exit 1
fi

FETCH_DIR=${FETCH_DIR:-$(cd "$(dirname "$0")" && pwd)/fetched}
REMOTE_HOME=${REMOTE_HOME:-/home/isucon}
# BatchMode: パスワード入力待ちで止まらないように。当日の新しい IP は host key を自動で受け入れる
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
HAVE_GO=0
command -v go > /dev/null && HAVE_GO=1

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
  # 両側に rsync があれば差分だけ取る。無ければ ssh 越しの tar で丸ごと取る
  use_rsync=0
  if command -v rsync > /dev/null && ssh "${SSH_OPTS[@]}" "$host" 'command -v rsync > /dev/null'; then
    use_rsync=1
  fi

  for d in analysis pprof; do
    if ! ssh "${SSH_OPTS[@]}" "$host" "test -d $REMOTE_HOME/$d"; then
      echo "  - $d: サーバーにまだ無い(make analyze / make pprof-record していない)"
      continue
    fi
    mkdir -p "$FETCH_DIR/$host/$d"
    echo "  - $REMOTE_HOME/$d -> $FETCH_DIR/$host/$d"
    if [ "$use_rsync" = 1 ]; then
      rsync -az -e "ssh ${SSH_OPTS[*]}" "$host:$REMOTE_HOME/$d/" "$FETCH_DIR/$host/$d/" \
        || FAILED+=("$host: $d の取得失敗(rsync)")
    else
      ssh "${SSH_OPTS[@]}" "$host" "tar -czf - -C $REMOTE_HOME $d" | tar -xzf - -C "$FETCH_DIR/$host" \
        || FAILED+=("$host: $d の取得失敗(tar)")
    fi
  done

  # pprof はバイナリなので、エージェントがそのまま読める要約テキストを横に作る(作成済みは飛ばす)
  if [ -d "$FETCH_DIR/$host/pprof" ]; then
    if [ "$HAVE_GO" = 1 ]; then
      for f in "$FETCH_DIR/$host/pprof"/*.pb.gz; do
        [ -e "$f" ] || continue
        txt="${f%.pb.gz}.top.txt"
        [ -s "$txt" ] && continue
        go tool pprof -top -nodecount=50 "$f" > "$txt" 2> /dev/null \
          || { rm -f "$txt"; WARNED+=("$host: $(basename "$f") の要約に失敗"); }
      done
    else
      WARNED+=("$host: 手元に go が無いため pprof の要約テキスト(*.top.txt)は作っていない")
    fi
  fi

  latest=$(ls -1 "$FETCH_DIR/$host/analysis" 2> /dev/null | tail -n 1)
  [ -n "$latest" ] && echo "  最新の analyze: $FETCH_DIR/$host/analysis/$latest"
done

if [ "${#WARNED[@]}" -gt 0 ]; then
  echo "== WARN =="
  for m in "${WARNED[@]}"; do echo "  $m"; done
fi
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "== 失敗 =="
  for m in "${FAILED[@]}"; do echo "  $m"; done
  exit 1
fi
echo "== done. $FETCH_DIR を AI エージェントに渡す(競技データなので外部へ公開・共有しない)=="
