# isucon-setup

ISUCON 当日の初動(鍵・git 化・ツール導入)スクリプト集。**大会に依存しない内容だけ**を置き、public リポジトリとして運用する(→ サーバーから認証なしで clone できる)。

⚠️ **競技コード・競技固有の情報は絶対にここに入れない**(public のため。入れると失格リスク)。

競技リポジトリは2つに分かれている:

| リポジトリ | 役割 | 可視性 |
| --- | --- | --- |
| **isucon-setup**(これ) | 初動スクリプト。サーバーに最初に clone するもの | public |
| **isucon-env** | 問題環境の git 管理(etc 取り込み/配布・build・解析の Makefile)。**今回の競技 repo そのもの**で、当日 /home/isucon に合流させる | **private** |

## 鍵の整理(2種類を混同しない)

### 1. 個人鍵(メンバー → サーバー)

- 競技サーバーの作業ユーザーは `isucon`。**メンバー全員の GitHub 公開鍵を isucon ユーザーの authorized_keys に追記**し、以後は全員 `ssh isucon@<ip>` で直接入る
- 入口が `ubuntu` 等の別ユーザーの環境(EC2 素の構成や multipass)では、ポータル/クラウドが配置した鍵で最初の1人だけが入れる。その1人が `sudo -i -u isucon` してこのリポジトリを clone し、`10-add-members-keys.sh` を実行すれば、**以後は全員 isucon 直ログイン**になる
- 10 は保険として**入口ユーザー(ubuntu 等)にも同じ鍵を入れる**。sshd_config の `AllowUsers` / `AllowGroups` / `DenyUsers` 等で isucon への直接 ssh が拒否される環境でも、全員が入口ユーザー経由(`ssh ubuntu@<ip>` → `sudo -i -u isucon`)で入れるように
  - 入口ユーザーは `ENTRY_USER` > `SUDO_USER`(`sudo -i -u isucon` 経由ならここに入る)> 実行ユーザー > `ubuntu` の順に決める(isucon / root は `ENTRY_USER` で指定しても除外。見つからなければ WARN を出してスキップ)
  - 10 は `sudo sshd -T -C user=<ユーザー>,...` でユーザーごとの実効設定(Match ブロック込み)を見て、isucon / 入口ユーザーが拒否され得る設定があれば WARN を出す。WARN が出たら拒否されない方のユーザーで入る
- 近年の ISUCON 本番(11〜14)はポータルに登録した公開鍵が cloud-init で isucon に配置されるので、最初から isucon 直ログインできることが多い

### 2. デプロイキー(サーバー → GitHub)

- **基本方式: 事前登録**。手元で鍵ペアを**1本**生成し、isucon-env の Settings → Deploy keys に **UI から事前登録**しておく(Allow write access にチェック)。当日は同じ秘密鍵を3台に scp するだけ
- 一般原則では「サーバーごとに鍵を分ける」(侵害時にその1台分だけ失効できる)が、単回利用・競技後に鍵自体を削除する今回の運用では分離の利点が薄いため、1本共用で簡素化している
- もしもの時(事前準備を忘れた・鍵を失くした)は `90-fallback-deploy-key.sh` で当日生成して登録する(後述)
- 方針: **gh など特定目的のツールは入れない**。GitHub API の操作が要る場合も curl で行う

## 事前準備(前日まで)

```sh
# 1. isucon-env(= 今回の競技 repo)にメンバー全員を Collaborator として招待する

# 2. 手元でデプロイキーを1本生成(3台で同じ鍵を共用)
ssh-keygen -t ed25519 -N "" -f ./deploy_key -C "isucon-deploy"

# 3. deploy_key.pub を isucon-env の Settings → Deploy keys に UI から登録(Allow write access にチェック)
#    秘密鍵(deploy_key)は手元に保管。リポジトリにコミットしない・チャットに貼らない

# 4. ssh_config.example を各自の ~/.ssh/config に追記(IP は当日埋める)
#    手元の作業ディレクトリ(このリポジトリの clone)で 00-local-backup.sh を使う。backup/ は git 管理しない(.gitignore 済み)
#    ※ 10-add-members-keys.sh の MEMBERS は記入済み(Lumonde-software / oshamashama / ryouta-uemura)
```

