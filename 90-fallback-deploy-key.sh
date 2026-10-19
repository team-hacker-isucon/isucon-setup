#!/bin/bash
# 【フォールバック】デプロイキーを「当日サーバー上で」生成・登録する。
# 基本方式は事前登録(手元で鍵を生成して repo の Deploy Keys に UI から登録 → 当日 scp。README 参照)。
# このスクリプトは事前準備を忘れた・秘密鍵を失くした場合に使う。
#
# 使い方(repo は既定で team-hacker-isucon/isucon-env):
#   ./90-fallback-deploy-key.sh   # GITHUB_TOKEN を聞かれるので貼り付け → curl で API 登録まで自動
#                                 # 空のまま Enter なら鍵生成・表示のみ(手動登録)
# token はコマンドラインに書かない(GITHUB_TOKEN=... ./90... だと ~/.bash_history に残る)。
# 環境変数 GITHUB_TOKEN が既にあればそれを使い、入力は求めない
#
# GITHUB_TOKEN は登録のときだけ使う(push は SSH 鍵なのでサーバーに token を残す必要はない)。
# fine-grained PAT なら対象リポジトリ限定 + Administration: Read and write、
# classic PAT なら repo スコープが必要。token を用意しない場合は、表示される公開鍵を
# GitHub の Settings → Deploy keys に手で登録する(Allow write access にチェック)。
set -euo pipefail
# symlink 経由で実行されても lib を見つけられるよう実体のパスから辿る
SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
source "$SCRIPT_DIR/lib/log.sh"
log_start "デプロイキーを当日生成し、(token を入力すれば)GitHub に登録する"

REPO=${1:-team-hacker-isucon/isucon-env}

echo "== [1/3] 鍵の生成 =="
if [ ! -f ~/.ssh/id_ed25519 ]; then
  ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
fi

PUBKEY=$(cat ~/.ssh/id_ed25519.pub)
echo "== 公開鍵 =="
echo "${PUBKEY}"

echo "== [2/3] Deploy key の登録 =="
# token が set -x のトレース(= 画面とログファイル)に展開されて残らないよう、
# GITHUB_TOKEN を参照する区間はトレースを止める
{ set +x; } 2>/dev/null
if [ -z "${GITHUB_TOKEN:-}" ] && [ -t 0 ]; then
  read -rsp 'GITHUB_TOKEN(空なら手動登録): ' GITHUB_TOKEN || GITHUB_TOKEN=""
  echo
fi
if [ -n "${GITHUB_TOKEN:-}" ]; then
  # ヘッダはファイル(プロセス置換)経由で渡す。引数に書くと ps で他ユーザーからも見える
  if curl -fsS -X POST \
    -H @<(printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN") \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${REPO}/keys" \
    -d "{\"title\":\"$(hostname)\",\"key\":\"${PUBKEY}\",\"read_only\":false}"; then
    echo "== Deploy key を登録した =="
  else
    echo "== 登録失敗(token の権限・期限・repo 名を確認)。上の公開鍵を Deploy keys に手動登録してください =="
  fi
else
  echo "== GITHUB_TOKEN 未設定のため自動登録をスキップ。上の公開鍵を Deploy keys に手動登録してください =="
fi
unset GITHUB_TOKEN
set -x

echo "== [3/3] 接続確認('successfully authenticated' が出れば OK)=="
ssh -o StrictHostKeyChecking=accept-new -T git@github.com || true
