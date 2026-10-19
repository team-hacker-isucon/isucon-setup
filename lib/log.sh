# shellcheck shell=bash
# 共通ログ処理(サーバー上で動かす 10/20/30/90 の先頭で source する)。
# - 出力を画面とログファイルの両方に出す(当日あとから「どこで何が起きたか」を追えるように)
# - log_start 以降は set -x で全コマンドを時刻付きでトレースする
# - 失敗時は「どのスクリプトの何行目の何のコマンドか」とログの場所を目立つ形で出す
# 注意: set -x 中は変数が展開された形で記録される。秘匿値(token 等)を扱う区間は
#       呼び出し側で `{ set +x; } 2>/dev/null` してから実行し、終わったら set -x に戻す(90 参照)

_LOG_SCRIPT=$(basename "$0" .sh)
_LOG_TS=$(date +%Y%m%d-%H%M%S)

# 親ディレクトリが存在する候補だけ使う(mkdir -p で /home/isucon 自体を作ってしまわないように)。
# ubuntu 等で実行して /home/isucon に書けない場合は自分のホームへ
LOG_DIR=""
for _d in /home/isucon/isucon-setup-logs "$HOME/isucon-setup-logs" "${TMPDIR:-/tmp}/isucon-setup-logs"; do
  if [ -d "${_d%/*}" ] && mkdir -p "$_d" 2>/dev/null && [ -w "$_d" ]; then
    LOG_DIR=$_d
    break
  fi
done
unset _d
LOG_FILE="$LOG_DIR/$_LOG_SCRIPT-$_LOG_TS.log"

# 元の画面出力を 3/4 に退避(終了時に戻して tee の書き切りを待つため)
exec 3>&1 4>&2
# -i: Ctrl-C の SIGINT で tee が先に死ぬと、最後の失敗表示が画面にもログにも出なくなる
exec > >(tee -ia "$LOG_FILE") 2>&1
_LOG_TEE_PID=${!:-}

# 関数内・サブシェル内の失敗でも ERR trap を発火させる
set -E

# LOG_ERR_HINT: 呼び出し側がフェーズごとに設定しておくと、失敗時に復旧手順として表示する
LOG_ERR_HINT=""

_log_on_err() {
  local rc=$1 pipestatus=$2 src=$3 line=$4 cmd=$5
  { set +x; } 2>/dev/null
  # $(...) やパイプ内の失敗は親でも同じ trap が発火するので、親の1回だけ表示する
  [ "${BASH_SUBSHELL:-0}" -eq 0 ] || return 0
  echo ""
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "!! FAILED: ${src} の ${line} 行目 (exit ${rc})"
  echo "!! コマンド(パイプなら末尾要素): ${cmd}"
  case "$pipestatus" in *" "*) echo "!! パイプ各段の exit: ${pipestatus}" ;; esac
  echo "!! ログ: ${LOG_FILE}"
  if [ -n "$LOG_ERR_HINT" ]; then
    echo "!! 復旧:"
    printf '%s\n' "$LOG_ERR_HINT" | sed 's/^/!!   /'
  fi
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
}
trap '_log_on_err $? "${PIPESTATUS[*]}" "${BASH_SOURCE[0]##*/}" "$LINENO" "$BASH_COMMAND"' ERR

_log_on_exit() {
  local rc=$?
  { set +x; } 2>/dev/null
  echo ""
  if [ "$rc" -eq 0 ]; then
    echo "== 正常終了 $(date '+%F %T')  ログ: ${LOG_FILE} =="
  else
    echo "== 異常終了 (exit ${rc}) $(date '+%F %T')  ログ: ${LOG_FILE} =="
  fi
  # tee に EOF を渡して書き切るまで待つ(待たないとプロンプトの後に出力が続く)
  exec 1>&3 2>&4 3>&- 4>&-
  if [ -n "$_LOG_TEE_PID" ]; then wait "$_LOG_TEE_PID" 2>/dev/null || true; fi
}
trap _log_on_exit EXIT

# 冒頭の案内を出してからトレースを開始する
log_start() {
  echo "============================================================"
  echo "== ${0##*/}: $1"
  echo "== 開始 $(date '+%F %T') / user=$(id -un) / host=$(hostname)"
  echo "== ログ: ${LOG_FILE}"
  echo "============================================================"
  PS4='+ [$(date +%H:%M:%S)] ${BASH_SOURCE##*/}:${LINENO}: '
  set -x
}