## 初回の公開鍵登録(clone 前に直接追加する場合)

メンバー個人の鍵で最初から SSH できるか分からない場合は、最初の担当者が大会配布の初期接続鍵または管理コンソールでサーバーに入り、次の1行を実行する。リポジトリの clone や `10-add-members-keys.sh` を使わず、`Lumonde-software`・`oshamashama`・`ryouta-uemura` の GitHub 公開鍵を `isucon` に追加する。各サーバーで実行する。

```bash
sudo -iu isucon bash -c 'set -e; umask 077; keys_tmp=$(mktemp); cleanup() { rm -f "$keys_tmp"; }; trap cleanup EXIT; for member in Lumonde-software oshamashama ryouta-uemura; do curl -fsS "https://github.com/${member}.keys" >> "$keys_tmp"; printf "\n" >> "$keys_tmp"; done; install -d -m 700 "$HOME/.ssh"; auth="$HOME/.ssh/authorized_keys"; touch "$auth"; chmod 600 "$auth"; printf "\n" >> "$auth"; cat "$keys_tmp" >> "$auth"; sort -u "$auth" -o "$auth"'
```

3人分の取得処理が成功してから追記する。既存の鍵は残し、重複する行を除去する。`.ssh` は700、`authorized_keys` は600に設定する。

このワンライナーは `isucon` への鍵追加に絞っており、`10-add-members-keys.sh` の次の機能は含まない。

| 省いた機能 | `10-add-members-keys.sh` の処理 |
| --- | --- |
| 入口ユーザーへの鍵追加 | `ubuntu` などにも同じ鍵を登録 |
| SSH 接続制限の確認 | `AllowUsers`・`DenyUsers`・鍵認証の無効化などを確認して警告 |
| 取得した鍵が0本の場合の停止 | 空行を除去し、公開鍵がなければ停止 |
| ログと結果表示 | 実行ログ、失敗箇所、登録前後の鍵数を記録 |

実行後は元の接続を残し、手元の別ターミナルで個人の鍵による接続を確認する。秘密鍵のパスと IP は実際の値に置き換える。

```sh
ssh -i "$HOME/.ssh/個人鍵のファイル名" isucon@サーバーIP
```

`isucon` への直接 SSH が禁止されている環境では、鍵の追加が成功しても接続できない。入口ユーザーにはこのワンライナーで鍵を追加していないため、初期接続鍵で入口ユーザーへ接続するか、`10-add-members-keys.sh` で入口ユーザーにも公開鍵を登録する。

接続を確認したら、以下の一括セットアップへ進む。`setup.sh` 自体も SSH を使うため、初期接続手段がない状態から公開鍵を登録することはできない。

## 初動をまとめて実行する

手元の `setup.sh` が、初期バックアップ・デプロイキー配置・サーバーでの鍵登録・Git 化・ツール導入・現設定の取り込みを順番に実行する。SSH の Host/IP/User/入口鍵は事前に `~/.ssh/config` へ設定し、GitHub に登録済みのデプロイ秘密鍵を手元のファイルで指定する。入口が ubuntu 等でも、非対話 sudo が使えればサーバー側の処理を isucon ユーザーで実行できる。isucon へ直接 SSH する場合も、30 の APT や設定コピーに使う sudo がパスワードなしで動くことを前提とする。秘密鍵・token・パスワードを引数の値へ直接書かない。

まず設定例をコピーし、アプリの場所・unit 名・成果物名・デプロイキーのパスを編集する。`setup.local.conf` は Git の管理対象から除外している。設定ファイルは Bash として読み込むため、自分で内容を確認したファイルを指定する。`--plan` でも設定ファイル自体は実行される。

```sh
cp setup.conf.example setup.local.conf
# setup.local.conf を編集
```

