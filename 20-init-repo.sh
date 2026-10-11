#!/bin/bash
# /home/isucon を git 化し、競技環境管理リポジトリ(isucon-env から生成したもの)と合流させる。
# /home/isucon は空でないため clone できない。init → remote add → merge --allow-unrelated-histories で合流する。
#
# 前提: デプロイキー配置済み(事前登録した秘密鍵を ~/.ssh/id_ed25519 に scp。README 参照)
# 使い方(isucon ユーザーで、1台目のみ。2台目以降は README の合流手順):
#   ./20-init-repo.sh                       # デプロイキー方式(ssh URL)。repo は既定で team-hacker-isucon/isucon-env
#   ./20-init-repo.sh team-hacker-isucon/isucon-env https    # PAT 方式(https URL。フォールバック用)
set -euo pipefail

REPO=${1:-team-hacker-isucon/isucon-env}
PROTO=${2:-ssh}
cd /home/isucon

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
# setup リポジトリの clone(競技 repo には入れない)
/isucon-setup/
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

git add -A
git commit -m "initial server state"

if [ "$PROTO" = "https" ]; then
  git remote add origin "https://github.com/${REPO}.git"
else
  git remote add origin "git@github.com:${REPO}.git"
fi
git fetch origin
# タレ(Makefile / templates)を取り込む。README.md など同名ファイルが
# 競技ホームに既にあると衝突して止まり得るため、衝突時はテンプレ側(theirs)を優先する
git merge origin/main --allow-unrelated-histories -X theirs -m "merge isucon-env"
git push -u origin main

echo "== done. 以後は通常の add/commit/push で運用 =="
