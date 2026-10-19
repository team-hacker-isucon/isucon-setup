#!/bin/bash
# /home/isucon を git 化し、競技環境管理リポジトリ(isucon-env から生成したもの)と合流させる。
# /home/isucon は空でないため clone できない。init → remote add → merge --allow-unrelated-histories で合流する。
#
# 前提: デプロイキー配置済み(事前登録した秘密鍵を ~/.ssh/id_ed25519 に scp。README 参照)
# 使い方(isucon ユーザーで、1台目のみ。2台目以降は README の合流手順):
#   ./20-init-repo.sh                       # デプロイキー方式(ssh URL)。repo は既定で team-hacker-isucon/isucon-env
#   ./20-init-repo.sh team-hacker-isucon/isucon-env https    # PAT 方式(https URL。フォールバック用)
#
# 環境変数:
#   FORCE=1          /home/isucon/webapp が無くても続行する(想定外の構成と承知のうえで)
#   SKIP_ARCHIVE=1   git 化前の /home/isucon 丸ごとコピー(/home/isucon_archive_<時刻>)を省略する
#   KEEP_LANG=go     残す言語実装(webapp/<lang>)。カンマ区切りで複数可。既定 go
#   NO_PRUNE_LANG=1  Go 以外の言語実装の削除をしない
set -euo pipefail
# symlink 経由で実行されても lib を見つけられるよう実体のパスから辿る
SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/prune-lang.sh"
log_start "/home/isucon を git 化し、競技 repo と合流して push する(1台目のみ)"

