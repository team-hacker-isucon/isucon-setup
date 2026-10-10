#!/bin/bash
# チームメンバーの SSH 公開鍵(GitHub 登録済みのもの)を isucon ユーザーの
# authorized_keys に追記する(全サーバーで実行)。
#
# 置き先が isucon ユーザーなのは「以後 ssh isucon@<ip> で直接入れるようにする」ため。
# 入口が ubuntu 等の別ユーザーの環境でも、最初の1人がこれを実行すれば全員 isucon で
# 直接入れるようになる(ubuntu 側に鍵を足す必要はない)。
# isucon / ubuntu どちらのユーザーで実行してもよい(isucon 以外なら sudo で書き込む)。
set -euo pipefail

MEMBERS=(
  "Lumonde-software"
  "oshamashama"
  "ryouta-uemura"
)

ISUCON_HOME=/home/isucon
AUTH_KEYS=$ISUCON_HOME/.ssh/authorized_keys

SUDO=""
if [ "$(id -un)" != "isucon" ]; then SUDO="sudo"; fi

$SUDO install -d -m 700 -o isucon -g isucon "$ISUCON_HOME/.ssh"
$SUDO touch "$AUTH_KEYS"

for user in "${MEMBERS[@]}"; do
  echo "== $user の鍵を追加 =="
  curl -fs "https://github.com/${user}.keys" | $SUDO tee -a "$AUTH_KEYS" > /dev/null
done

$SUDO sort -u "$AUTH_KEYS" -o "$AUTH_KEYS"
$SUDO chown isucon:isucon "$AUTH_KEYS"
$SUDO chmod 600 "$AUTH_KEYS"
echo "== done. 以後は ssh isucon@<このサーバーのIP> で直接入れる =="
