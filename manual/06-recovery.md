# 6. 途中停止からの復旧と Git の手作業

[一覧](README.md)

まず失敗したコマンドと対象サーバーを特定する。ホーム直下と入れ子の `.git`、原本、バックアップを残す。初期化や合流の途中停止は、最初から実行し直す前に、どこまで進んだか確認する。

## 現在の状態を調べる

isucon ユーザーの Bash で実行する。

```bash
source "$HOME/local/manual-settings.env"
cd "$ISUCON_HOME"
ls -ld .git
git status --short
git log --oneline -5
git remote -v
git ls-files --stage | awk '$1 == "160000" { print }'
```

`.git` がない場合や、まだコミットしていない場合のエラーも状態を示す情報になる。親の repo を表示していないか `git rev-parse --show-toplevel` も確認する。レポートが存在する場合は次を読む。

```bash
test ! -f .git/info/isucon-init-report.txt || cat .git/info/isucon-init-report.txt
test ! -f .git/info/isucon-join-report.txt || cat .git/info/isucon-join-report.txt
test ! -f .git/info/isucon-join-collisions.txt || cat .git/info/isucon-join-collisions.txt
```

| 状態 | 次の作業 |
| --- | --- |
| `.git` がない | 初台は [3](03-first-server.md)、他台は [4](04-join-servers.md) |
| 初台で、HEAD がなく index に mode 160000 がある | 下の入れ子 Git の扱いを決め、初期コミットから続ける |
| `initial server state` があり、テンプレート未合流 | 下のテンプレート合流から続ける |
| テンプレート合流済みで `config.mk` が未作成 | 下の config.mk 作成から続ける |
| Git 化と `config.mk` が完成 | [5](05-tools-and-config.md) から再開。必要なら `setup.sh --mode existing` |
| join が fetch や衝突確認で停止 | 下の join の復旧を使う。初台用の初期コミットは作らない |

## Git を手作業で進める

ここは **初台専用**。`init-repo.sh` を使えない場合の代替と、初期化途中からの続きを示す。helper と異なり、追加除外や成果物名の衝突を自分で確認する必要がある。先に [1](01-prepare.md) のバックアップを成功させ、[2](02-keys.md) の GitHub 認証と [3](03-first-server.md) の env clone を用意する。

### 未初期化のときだけ Git を作る

すでにホーム直下の `.git` がある場合はこのブロックを飛ばす。`git init -b` に対応しない古い Git でも、次の2つのコマンドで main 等の指定ブランチを作れる。

```bash
cd "$ISUCON_HOME"
git init
git symbolic-ref HEAD "refs/heads/$BRANCH"
git config user.name "$(hostname)"
git config user.email isucon@example.com
git remote add origin "$REMOTE"
```

### 除外を設定し、初期コミットを作る

既存の `.gitignore` がある場合も内容を残す。`.gitignore` と `config.mk` がシンボリックリンクなら、この操作を進めずリンク先と扱いを確認する。テンプレートの既定除外に、今回必要なパスを追加する。

```bash
cd "$ISUCON_HOME"
printf '\n' >> .gitignore
git -C "$ENV_DIR" show HEAD:.gitignore >> .gitignore
for pattern in "${EXTRA_IGNORES[@]}"; do
  printf '/%s\n' "$pattern" >> .gitignore
done
vim .gitignore
```

実行元 clone の場所を変えた場合は、ホームからの相対パスを除外する。既定名の `/isucon-setup/`・`/isucon-env/`・`/local/`・`/.ssh/` はテンプレートに含まれる。アプリの成果物も、例えば `/isucari/webapp/go/isuapp` のように追加する。成果物名が既存ソース・設定と一致している場合は、除外する前に `APP_BIN` を変更する。

次は未追跡候補から ELF・大容量ファイル・Python 仮想環境の設定を探す **表示専用** のコマンド。表示されたパスを確認して `.gitignore` に追加する。`pyvenv.cfg` はファイルだけでなく、それが属する仮想環境ディレクトリを除外する。`MAX_FILE_SIZE_MIB` は設定例の既定値で 50。

```bash
while IFS= read -r -d '' candidate; do
  test -f "$candidate" && test ! -L "$candidate" || continue
  case "$candidate" in
    */pyvenv.cfg) printf 'Python environment: %s\n' "${candidate%/pyvenv.cfg}" ;;
  esac
  if [[ "$(head -c 4 < "$candidate" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ]]; then
    printf 'ELF: %s\n' "$candidate"
  elif [[ $(wc -c < "$candidate") -gt $((MAX_FILE_SIZE_MIB * 1024 * 1024)) ]]; then
    printf 'Large: %s\n' "$candidate"
  fi
done < <(git ls-files -o --exclude-standard -z -- .)
vim .gitignore
```

