#!/bin/bash
# チームメンバーの SSH 公開鍵(GitHub 登録済みのもの)を isucon ユーザーの
# authorized_keys に追記する(全サーバーで実行)。
#
# 置き先が isucon ユーザーなのは「以後 ssh isucon@<ip> で直接入れるようにする」ため。
# 保険として入口ユーザー(ubuntu 等)にも同じ鍵を入れる。sshd_config の AllowUsers 等で
# isucon への直接 ssh が拒否される環境でも、入口ユーザー経由(sudo -i -u isucon)で全員入れるように。
# 入口ユーザーは ENTRY_USER > SUDO_USER > 実行ユーザー > ubuntu の順に決める(isucon / root は除外)。
# isucon / ubuntu どちらのユーザーで実行してもよい(自分以外のユーザーへは sudo で書き込む)。
#
# 使い方:
#   ./10-add-members-keys.sh
#   ENTRY_USER=admin ./10-add-members-keys.sh   # 入口ユーザーを明示する場合
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/log.sh"
log_start "メンバーの GitHub 公開鍵を isucon と入口ユーザーの authorized_keys に追記する"

MEMBERS=(
  "Lumonde-software"
  "oshamashama"
  "ryouta-uemura"
)

ME=$(id -un)

echo "== [1/4] GitHub から公開鍵を取得 =="
KEYS_FILE=$(mktemp)
for user in "${MEMBERS[@]}"; do
  echo "== $user の鍵を取得 =="
  curl -fsS "https://github.com/${user}.keys" >> "$KEYS_FILE"
  # .keys の末尾に改行が無い場合に次の人の鍵と同じ行に繋がるのを防ぐ
  echo >> "$KEYS_FILE"
done
sed -i.bak '/^[[:space:]]*$/d' "$KEYS_FILE" && rm -f "$KEYS_FILE.bak"
if [ ! -s "$KEYS_FILE" ]; then
  echo "ERROR: 取得できた鍵が0本。MEMBERS の GitHub ユーザー名と、各自が GitHub に公開鍵を登録済みかを確認する"
  exit 1
fi
echo "== 取得した鍵: $(wc -l < "$KEYS_FILE") 本 =="

# 指定ユーザーの ~/.ssh/authorized_keys に鍵を追記し、重複を除いて権限を整える。
# 入口ユーザー向けは失敗しても続行したいので、set -e に頼らず各行で return する
SUMMARY=()
add_keys_to_user() {
  local target=$1 home group sudo="" before after
  home=$(getent passwd "$target" | cut -d: -f6) || return 1
  [ -n "$home" ] && [ -d "$home" ] || { echo "WARN: $target のホームが見つからない"; return 1; }
  group=$(id -gn "$target") || return 1
  if [ "$ME" != "$target" ]; then sudo="sudo"; fi
  $sudo install -d -m 700 -o "$target" -g "$group" "$home/.ssh" || return 1
  $sudo touch "$home/.ssh/authorized_keys" || return 1
  before=$($sudo cat "$home/.ssh/authorized_keys" | wc -l) || return 1
  $sudo tee -a "$home/.ssh/authorized_keys" < "$KEYS_FILE" > /dev/null || return 1
  $sudo sort -u "$home/.ssh/authorized_keys" -o "$home/.ssh/authorized_keys" || return 1
  $sudo chown "$target:$group" "$home/.ssh/authorized_keys" || return 1
  $sudo chmod 600 "$home/.ssh/authorized_keys" || return 1
  after=$($sudo cat "$home/.ssh/authorized_keys" | wc -l) || return 1
  SUMMARY+=("$target: authorized_keys $((after)) 本(今回の追加 $((after - before)) 本)  $home/.ssh/authorized_keys")
}

echo "== [2/4] isucon に鍵を追記 =="
add_keys_to_user isucon

echo "== [3/4] 入口ユーザーに鍵を追記(isucon 直 ssh が塞がれていた時の保険)=="
ENTRY=${ENTRY_USER:-}
if [ -z "$ENTRY" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != isucon ] && [ "$SUDO_USER" != root ]; then
  ENTRY=$SUDO_USER
fi
if [ -z "$ENTRY" ] && [ "$ME" != isucon ] && [ "$ME" != root ]; then
  ENTRY=$ME
fi
if [ -z "$ENTRY" ] && getent passwd ubuntu > /dev/null; then
  ENTRY=ubuntu
