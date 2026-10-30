# 2. メンバー公開鍵・GitHub 認証

[一覧](README.md) / [前: 準備](01-prepare.md) / [次: 初台](03-first-server.md)

個人鍵は「メンバー → サーバー」、デプロイキーは「サーバー → private GitHub repo」の認証に使う。それぞれ全台で確認する。

## サーバー: メンバーの公開鍵を追加する

isucon ユーザーの Bash で実行する。設定は [準備](01-prepare.md) で用意したものを使う。

```bash
source "$HOME/local/manual-settings.env"
ENTRY_USER="$ENTRY_USER" bash "$SETUP_DIR/10-add-members-keys.sh"
```

この処理は isucon と入口ユーザーの `authorized_keys` に公開鍵を追記し、SSH の接続制限も確認する。既存のログインセッションを残したまま、各メンバーが別の端末からログインできるか確認する。

10 が動かない場合は、各メンバーから受け取った公開鍵を、isucon ユーザーで次のように追記できる。`member.pub` はサーバーに転送した公開鍵ファイルに置き換える。

```bash
ssh-keygen -lf ./member.pub
install -d -m 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
printf '\n' >> "$HOME/.ssh/authorized_keys"
cat ./member.pub >> "$HOME/.ssh/authorized_keys"
printf '\n' >> "$HOME/.ssh/authorized_keys"
```

公開鍵が1行で完結していることと、fingerprint が本人の鍵と一致することを確認してから追加する。追記前後の改行は、既存行や公開鍵の末尾に改行がない場合に行がつながるのを防ぐ。入口ユーザーにも必要なら、そのユーザーでログインして同じ操作を行う。直接ログインが拒否される場合は入口ユーザー経由を使い、`sudo sshd -T` や sshd のログで原因を確認する。

## 手元: GitHub に登録したデプロイキーを転送する

鍵をまだ作っていない場合だけ、手元で生成する。

```sh
ssh-keygen -t ed25519 -N '' -f ./deploy_key -C isucon-deploy
```

`deploy_key.pub` を **private な isucon-env** の Settings → Deploy keys へ登録し、push するなら Allow write access を有効にする。GitHub の画面操作は自分で行う。

次はサーバーへ isucon で直接ログインできる場合の例。先に既存鍵の有無を確認する。

```sh
ssh isu1 'test ! -e ~/.ssh/id_ed25519 && test ! -L ~/.ssh/id_ed25519'
```

終了コードが 0 なら次へ進む。既存鍵があれば上書きせず、それで private repo を読めるか先に確認する。以下は一時ファイルで受け取り、既存鍵を上書きしないハードリンクで配置する。鍵の内容は画面や引数へ出さない。

```sh
ssh isu1 'umask 077; mkdir -p ~/.ssh; chmod 700 ~/.ssh;
  key_tmp=$(mktemp "$HOME/.ssh/deploy-key.XXXXXX") || exit 1
  cat > "$key_tmp" && test -s "$key_tmp" && chmod 600 "$key_tmp" &&
  ln "$key_tmp" "$HOME/.ssh/id_ed25519"
  key_rc=$?
  rm -f "$key_tmp"
  exit "$key_rc"' < ./deploy_key
```

isu2・isu3 にも同じ手順で配置する。

入口ユーザーでしか入れない場合は、まずそのアカウントで転送先を作る。次の1行目で表示された `/tmp/isucon-deploy-key.XXXXXX` の実際の名前を、以降の `ABCDEF` の箇所に入れる。

```sh
ssh isu1 'umask 077; mktemp /tmp/isucon-deploy-key.XXXXXX'
scp ./deploy_key isu1:/tmp/isucon-deploy-key.ABCDEF
ssh isu1
```

ログイン後は isucon に切り替え、Bash で配置する。途中のコマンドが失敗した場合は、一時ファイルを残して状態を確認する。

```bash
sudo -iu isucon
bash
install -d -m 700 "$HOME/.ssh"
manual_key_tmp=$(mktemp "$HOME/.ssh/deploy-key.XXXXXX")
sudo cat /tmp/isucon-deploy-key.ABCDEF > "$manual_key_tmp" &&
  test -s "$manual_key_tmp" && chmod 600 "$manual_key_tmp" &&
  ln "$manual_key_tmp" "$HOME/.ssh/id_ed25519" &&
  rm "$manual_key_tmp" && sudo rm /tmp/isucon-deploy-key.ABCDEF
```

既存鍵があれば `ln` が失敗して保持される。配置先は **isucon の実ホーム** であり、入口ユーザーの `~/.ssh` や、変更した競技 Git ルートとは区別する。

## サーバー: リポジトリへの権限を確認する

```bash
source "$HOME/local/manual-settings.env"
ssh -T git@github.com
git ls-remote "$ENV_REPO" "refs/heads/$ENV_REF"
```

初回の GitHub host key は公開されている fingerprint と照合する。`ssh -T` は認証成功でも終了コード 1 を返すので、メッセージで判断する。private repo の指定ブランチを `git ls-remote` で読めることを確認してから clone へ進む。別の鍵を使う場合は `~/.ssh/config` の GitHub 用 IdentityFile / IdentitiesOnly を設定する。
