# 5. ツール導入・現在の設定の取り込み

[一覧](README.md) / [前: 他台の合流](04-join-servers.md) / [復旧](06-recovery.md)

Git 化または合流が完了した各台で行う。以下は isucon ユーザーの Bash で実行する。

```bash
source "$HOME/local/manual-settings.env"
cd "$ISUCON_HOME"
git status --short
cat config.mk
```

アプリの配置・unit・ログ設定は `config.mk` を確認する。このページの環境変数も同じ値に揃える。

## 30 を単独で実行する場合

```bash
ISUCON_HOME="$ISUCON_HOME" \
NGINX_ACCESS_LOG="$NGINX_ACCESS_LOG" MYSQL_SLOW_LOG="$MYSQL_SLOW_LOG" \
  bash "$SETUP_DIR/30-install-tools.sh"
```

ホーム・DB・nginx・systemd の退避を試み、ツールとログ権限、Git・vim・tmux の設定を行う。`local/backup-*-report.txt` の `success` / `failed` / `skipped` を確認する。バックアップ失敗でもツール導入は続くため、完了表示だけで原本が保存されたと判断しない。30 は既存の `.vimrc` / `.tmux.conf` を置き換えるので、残したい設定は先に退避する。

30 自体が動かない場合や必要なツールだけ入れたい場合は、下の直接コマンドを使う。すでに必要なツールがあれば導入を省ける。

## 直接コマンド: APT のツール

```bash
sudo apt-get update
sudo apt-get install -y \
  -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
  percona-toolkit graphviz unzip vim dstat htop tmux
```

APT のロックで止まったら、表示された PID と `ps -fp <PID>` を確認し、他のインストールや更新の完了後に再実行する。ロックファイルは消さない。dpkg の中断ならエラーが指示する修復内容を確認し、`sudo dpkg --configure -a` が必要な状態か判断する。確認やサービス再起動のダイアログが出たら内容を読んで選択する。

## 直接コマンド: alp / slp

現在の30と同じバージョンを導入する。CPU アーキテクチャをファイル名に反映し、展開先を分ける。

```bash
manual_arch=$(dpkg --print-architecture)
manual_tools_dir=$(mktemp -d)
printf 'arch=%s\nwork=%s\n' "$manual_arch" "$manual_tools_dir"
wget -O "$manual_tools_dir/alp.zip" \
  "https://github.com/tkuchiki/alp/releases/download/v1.0.21/alp_linux_${manual_arch}.zip"
unzip "$manual_tools_dir/alp.zip" -d "$manual_tools_dir/alp"
sudo install -m 755 "$manual_tools_dir/alp/alp" /usr/local/bin/alp
```

各コマンドの成功を確認してから次へ進む。配布物のないアーキテクチャなら、そのバイナリは導入せず対応する配布物・ビルド方法を確認する。

```bash
wget -O "$manual_tools_dir/slp.tar.gz" \
  "https://github.com/tkuchiki/slp/releases/download/v0.2.3/slp_linux_${manual_arch}.tar.gz"
mkdir "$manual_tools_dir/slp"
tar -xzf "$manual_tools_dir/slp.tar.gz" -C "$manual_tools_dir/slp"
find "$manual_tools_dir/slp" -type f -name slp
```

表示された **1つの実ファイル** を指定して配置する。例えば展開先直下にある場合は次のようになる。

```bash
sudo install -m 755 "$manual_tools_dir/slp/slp" /usr/local/bin/slp
alp --version
slp --version
pt-query-digest --version
```

slp を導入できなくても `pt-query-digest` で slow log を解析できる。Go の古い環境では最新の `go install` が失敗することがあるため、既存の Go を入れ替える前に配布バイナリを確認する。

## 直接コマンド: ログの読み取りと Git

次は30と同じログ読み取り権限を付ける例。ローテーション後の権限は別途確認する。ログをグループや ACL で管理している環境では、その方式に合わせる。

```bash
sudo chmod a+rx "$(dirname "$NGINX_ACCESS_LOG")" "$(dirname "$MYSQL_SLOW_LOG")"
# 各ログが存在する場合だけ実行
sudo chmod a+r "$NGINX_ACCESS_LOG" "$MYSQL_SLOW_LOG"
```

この操作だけでは LTSV 出力や MySQL slow log は有効にならない。

```bash
git config --global user.name "$(hostname)"
git config --global user.email isucon@example.com
git config --global core.editor vim
git config --global pull.rebase true
```

すでに設定した identity を使うなら、変更せず `git config user.name` / `user.email` を確認する。古い Git でも、push 時に `git push -u origin "$BRANCH"` を明示すれば upstream を設定できる。vim・tmux の好みの設定や録画は初動の必須条件ではない。30 の設定を使う場合は、[スクリプト](../30-install-tools.sh) の該当箇所を確認して選ぶ。

## 現在の設定を private repo へ取り込む

**以下の ID はこの台に合わせて1つだけ実行する。** s2 の例:

```bash
cd "$ISUCON_HOME"
make set-as-s2
# s1: make set-as-s1 / s3: make set-as-s3
make check-server-id
make get-conf
git status --short
```

実設定のコピーが `s2/etc/`、ホームの `env.sh` が `s2<ホームの絶対パス>/env.sh` にできる。通常ホームなら `s2/home/isucon/env.sh` になる。既存の DB 環境変数を残したまま、ホーム直下の `env.sh` へ SERVER_ID が追記される。`get-conf` は設定をリポジトリへ読み込むだけで、サービスへ配布しない。

unit が見つからない場合は `systemctl show -p FragmentPath "$APP_SERVICE"` で実体を確認する。`/lib/systemd/system` 等にある場合は、実際の unit を該当台の `s2/etc/systemd/` へ同名でコピーする。nginx/MySQL の配置が異なる場合も、`config.mk` とコピー対象を実態に合わせる。Makefile が失敗した場合は、[直接取り込む手順](06-recovery.md#設定を直接取り込む) を使える。

s1 では [初台の共有](03-first-server.md#現設定を取り込み内容を確認して共有する) へ戻る。s2 / s3 は自分のディレクトリだけを確認して commit し、他台の push を取り込んでから push する。

```bash
# s2 の例。内容に秘密鍵や不要な認証ファイルがないことを確認してから実行
git add -- s2
git diff --cached --stat
git commit -m 'capture s2 configuration'
git pull --rebase origin "$BRANCH"
git push -u origin "$BRANCH"
```

pull 前に作業差分が残っていないか確認し、競合した場合は解消するまで push しない。ここで初動は完了。計測設定は env repo の `templates/nginx/log-ltsv.conf`・`templates/mysql/99-isucon.cnf`・`templates/go-snippets.md` と README を参照する。