設定例の `isucari/webapp/go` と `xbuild/` は ISUCON9 の配置例。今回の競技ソースとツールの配置に合わせる。`DEPLOY_KEY_FILE` と `BACKUP_DIR` の相対パスは設定ファイルのあるディレクトリを基準にする。引数で渡す手元のファイルパスは、実行時のディレクトリを基準にする。

設定の優先順位は **コマンド引数 → 設定ファイル → 既定値**。`--config` の指定位置によらず、引数の値を使う。`--ignore` を引数で1つでも指定した場合は、設定ファイルの `EXTRA_IGNORES` を置き換える。複数指定するときは `--ignore` を繰り返す。設定ファイルを使わず、すべて引数で渡すこともできる。

まず初台のみをセットアップする。

```sh
# 計画表示。SSH・書き込み・コピーは行わない
./setup.sh --config ./setup.local.conf --mode first --server isu1:s1 --plan

# 初台を実行
./setup.sh --config ./setup.local.conf --mode first --server isu1:s1
```

`make` からも同じ処理を呼べる。モードと対象サーバーは毎回明示する。

```sh
make plan MODE=first SERVER=isu1:s1
make setup MODE=first SERVER=isu1:s1
# 別の設定ファイルを使う場合: CONFIG=./competition.conf を追加
```

アプリの場所などをその場で指定する場合も、`--` で区切る必要はない。

```sh
./setup.sh --mode first --server isu1:s1 --deploy-key ./deploy_key \
  --env-ref main --app-dir isucari/webapp/go --ignore xbuild/
```

従来の `-- SERVER_OPTIONS -- ENV_OPTIONS` 形式も利用できる。サーバー上の setup clone は指定 URL・ref と一致することを確認して再利用し、自動更新しない。未公開のローカルブランチはサーバーから clone できない。

初台では `/home/isucon` が新しい Git ルートになる。バックアップ結果・除外ファイル・`config.mk`・取り込んだ設定を確認し、必要な差分を自分で commit/push する。その push が済んでから、他台に共有履歴を配置する。

```sh
./setup.sh --config ./setup.local.conf --mode join --server isu2:s2 --server isu3:s3
# または: make setup MODE=join SERVERS="isu2:s2 isu3:s3"
```

設定ファイルのアプリ設定と `EXTRA_IGNORES` は `first` だけで使い、`join` / `existing` では共有履歴の設定を使う。`ARCHIVE_DIR` / `SKIP_ARCHIVE` は `first` / `join` だけで使う。このため、同じ設定ファイルを各モードで指定できる。引数で明示した初台専用オプションは、`join` / `existing` では誤指定として停止する。

`join` は既存のホーム直下 `.git` がないサーバー向けの明示的な合流操作。ホームのバックアップを試み、初台が push したブランチを fetch してから管理対象を共有履歴へ合わせる。既存ファイルを置換する場合は、サーバー内バックアップの成功が必要。バックアップが失敗・省略されても衝突がなければ合流でき、衝突する場合は原本を残して停止する。入れ子の `.git` や未追跡ファイルを一括削除する操作は行わない。既存ファイルと共有履歴が衝突する場合の保存・停止条件は、使用する env の `scripts/join-repo.sh --help` と README を確認する。初台用の `--app-dir` / `--ignore` 等は join では受け付けず、共有履歴の設定を使う。複数の `--server` は順に実行し、1台で失敗したら後続は実行しない。再開時は各台の完了段階に応じて first/join/existing を選ぶ。

ツール導入等で途中停止し、ホームの Git 化または合流が完了している場合は `existing` で鍵登録・ツール・設定取り込みを再実行できる。`.git` だけが作られた未完了状態では止まるため、env README の復旧手順で先に確認する。

```sh
./setup.sh --mode existing --server isu1:s1 --skip-deploy-key
```

