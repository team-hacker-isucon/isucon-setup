# 1. SSH・バックアップ・作業設定

[一覧](README.md) / [次: 鍵](02-keys.md)

## 手元: 接続を確認する

[ssh_config.example](../ssh_config.example) を参考に `~/.ssh/config` に `isu1` / `isu2` / `isu3` を設定し、IP・User・必要なら IdentityFile を埋める。`isu1` が s1、`isu2` が s2、`isu3` が s3 に対応する。最初は ubuntu 等でしか入れない場合、その User を指定する。

```sh
ssh isu1 'id; hostname; command -v bash git; sudo -n true'
ssh isu2 'id; hostname; command -v bash git; sudo -n true'
ssh isu3 'id; hostname; command -v bash git; sudo -n true'
```

sudo の認証が必要なら、まず対話ログインして使える方法を確認する。一括実行は非対話 sudo が必要だが、手動手順はログイン後に必要な箇所で認証できる。SSH の host key が変わった場合は、接続先と正しい fingerprint を確認する。

## 手元: 変更前の状態を保存する

以下は **手元の isucon-setup clone のルート** で実行する。

```sh
bash ./00-local-backup.sh isu1 isu2 isu3
# ホームが異なる場合:
# REMOTE_HOME=/srv/isucon bash ./00-local-backup.sh isu1 isu2 isu3
```

`backup/` にホーム全体と `/etc/nginx`・`/etc/mysql`・`/etc/systemd/system` のアーカイブができる。WARN も確認する。gzip として開けても、読み取り失敗で欠けたファイルがある場合は部分バックアップである。稼働中の DB の整合性は、この tar では保証しない。

00 が使えない場合は、1台ずつ直接取得する。次はホームが `/home/isucon`、非対話 sudo が使える環境の例。別ホームの場合は `-C /home isucon` を実際の親ディレクトリと名前に変更する。

```sh
umask 077
manual_backup_dir=$(mktemp -d "${TMPDIR:-/tmp}/isucon-manual-backup.XXXXXX")
echo "$manual_backup_dir"
ssh isu1 'sudo -n tar -czf - -C /home isucon' \
  > "$manual_backup_dir/isu1-home.tar.gz.partial" &&
  gzip -t "$manual_backup_dir/isu1-home.tar.gz.partial" &&
  mv "$manual_backup_dir/isu1-home.tar.gz.partial" "$manual_backup_dir/isu1-home.tar.gz"
```

終了コードが 0 のときだけ完成名にする。失敗時の `.partial` は残し、エラーに出たファイル・権限・空き容量を確認する。`echo` で表示した保存先を控え、後でバックアップ用の保管先へ移す。次の例は3つの設定ディレクトリが存在する場合。存在しないものは、接続先で確認して引数から外す。

```sh
ssh isu1 'sudo -n tar -czf - -C / etc/nginx etc/mysql etc/systemd/system' \
  > "$manual_backup_dir/isu1-etc.tar.gz.partial" &&
  gzip -t "$manual_backup_dir/isu1-etc.tar.gz.partial" &&
  mv "$manual_backup_dir/isu1-etc.tar.gz.partial" "$manual_backup_dir/isu1-etc.tar.gz"
```

非対話 sudo が使えない場合は、対話ログイン後に容量を確認し、ホームの外へ権限 700 の新規ディレクトリを作る。例: `sudo mktemp -d /var/tmp/isucon-original.XXXXXX` で表示された場所を保存先にし、`sudo cp -a /home/isucon <保存先>/home` を実行する。サーバー内だけのコピーなので、取り出して保管するまではそのサーバーの障害で失われる。

## 全サーバー: 作業ユーザーと設定を用意する

各台にログインする。入口が ubuntu 等なら、その中で `sudo -iu isucon` を実行する。すでに isucon なら切り替えは不要。

```sh
id -un
# isucon であることを確認してから Bash に入る
bash
```

まず配置を確認する。`APP_DIR` は Go の `go.mod` がある場所、`APP_SERVICE` は実際にアプリを起動している unit 名に合わせる。

```bash
pwd
ls -la /home/isucon
find /home/isucon -maxdepth 5 -name go.mod -type f
systemctl list-units --type=service --all --no-pager
```

setup clone がまだなければ取得する。既存の clone は `git -C <場所> status` と `remote -v` を確認して使い、自動で上書きしない。以下は通常ホームの例で、以降の配置を変える場合は設定内の `ISUCON_HOME` / `SETUP_DIR` / `ENV_DIR` も揃える。

```bash
git clone https://github.com/team-hacker-isucon/isucon-setup.git "$HOME/isucon-setup"
install -d -m 700 "$HOME/local"
test ! -e "$HOME/local/manual-settings.env" &&
  cp "$HOME/isucon-setup/manual/server.env.example" "$HOME/local/manual-settings.env"
vim "$HOME/local/manual-settings.env"
```

この設定は Bash として実行されるため、自分で内容を確認する。既存の設定がある場合はコピーせず、その内容を確認する。秘密鍵やパスワードは書かない。アプリがホーム直下なら `APP_DIR=.`、別の場所ならホームからの相対パスを使う。

```bash
source "$HOME/local/manual-settings.env"
test "$(id -un)" = isucon
test -d "$ISUCON_HOME"
test -f "$ISUCON_HOME/$APP_DIR/go.mod"
systemctl cat "$APP_SERVICE"
```

パス・unit 名・成果物名は英数字と `_./:@+-` の範囲にする。`.gitignore` の追加指定 `EXTRA_IGNORES` は、ホームからの相対パターン。例の `xbuild/` が不要なら `EXTRA_IGNORES=()` に変える。`go/` や `data/` をまとめて除外するとアプリ本体や原本も対象外になるため、内容を見て必要なパスだけを指定する。