入れ子の Git があるか、候補をプレビューしてから index に追加する。既存 repo の `.git` は消さない。

```bash
git add --dry-run -A
git add -A
git ls-files --stage | awk '$1 == "160000" { print }'
git diff --cached --stat
```

mode 160000 が出た場合はまだ commit しない。例えば、原本を残して除外するツール clone が `xbuild` なら次のように扱う。

```bash
# xbuild が本当に除外するツール clone であると確認した場合だけ実行
git rm --cached -- xbuild
printf '\n/xbuild/\n' >> .gitignore
git add -- .gitignore
```

`--cached` により作業ファイルは残る。削除を拒否された場合は `-f` を追加せず、index と作業ファイルの差分を確認する。アプリ自体が入れ子の Git なら、ツールと同じように除外せず、どの repo を正本にするか先に決める。

初期化 helper がすでに追加・除外した状態から再開する場合も、index と除外を確認する。まだ HEAD がないこと、mode 160000 と不要な機密ファイルがないことを確認して、初期コミットを作る。

```bash
git diff --cached --stat
git commit -m 'initial server state'
```

### テンプレート履歴を合流する

`initial server state` から再開する場合もここを使う。`git status` に作業差分や未解決の merge があるときは先に解消する。ホームに合わせた除外設定を Git metadata 内へ退避し、ローカル clone の履歴を取得する。

```bash
cp .gitignore .git/info/manual-home.gitignore
git fetch --no-tags "$ENV_DIR" HEAD
git merge --allow-unrelated-histories -X theirs FETCH_HEAD -m 'merge isucon-env template'
```

同名ファイルが競合するとテンプレート側を優先する。`Makefile` / `README.md` 等の原本は `initial server state` コミットから確認できる。merge が失敗した場合は `git status` で衝突ファイルを確認し、解消・commit してから次へ進む。テンプレート側の内容を使う前提を変えたい場合は、この merge 前に方針を決める。

### config.mk を作成する

ここはテンプレート合流後に実行する。helper の途中から再開する場合、元の除外は `.git/info/isucon-home.gitignore`、上の手動手順なら `.git/info/manual-home.gitignore` にある。該当する1つを使って `.gitignore` を復元する。

```bash
# 上の手動手順から続ける場合
cp .git/info/manual-home.gitignore .gitignore
# helper から復旧する場合は、代わりに次を使う:
# cp .git/info/isucon-home.gitignore .gitignore
```

すでに正しい `config.mk` がある場合は上書きしない。作成する場合は、`APP_DIR` がホームからの相対パスであることと、下の変数が英数字・`_./:@+-` だけで構成されることを確認する。アプリがホーム直下なら `APP_DIR=.` を使う。

```bash
manual_app_abs=$(cd "$ISUCON_HOME/$APP_DIR" && pwd -P)
cat > config.mk <<EOF
ISUCON_HOME := $ISUCON_HOME
APP_DIR := $manual_app_abs
APP_SERVICE := $APP_SERVICE
APP_BIN := $APP_BIN
MYSQL_CONF_DIR := $MYSQL_CONF_DIR
NGINX_ACCESS_LOG := $NGINX_ACCESS_LOG
MYSQL_SLOW_LOG := $MYSQL_SLOW_LOG
EOF
git add -- .gitignore config.mk
git diff --cached --stat
git commit -m 'configure competition home'
```