| 引数 | 用途 |
| --- | --- |
| `--config FILE` | ローカルの Bash 設定。対応する変数は `setup.conf.example` を参照 |
| `--server HOST:sN` | SSH Host とサーバー ID。join/existing では繰り返し指定可。first は1台だけ |
| `--home PATH` | 競技 Git ルートとバックアップ元。既定 `/home/isucon` |
| `--entry-user USER` | 10 が公開鍵を追加する入口アカウント。SSH ログインユーザーは SSH config の User で指定 |
| `--setup-ref REF` / `--setup-clone-dir PATH` | サーバーに置く setup の ref と clone 先。既定 `main` / `HOME/isucon-setup` |
| `--backup-dir PATH` / `--skip-backup` | 手元の先行バックアップ先 / その省略。env と30のサーバー内バックアップは別に試行 |
| `--deploy-key FILE` / `--skip-deploy-key` | デプロイ秘密鍵ファイルの配布 / 既存の認証を使う |
| `--env-ref` / `--env-repo` / `--clone-dir` | env の ref・URL・clone 先 |
| `--branch` / `--remote` | 競技リポジトリのブランチと origin |
| `--app-dir` / `--app-service` / `--app-bin` | 初台のアプリ配置・unit 名・成果物名 |
| `--mysql-conf-dir` / `--nginx-access-log` / `--mysql-slow-log` | 初台の設定・ログのパス |
| `--ignore PATTERN` / `--max-file-size-mib N` | 初台の追加除外（反復可）・大容量ファイルの除外基準 |
| `--archive-dir` / `--skip-archive` | first/join のサーバー内バックアップ先・その省略 |
| `--skip-keys` / `--skip-tools` / `--skip-config` | 鍵登録・ツール導入・設定取り込みの省略 |

すべてのオプションを `setup.sh` に直接指定できる。従来形式を使う場合、共通の `--home` は最初の `--` より前に指定する。`--clone-dir` は env の clone 先で、setup の clone 先とは別。サーバー側のパス・競技設定は ASCII 英数字と `_./:@+-` のみを使う。`--env-repo` / `--setup-repo` は認証情報を含まない SSH URL または HTTPS URL にし、既存 clone の origin と同じ値を指定する。既存 clone の ref が違う場合は勝手に切り替えず停止する。Git の SSH 接続は、このコマンドと子プロセスの範囲で `BatchMode=yes`・`StrictHostKeyChecking=accept-new`・接続待ち10秒を既定にする。初めての host key は登録し、変更された key は拒否する。呼び出し元が `GIT_SSH_COMMAND` を設定している場合はその指定を保つ。

デプロイキーの配置先は isucon アカウントの実ホームの `.ssh/id_ed25519`。`--home` で競技 Git ルートを変えても認証鍵の場所は変えない。`.ssh` は700、鍵は600とし、同じ鍵があれば再利用し、異なる既存鍵やシンボリックリンクは上書きせず停止する。鍵の内容は SSH の標準入力で送り、コマンド引数やログへ表示しない。

`get-conf` は現在の nginx/MySQL/アプリ unit/env.sh を private な競技リポジトリへコピーし、`set-as-sN` はホームの `env.sh` にサーバー ID を設定する。これらを省く場合は `--skip-config` を指定する。一括実行は push、設定の deploy、競技サービスの restart、LTSV/slow log/pprof 等の計測設定を実行しない。計測やデプロイは、取り込んだ設定を確認して env README の手順で行う。2台目でホームやアプリ配置が初台と異なる場合は、共有した `config.mk` を確認してから設定取り込みへ進める。

サーバーへ自分でログインして開始する場合は `setup-server.sh` だけでも同じ処理をまとめられる。この入口は手元バックアップや秘密鍵配布を行わない。

```sh
sudo -iu isucon
bash /home/isucon/isucon-setup/setup-server.sh \
  --mode first --server-id s1 --home /home/isucon \
  -- --app-dir isucari/webapp/go --ignore xbuild/
```

個々の処理だけ実行したい場合は、下の手順と既存の 00/10/30 を引き続き利用できる。

一括実行が止まった場合や、作業を1段階ずつ確認したい場合は [手動セットアップ手順](manual/README.md) を使う。手元でのバックアップ、鍵の配置、初台の Git 化、他台の合流、ツール導入、途中停止からの復旧を分けて記載している。00/10/30 が動かない場合の直接コマンドと、サーバー用の設定例も用意している。

## 当日の初動(サーバーごと)

