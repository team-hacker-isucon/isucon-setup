#!/bin/bash
# 【フォールバック】デプロイキーを「当日サーバー上で」生成・登録する。
# 基本方式は事前登録(手元で鍵を生成して repo の Deploy Keys に UI から登録 → 当日 scp。README 参照)。
# このスクリプトは事前準備を忘れた・秘密鍵を失くした場合に使う。
#
# 使い方(repo は既定で team-hacker-isucon/isucon-env):
#   GITHUB_TOKEN=<token> ./90-fallback-deploy-key.sh   # curl で API 登録まで自動
#   ./90-fallback-deploy-key.sh                        # 鍵生成・表示のみ(手動登録)
#
# GITHUB_TOKEN は登録のときだけ使う(push は SSH 鍵なのでサーバーに token を残す必要はない)。
# fine-grained PAT なら対象リポジトリ限定 + Administration: Read and write、
# classic PAT なら repo スコープが必要。token を用意しない場合は、表示される公開鍵を
# GitHub の Settings → Deploy keys に手で登録する(Allow write access にチェック)。
set -euo pipefail

REPO=${1:-team-hacker-isucon/isucon-env}

if [ ! -f ~/.ssh/id_ed25519 ]; then
  ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
fi

PUBKEY=$(cat ~/.ssh/id_ed25519.pub)
echo "== 公開鍵 =="
echo "${PUBKEY}"

if [ -n "${GITHUB_TOKEN:-}" ]; then
  if curl -fsS -X POST \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
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

echo "== 接続確認('successfully authenticated' が出れば OK)=="
ssh -o StrictHostKeyChecking=accept-new -T git@github.com || true