`APP_BIN` が原本・テンプレート・追跡ファイルに重ならないか再確認する。[3 の結果確認](03-first-server.md#結果を確認する) へ戻り、必要なファイルが追跡されていることを確認してから [5](05-tools-and-config.md) へ進む。手動初期化では helper 専用のレポートは作られないため、存在するファイルだけを確認する。

## 原本を取り出す

ホーム内に上書きして展開する前に、別の新規ディレクトリへ取り出して比較する。次は手元の tar から復旧候補を取り出す例。アーカイブ名を実際のものに置き換える。

```sh
umask 077
manual_restore_dir=$(mktemp -d "${TMPDIR:-/tmp}/isucon-restore.XXXXXX")
tar -xzf ./backup/isu1-日時-home-isucon.tar.gz -C "$manual_restore_dir"
echo "$manual_restore_dir"
```

helper のサーバー内アーカイブなら、レポートの `archive_status=success` を確認したうえで `<archive_path>/home/` を参照する。失敗したコピーや部分 tar は原本全体の代わりにはならない。初期状態で追跡したファイルは、そのコミットから別ファイルへ取り出せる。

```bash
git log --oneline --all
# 表示された initial server state のコミット ID を使う
# git show <コミットID>:Makefile > "$HOME/local/original-Makefile"
```

必要なファイルだけを比較し、置き換える場合は現在のファイルも退避してから戻す。

## join の途中停止

`.git/info/isucon-join-report.txt` の `join_status` と `archive_status`、`isucon-join-collisions.txt` を確認する。展開前は branch がまだ存在しない場合もある。

- **fetch 失敗**: SSH・URL・ブランチを直し、`git fetch --no-tags origin "refs/heads/$BRANCH"` で取得を確認する。ここではまだ共有ファイルを展開しない。
- **バックアップ不足で衝突**: ホームの外に新規の保存先を用意し、原本を `cp -a` などで保存する。コピー完了を確認するまで置き換えない。
- **ファイル・ディレクトリ・symlink の構造衝突**: 指摘されたパスと共有側の構造を比較する。既存パスの移動はサービスの参照先に影響する場合もあるため、動作中のアプリとの関係を確認して決める。

helper を再開できない場合は、別の新規ディレクトリに共有 branch を clone し、衝突したファイルを比較できる。

```bash
manual_compare_root=$(mktemp -d)
git clone --branch "$BRANCH" "$REMOTE" "$manual_compare_root/shared"
git -C "$manual_compare_root/shared" log -1 --oneline
# 衝突した相対パスを指定する例
diff -u "$ISUCON_HOME/Makefile" "$manual_compare_root/shared/Makefile"
```

展開前に停止したこと、既存ファイルと `.git` を完全に退避できたことを確認したうえで、**この失敗した join が作成した未コミットのホーム直下 `.git` だけ**を退避先へ移動すれば、ホームの再バックアップを伴う [4](04-join-servers.md) を再実行できる。コミット済み、展開済み、または状態が不明ならこの方法は使わず、原本と共有ファイルを比較して復旧する。入れ子の `.git` は移動・削除しない。

## 設定を直接取り込む

`make get-conf` が配置の違いなどで止まった場合、実ファイルを確認してコピーする。以下は s2、標準の nginx/MySQL 配置を使う例。作業先が private なホームの Git ルートであることを確認する。

```bash
cd "$ISUCON_HOME"
manual_server_id=s2
mkdir -p "$manual_server_id/etc/nginx" "$manual_server_id/etc/mysql" \
  "$manual_server_id/etc/systemd" "$manual_server_id$ISUCON_HOME"
sudo cp -a /etc/nginx/. "$manual_server_id/etc/nginx/"
sudo cp -a "$MYSQL_CONF_DIR/." "$manual_server_id/etc/mysql/"
systemctl show -p FragmentPath "$APP_SERVICE"
```

表示された unit の実ファイルを、同じサービス名で保存する。例:

```bash
sudo cp /lib/systemd/system/isuapp.go.service "$manual_server_id/etc/systemd/$APP_SERVICE"
test ! -f "$ISUCON_HOME/env.sh" || cp "$ISUCON_HOME/env.sh" "$manual_server_id$ISUCON_HOME/env.sh"
sudo chown -R "$(id -un):$(id -gn)" "$manual_server_id"
rm -f "$manual_server_id/etc/mysql/debian.cnf"
git status --short
```

`debian.cnf` は管理用パスワードを含むためコピー側から除く。他の認証ファイルや証明書鍵が設定ディレクトリにある場合も、コピーを確認して commit 対象を選ぶ。SERVER_ID は [5](05-tools-and-config.md) の `make set-as-s2` 等で設定する。Makefile 自体を使えない場合はホームの `env.sh` を編集し、既存の DB 変数を保ったまま単独の `SERVER_ID=s2` 行を1行だけ設定してから、上の env.sh のコピーを行う。

## よくある停止点

| エラー・状況 | 確認と対処 |
| --- | --- |
| `unknown switch 'b'` | `git init -b main` を使わず、未初期化のホームで `git init` → `git symbolic-ref HEAD refs/heads/main` |
| `/dev/fd/63: Operation not permitted` | ログ処理の process substitution が環境の制限で使えない場合がある。10 は [2](02-keys.md)、30 は [5](05-tools-and-config.md) の直接コマンドで進める |
| APT のロック | 所有 PID を確認し、処理完了を待つ。ロックファイルを削除しない |
| `Permission denied (publickey)` | 入口ログイン用の個人鍵と GitHub 用デプロイキーを区別し、所有者・権限・GitHub の登録先を確認 |
| push の切断・タイムアウト | 履歴を残して下の確認を行う。切断だけで原因や反映状況を決めない |

push 後に接続が切れた場合は、ローカルとリモートのコミット ID を比較する。

```bash
git rev-parse "$BRANCH"
git ls-remote origin "refs/heads/$BRANCH"
git status --short
```

一致していれば、そのコミットはリモートに反映されている。異なる場合は接続・共有先・他メンバーの更新を確認して再試行する。大容量の object が過去のコミットに入っている場合、現在の `.gitignore` を変えても履歴は小さくならない。共有済みかを調べてから整理方法を決め、force push や履歴削除で対処しない。