```sh
# 0. 手元から: ssh_config の IP を埋める → 何かを触る前に初期状態を手元にバックアップ(全台まとめて)
#    スクリプトと同じ場所の backup/ に <host>-<時刻>-home-isucon.tar.gz と -etc.tar.gz
#    (/etc/nginx, /etc/mysql, /etc/systemd/system)ができる。権限 600(中身に認証情報を含み得る)。
#    出力先は OUT_DIR、ホームのコピー元は REMOTE_HOME で変更可(既定 /home/isucon)
#    読めないファイルがあって tar が失敗しても、gzip として完結していれば部分バックアップとして残す(WARN 表示)
#    isucon で入れない環境(入口が ubuntu だけ)なら、ssh_config の User を一時的に入口ユーザーにして実行するか、
#    10 の後に実行する(sudo が非対話で使えれば /home/isucon も sudo tar で取る)
./00-local-backup.sh isu1 isu2 isu3
# REMOTE_HOME=/srv/isucon ./00-local-backup.sh isu1  # 別ホームの例(ASCII英数字と _./:@+- の絶対パス)

# 1. 最初の1人がサーバーに入る(入口が ubuntu 等なら sudo -i -u isucon で isucon に切り替え)
#    このリポジトリを clone(public なので認証不要)して鍵を登録
git clone https://github.com/team-hacker-isucon/isucon-setup.git ~/isucon-setup
cd ~/isucon-setup
./10-add-members-keys.sh        # 以後、全員 ssh isucon@<ip> で直接入れる(入口ユーザーにも同じ鍵が入る)

# 2. 手元から: デプロイキーを配置
scp ./deploy_key isu1:.ssh/id_ed25519    # isu2 / isu3 にも同じ鍵を配る
ssh isu1 'chmod 600 ~/.ssh/id_ed25519'

# 3. Git 初期化は isucon-env 側で実行する(1台目のみ)
ENV_BRANCH=main
git clone --branch "$ENV_BRANCH" git@github.com:team-hacker-isucon/isucon-env.git ~/isucon-env
bash ~/isucon-env/scripts/init-repo.sh --home /home/isucon
#    webapp/go 以外にアプリがある場合は --app-dir <ホームからの相対パス> を指定する。
#    ツールの別 Git clone がある場合は --ignore xbuild/ などで除外する。
#    設定・除外・バックアップ結果を確認してから、必要な時に自分で push する。

cd ~/isucon-setup
# 4. ツール導入 + git/エディタ設定(先頭で触る前のバックアップも取る)
./30-install-tools.sh

# 5. 以後は競技 repo 側(/home/isucon の Makefile)で作業
#    make set-as-s1 → make get-conf → …(isucon-env の README 参照)
```

### Git 初期化を isucon-env に移管

`20-init-repo.sh` は移行先を表示して exit 2 で終了する。ホームの初期化・言語削除・通信・push は行わず、旧引数や `FORCE` / `KEEP_LANG` 等も引き継がない。初期化の入口を `isucon-env/scripts/init-repo.sh` に統一し、古い Git の `git init -b`、`webapp` 固定、容量不足や大容量ファイルによる中断が残る旧実装は実行しない。