REPO=${1:-team-hacker-isucon/isucon-env}
PROTO=${2:-ssh}
ISUCON_HOME=/home/isucon
KEEP_LANG=${KEEP_LANG:-go}
KEEP_LANG=${KEEP_LANG//[[:space:]]/}   # "go, php" のような空白入りの指定も受け付ける
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ARCHIVE_DIR=${ISUCON_HOME}_archive_${TIMESTAMP}

# --- 実行前チェック(引っかかったら何も変更せずに止める)---
echo "== [1/6] 実行前チェック =="
if [ ! -d "$ISUCON_HOME" ]; then
  echo "ERROR: $ISUCON_HOME が無い(ディレクトリでない)。競技サーバーで実行しているか確認する"
  exit 1
fi
if [ "$(id -un)" != isucon ]; then
  echo "ERROR: isucon ユーザーで実行する(今は $(id -un))。sudo -i -u isucon してから実行"
  exit 1
fi
if [ -e "$ISUCON_HOME/.git" ]; then
  echo "ERROR: $ISUCON_HOME は git 化済み。二重実行はしない"
  echo "       - 1台目で途中失敗した場合: README の「20 が途中で失敗したときの復旧」を参照(.git は消さない)"
  echo "       - 2台目以降の場合: README の合流手順を使う"
  exit 1
fi
if [ ! -d "$ISUCON_HOME/webapp" ]; then
  echo "--- ls -la $ISUCON_HOME ---"
  ls -la "$ISUCON_HOME"
  if [ "${FORCE:-}" = 1 ]; then
    echo "WARN: $ISUCON_HOME/webapp が無い(想定と違うディレクトリ構成)が FORCE=1 のため続行"
  else
    echo "ERROR: $ISUCON_HOME/webapp が無い。想定と違うディレクトリ構成なので止める"
    echo "       上の一覧を見て問題なければ FORCE=1 ./20-init-repo.sh で続行できる"
    exit 1
  fi
fi
cd "$ISUCON_HOME"

if [ "$PROTO" = "ssh" ]; then
  # 先に認証を確認(鍵の配置忘れ・登録漏れならここで止める)。
  # 注意: ssh -T git@github.com は認証成功でも exit 1 を返すため、pipefail 下で
  # パイプのまま判定すると常に失敗扱いになる。出力を変数に受けてから判定する
  AUTH_MSG=$(ssh -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 || true)
  if ! grep -q "successfully authenticated" <<<"$AUTH_MSG"; then
    echo "ERROR: GitHub の SSH 認証に失敗。デプロイキーの配置(~/.ssh/id_ed25519、chmod 600)と Deploy Keys 登録を確認する"
    echo "--- ssh の出力 ---"
    echo "$AUTH_MSG"
    exit 1
  fi
fi

# --- git 化の前に丸ごとアーカイブ ---
# .gitignore の作成や merge -X theirs(README.md / Makefile 等の上書き)より前に取る。
# 競技中に「初期状態のあのファイル」を見たくなった時の原本(git に入らない ignore 対象も含む)
echo "== [2/6] $ISUCON_HOME を丸ごとアーカイブ =="
if [ "${SKIP_ARCHIVE:-}" = 1 ]; then
  echo "SKIP_ARCHIVE=1 のためアーカイブを省略"
  ARCHIVE_DIR="(省略)"
else
  df -h /home
  NEED_KB=$(sudo du -sk "$ISUCON_HOME" 2>/dev/null | awk '{print $1}' || true)
  AVAIL_KB=$(df -Pk /home | awk 'NR==2 {print $4}' || true)
  if [ -z "$NEED_KB" ] || [ -z "$AVAIL_KB" ]; then
    echo "ERROR: $ISUCON_HOME のサイズか /home の空き容量を取得できない(容量チェックができないので止める)。何も変更していない"
    echo "       手元バックアップ(00-local-backup.sh)を取ったうえで SKIP_ARCHIVE=1 ./20-init-repo.sh で続行できる"
    exit 1
  fi
  echo "サイズ: $((NEED_KB / 1024)) MB / /home の空き: $((AVAIL_KB / 1024)) MB"
  # アーカイブは競技中ずっと残り、mysql やログと同じ fs のことが多い。
  # 途中や競技中にディスクが埋まると競技そのものが壊れるので、余裕(+5GB)が無ければ止める
  if [ $((NEED_KB + 5 * 1024 * 1024)) -gt "$AVAIL_KB" ]; then
    echo "ERROR: 空き容量不足の恐れ(必要 $((NEED_KB / 1024))MB + 余裕 5GB > 空き $((AVAIL_KB / 1024))MB)。何も変更していない"
    echo "       手元バックアップ(00-local-backup.sh)を取ったうえで SKIP_ARCHIVE=1 ./20-init-repo.sh で続行できる"
    exit 1
  fi
  # 失敗・Ctrl-C で中途半端なアーカイブが残ると「取れている」と誤解し、容量も食うので消す
  _abort_archive() {
    echo "中断: 作りかけのアーカイブ $ARCHIVE_DIR を削除する"
    sudo rm -rf -- "$ARCHIVE_DIR"
    exit 130
  }
  trap _abort_archive INT TERM
  if ! sudo cp -a "$ISUCON_HOME" "$ARCHIVE_DIR"; then
    echo "ERROR: アーカイブのコピーに失敗。作りかけの $ARCHIVE_DIR を削除して止める(git 化はまだしていない)"
    sudo rm -rf -- "$ARCHIVE_DIR"
    exit 1
  fi
  trap - INT TERM
  sudo du -sh "$ARCHIVE_DIR" || true
fi

echo "== [3/6] git init + initial commit(サーバー初期状態のまま。全言語を含む)=="
LOG_ERR_HINT="まだ何も push していない。原因を直してから
rm -rf $ISUCON_HOME/.git $ISUCON_HOME/.gitignore して再実行してよい"
git init -b main
# fresh なサーバーは git の identity 未設定で commit に失敗するため先に設定しておく
git config --global user.email isucon@example.com
git config --global user.name "$(hostname)"

cat > .gitignore <<'EOF'
*.log
logs/
# ビルド成果物・巨大な初期データは push しない(必要なら個別に外す)
*.tar.gz
*.sql.gz
node_modules/
# ホーム直下の秘匿物・ゴミ(デプロイ秘密鍵を絶対に push しない)。
# 先頭 / でリポジトリ直下(/home/isucon)のみ ignore(webapp/go 等を巻き込まない)
/.ssh/
/.cache/
/.config/
/.bash_history
/go/
# 平文の認証情報(credential.helper store の PAT・mysql のパスワード)
/.git-credentials
/.my.cnf
# 言語ツールチェーン・パッケージのキャッシュ(巨大で、サーバーごとに入れ直せる)
/.cargo/
/.rustup/
/.npm/
/.local/
# setup リポジトリの clone とその実行ログ(競技 repo には入れない)
/isucon-setup/
/isucon-setup-logs/
# ホーム直下の作業ノイズ・シェル設定(30-install-tools.sh が各台で同じものを作るので共有不要)。
# .gitconfig は user.name がサーバーごとに違う(hostname)ので共有すると識別が壊れる
/.gitconfig
/.bashrc
/.profile
/.vimrc
/.viminfo
/.lesshst
/.mysql_history
/.wget-hsts
/.sudo_as_admin_successful
/.selected_editor
# pprotein が cwd(/home/isucon)に作る収集データ
/data/
# SERVER_ID 宣言(make set-as-s1 が書く。中身がサーバーごとに違うので共有しない。
# s1/home/isucon/env.sh の方は git 管理する)
/env.sh
# バックアップ(30-install-tools.sh)・解析結果(make analyze)・プロファイル(make pprof-record)
local/
analysis/
pprof/
EOF

# GitHub は 100MB 超のファイルを拒否する。最後の push だけが失敗すると再実行もできなくなるので、
# 何も commit していない今のうちに検査する(50MB 超は警告対象にもなるので止める)
BIG_FILES=$(git ls-files -o --exclude-standard -z | xargs -0 -r du -k -- | awk '$1 > 50 * 1024' || true)
if [ -n "$BIG_FILES" ]; then
  echo "ERROR: 50MB を超えるファイルが commit 対象に入っている(サイズは KB)"
  echo "$BIG_FILES"
  # まだ commit していないので、作ったばかりの .git と .gitignore を消せば実行前の状態に戻る
  rm -rf .git .gitignore
  echo "       .git / .gitignore を消して実行前の状態に戻した(元のファイルはアーカイブにある)"
  echo "       上のファイルを 20-init-repo.sh の .gitignore に追加する・移動するなど手で対処してから再実行する"
  exit 1
fi

git add -A
git commit -m "initial server state"
INITIAL_COMMIT=$(git rev-parse --short HEAD)

# --- 使わない言語実装を消す(別 commit。initial commit には全言語が残る)---
# 戻すときは: git checkout <initial commit> -- webapp/<lang>
echo "== [4/6] 使わない言語実装を削除(残す: $KEEP_LANG)=="
# ここから先の失敗では .git を消して再実行しない(git rm 済みの言語は initial commit にしか残っていない)
REMOTE_URL="git@github.com:${REPO}.git"
if [ "$PROTO" = "https" ]; then REMOTE_URL="https://github.com/${REPO}.git"; fi
LOG_ERR_HINT=".git は消さない(消すと削除済みの言語実装が initial commit ごと失われる)。原因を直してから:
cd $ISUCON_HOME
git status                    # 言語削除が未 commit なら: git commit -m 'remove non-${KEEP_LANG} implementations'
git remote -v                 # origin が無ければ: git remote add origin $REMOTE_URL
git fetch origin
git merge origin/main --allow-unrelated-histories -X theirs -m 'merge isucon-env'   # merge 済みなら不要
git push -u origin main"
PRUNED=()
if [ "${NO_PRUNE_LANG:-}" = 1 ]; then
  echo "NO_PRUNE_LANG=1 のため削除しない"
elif [ ! -d webapp ]; then
  echo "webapp が無いため削除しない"
elif [ ! -d "webapp/${KEEP_LANG%%,*}" ]; then
  # 残すはずの実装が見当たらない構成で消すと全実装が無くなるので、何もしない
  echo "WARN: webapp/${KEEP_LANG%%,*} が無いため削除しない(KEEP_LANG を確認)"
  ls -la webapp
else
  for lang in $(list_prune_targets webapp "$KEEP_LANG"); do
    # ignore 対象(node_modules 等)しか無いディレクトリは git rm できないので対象外
    if [ -n "$(git ls-files -- "webapp/$lang")" ]; then PRUNED+=("$lang"); fi
  done
  if [ "${#PRUNED[@]}" -eq 0 ]; then
    echo "削除対象なし"
  else
    echo "削除対象: ${PRUNED[*]/#/webapp/}"
    for lang in "${PRUNED[@]}"; do
      git rm -r -q -- "webapp/$lang"
    done
    git commit -m "remove non-${KEEP_LANG} implementations (initial commit keeps all)"
  fi
fi

echo "== [5/6] 競技 repo(${REPO})と合流 =="
git remote add origin "$REMOTE_URL"
git fetch origin
# タレ(Makefile / templates)を取り込む。README.md など同名ファイルが
# 競技ホームに既にあると衝突して止まり得るため、衝突時はテンプレ側(theirs)を優先する
git merge origin/main --allow-unrelated-histories -X theirs -m "merge isucon-env"

echo "== [6/6] push =="
git push -u origin main

{ set +x; } 2>/dev/null
echo "== サマリ =="
echo "  アーカイブ:      $ARCHIVE_DIR"
if [ "${SKIP_ARCHIVE:-}" != 1 ]; then
  echo "                   (不要になったら: sudo rm -rf $ARCHIVE_DIR)"
fi
echo "  initial commit:  $INITIAL_COMMIT(全言語入りの初期状態)"
if [ "${#PRUNED[@]}" -gt 0 ]; then
  echo "  削除した言語:    ${PRUNED[*]}(戻す: git checkout $INITIAL_COMMIT -- webapp/<lang>)"
fi
echo "== done. 以後は通常の add/commit/push で運用 =="