fi
if [ -z "$ENTRY" ]; then
  echo "WARN: 入口ユーザーが特定できないためスキップ(必要なら ENTRY_USER=<名前> を付けて再実行)"
elif [ "$ENTRY" = isucon ]; then
  echo "入口ユーザー = isucon のためスキップ"
elif ! getent passwd "$ENTRY" > /dev/null; then
  echo "WARN: 入口ユーザー $ENTRY が存在しないためスキップ"
elif ! add_keys_to_user "$ENTRY"; then
  echo "WARN: 入口ユーザー $ENTRY への追記に失敗(isucon 側は追記済み)"
fi

echo "== [4/4] sshd の接続制限を確認 =="
# sshd -T は実効設定を出す。-C で isucon 接続時の Match ブロックも評価させる
# (古い OpenSSH は -C に user/host/addr すべてが要る。失敗したら -C なしで再試行)
check_sshd() {
  # パターン(* 等)がカレントのファイル名に展開されないよう、この関数内だけ glob を止める
  local -
  set -f
  local conf u pat g groups hit warned=0
  conf=$(sudo sshd -T -C user=isucon,host=localhost,addr=127.0.0.1 2>/dev/null) \
    || conf=$(sudo sshd -T 2>/dev/null) \
    || { echo "WARN: sudo sshd -T に失敗(sshd_config の AllowUsers 等は手で確認する)"; return 0; }
  grep -E '^(allowusers|allowgroups|denyusers|denygroups|pubkeyauthentication|authorizedkeysfile) ' <<<"$conf" || true
  local allowusers allowgroups denyusers denygroups
  allowusers=$(awk '$1=="allowusers"{$1=""; print}' <<<"$conf" | xargs)
  allowgroups=$(awk '$1=="allowgroups"{$1=""; print}' <<<"$conf" | xargs)
  denyusers=$(awk '$1=="denyusers"{$1=""; print}' <<<"$conf" | xargs)
  denygroups=$(awk '$1=="denygroups"{$1=""; print}' <<<"$conf" | xargs)

  for u in isucon ${ENTRY:+"$ENTRY"}; do
    [ "$u" = isucon ] || getent passwd "$u" > /dev/null || continue
    groups=$(id -Gn "$u" 2>/dev/null || true)
    # パターンは user@host 形式もあり得るので @ より前だけ見る(ワイルドカードは case で一致判定)
    if [ -n "$allowusers" ]; then
      hit=0
      for pat in $allowusers; do case "$u" in ${pat%%@*}) hit=1 ;; esac; done
      [ "$hit" = 1 ] || { echo "WARN: AllowUsers ($allowusers) に $u が含まれない → $u への直接 ssh は拒否される"; warned=1; }
    fi
    for pat in $denyusers; do
      case "$u" in ${pat%%@*}) echo "WARN: DenyUsers ($denyusers) に $u が一致 → $u への直接 ssh は拒否される"; warned=1 ;; esac
    done
    if [ -n "$allowgroups" ]; then
      hit=0
      for pat in $allowgroups; do for g in $groups; do case "$g" in $pat) hit=1 ;; esac; done; done
      [ "$hit" = 1 ] || { echo "WARN: AllowGroups ($allowgroups) に $u の所属グループ ($groups) が無い → $u への直接 ssh は拒否される"; warned=1; }
    fi
    for pat in $denygroups; do
      for g in $groups; do
        case "$g" in $pat) echo "WARN: DenyGroups ($denygroups) に $u の所属グループ $g が一致 → $u への直接 ssh は拒否される"; warned=1 ;; esac
      done
    done
  done
  if grep -qx 'pubkeyauthentication no' <<<"$conf"; then
    echo "WARN: PubkeyAuthentication no → 鍵認証自体が無効"; warned=1
  fi
  if [ "$warned" = 0 ]; then
    echo "sshd の接続制限: 問題なし(isucon への直接 ssh を拒否する設定は見当たらない)"
  else
    echo "→ 拒否されるユーザーには直接入れない。入れる方のユーザーで入り、必要なら sudo -i -u isucon する"
  fi
}
# 検査は参考情報なので、失敗しても鍵の追記結果は有効なまま終える
check_sshd || echo "WARN: sshd の確認中にエラー(鍵の追記は完了している)"

rm -f "$KEYS_FILE"
{ set +x; } 2>/dev/null
echo "== サマリ =="
for line in "${SUMMARY[@]}"; do echo "  $line"; done
echo "== done. 以後は ssh isucon@<このサーバーのIP> で直接入れる(だめなら入口ユーザー経由)=="