詳細な引数・除外対象は [isucon-env README](https://github.com/team-hacker-isucon/isucon-env#readme)、段階ごとの手動操作と途中停止時の復旧は [手動セットアップ手順](manual/README.md) を参照する。

すでに旧 20 を実行して途中停止したホームでは `.git` を消さない。`git status`、`git log --oneline -5`、`git remote -v` を確認する。push の切断だけではローカルのコミットは失われないため、新スクリプトで二重に初期化せず、履歴と接続先を確認してから続きを実行する。キャッシュが古い履歴に入っている場合は、新しい ignore だけでは過去の Git object を減らせない。履歴の共有・push の反映状況を確認してから整理する。

### ツール導入時のバックアップと APT ロック

`30-install-tools.sh` は MySQL・nginx・systemd とホーム全体を `local/backup-<時刻>-*.tar.gz` へ保存する。`webapp` の存在を要求せず、ホームの `local/`・`.git/`・`isucon-setup-logs/` を除外する。ホームを変える場合は `ISUCON_HOME=/別のホーム ./30-install-tools.sh` と指定する。この指定はバックアップ元・保存先に適用し、エディタ設定等は実行ユーザーのホームを使う。ログの場所を変えた場合は `NGINX_ACCESS_LOG=/別のログ MYSQL_SLOW_LOG=/別のログ ./30-install-tools.sh` で、読み取り権限を付ける対象も指定できる。

各アーカイブは保存先の空き容量に 1 GiB の余裕がある場合に試行し、出力ファイルを権限 600 で作成し、成功時にだけ `.tar.gz` の名前にする。失敗時の `.partial` は完全なバックアップではない。コピー元のサイズや空き容量が不明な場合・容量不足・保存先を作れない場合も、警告を出してツール導入を続ける。保存先を作成できた場合は `backup-<時刻>-report.txt` に各対象の `success` / `failed` / `skipped` を残す。稼働中の MySQL は整合した物理バックアップを保証しないため、復旧可能性が必要なら別途確認する。

APT は更新・インストール時のロック占有エラーだけ最大 300 秒待って再試行する。古い APT でも動くよう、`DPkg::Lock::Timeout` に依存せず判定する。ロックファイルは削除せず、保持プロセスも停止しない。権限不足・リポジトリ障害・dpkg の中断等はそのまま失敗を返す。待機上限は `APT_LOCK_WAIT_SECONDS`、再試行の間隔は `APT_LOCK_RETRY_SECONDS` (既定 5 秒) で変更でき、上限を 0 にすると再試行しない。APT の出力は各試行の終了時に表示する。上限後もロックが残る場合は、別の更新処理が終わってから 30 を再実行する。

## 2台目以降の合流

1台目で内容を確認して push した後、上の `./setup.sh --mode join ...` を実行する。サーバーへ直接ログインして合流だけ行う場合は、isucon-env の `scripts/join-repo.sh` を使う。バックアップ・衝突時の保存・途中停止時の復旧条件は、上記 isucon-env README の「2台目以降の合流」を参照する。

## 解析結果を手元に取ってくる(手元の AI エージェントに渡す)

`make analyze` / `make pprof-record` の結果は各サーバーの `analysis/` と `pprof/` にたまる。手元で動かす AI エージェントに読ませるときは、**手元 PC で** `01-fetch-results.sh` を実行してコピーする(エージェントに競技サーバーへの ssh を渡さずに済む)。

```sh
./01-fetch-results.sh isu1 isu2 isu3   # 何度実行しても差分だけ取る(rsync が無ければ tar で丸ごと)
```

- 出力: `fetched/<host>/analysis/<時刻>/`(alp.txt / slow-query.txt)と `fetched/<host>/pprof/`。手元に go があれば pprof ごとに要約テキスト `*.top.txt` も作る
- コードはコピー不要(エージェントは手元に clone した競技 repo で `git pull` して読む)
- 生ログ(access.log / slow log)は大きすぎるので取らない。先に `make analyze` で要約する
- `fetched/` は git 管理しない。中身は競技データなので外部へ公開・共有しない(外部の AI サービスに送ってよいかは、その年のレギュレーションで事前に確認する)

## ログ

10 / 30 / 90 は実行した全コマンドを時刻付きで表示し、同じ内容をログファイルにも残す(失敗時は何行目の何のコマンドで止まったかとログの場所が出る)。

- 置き場所: `/home/isucon/isucon-setup-logs/<スクリプト名>-<時刻>.log`(書けない場合は `$HOME/isucon-setup-logs/`。ubuntu で 10 を実行した場合など)
- 競技 repo の `.gitignore` 対象(env の初期化で設定する)。90 の `GITHUB_TOKEN` はトレースを止めて扱うのでログに残らない
- 00 は手元で実行するため、毎行ログの対象外(結果のサマリだけ画面に出る)
- 20 は移行案内のみを表示し、実行ログを作らない

## tmux の全ペイン録画

30 が配る `~/.tmux.conf` で、**tmux の新しいウィンドウ/ペインはすべて自動で録画**される(util-linux の `script` を使うので追加インストール不要)。Ubuntu 18.04 の util-linux でも使える形式でタイミング付きの記録を取り、あとから再生できる。

- 保存先: `~/local/tmux-rec/<ホスト名>-<開始時刻>-p<ペイン番号>.{tm,out}`(競技 repo で gitignore 済み)
- 設定前から開いているペインは録画されない。30 の実行後は tmux を起動し直す
- 録画しないペインを開くとき: `prefix :` → `new-window bash`

```sh
ls -lt ~/local/tmux-rec/                                      # 一覧
scriptreplay -t X.tm -s X.out -m 1 -d 4                       # 無操作の待ちを最大1秒に詰めて 4倍速で再生
grep -a 'make bench' ~/local/tmux-rec/*.out                   # 中身を文字列検索
ssh -t isu1 scriptreplay -t local/tmux-rec/X.tm -s local/tmux-rec/X.out -m 1   # 手元から再生
```

注意:
- **画面に出たものは秘密も含めて全部残る**(webhook URL、`mysql -p<パスワード>`、貼り付けた token など)。秘密は `read -rs` で入力するなど画面に出さない。録画ファイルを Discord 等に貼らない
- ウィンドウ名が全部 `script` になる(tmux から見た前景プロセスが script のため)。名前は `prefix ,` で付ける
- 再生側の端末がペインより小さいと vim / htop の画面が崩れる。途中へのシークはできない(`-m` / `-d` で早送り)
- ディスクを使い続ける(出力量に比例。`journalctl -f` や htop を長く流すペインが大きい)。ときどき `du -sh ~/local/tmux-rec` で確認する

## フォールバック: デプロイキーを当日生成して登録する

事前登録を忘れた・秘密鍵を持ってくるのを忘れた場合。サーバー上で鍵を生成し、GitHub REST API(curl)で登録する:

```sh
# 実行すると GITHUB_TOKEN を聞かれる(入力は表示されない)。
# token: fine-grained PAT(対象 repo 限定 + Administration: Read and write)。
# コマンドラインに GITHUB_TOKEN=... と書かない(~/.bash_history に残る)。curl へもファイル経由で渡すので ps に出ない
./90-fallback-deploy-key.sh

# token が無い場合は空のまま Enter → 表示された公開鍵を
# isucon-env の Settings → Deploy keys に手で貼る(Allow write access にチェック)
```

さらにもしもの時(SSH が全滅した等)は PAT の https 認証でも push できる: `git config --global credential.helper 'cache --timeout=28800'` して、初回 fetch のプロンプトで Username = GitHub ユーザー名 / Password = PAT(Contents: Read and write)。cache はメモリにだけ 8 時間保持し、ファイルには残らない(`store` は ~/.git-credentials に平文で書くので使わない。env の .gitignore で除外はしているが、git add -A で push される事故を避ける)。競技後に PAT は必ず revoke する。

## ローカル回帰テスト

```sh
python3 -m unittest discover -s tests -v
for script in setup.sh setup-server.sh 20-init-repo.sh 30-install-tools.sh lib/install-tools.sh; do
  bash -n "$script"
done
```

APT・sudo・ダウンロード・設定変更を stub に置き換え、Ubuntu 18.04 のロック文言、有限待機、非ロック失敗、ホーム直下アプリのアーカイブ、容量不足と保存先作成失敗後の続行を確認する。実際の VM・APT の並行処理・MySQL 復旧はこのテストでは実行しない。

一括入口の回帰は SSH・ユーザー判定を stub にし、ローカル Git で鍵の既存保護、引数の境界、変更なし plan、バックアップ失敗後の続行を確認する。env との結合確認は、init/join を含むコミット済み clone を明示する。

```sh
ISUCON_ENV_TEST_SOURCE=/path/to/isucon-env \
  python3 -m unittest discover -s tests -p test_setup_runner.py -v
```

この結合確認も一時ディレクトリとローカルの bare Git のみを使い、実 SSH・APT・systemd は実行しない。
