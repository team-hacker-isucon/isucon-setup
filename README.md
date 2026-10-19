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

## 当日の初動(サーバーごと)

```sh
# 0. 手元から: ssh_config の IP を埋める → 何かを触る前に初期状態を手元にバックアップ(全台まとめて)
#    スクリプトと同じ場所の backup/ に <host>-<時刻>-home-isucon.tar.gz と -etc.tar.gz
#    (/etc/nginx, /etc/mysql, /etc/systemd/system)ができる。権限 600(中身に認証情報を含み得る)。出力先は OUT_DIR で変更可
#    読めないファイルがあって tar が失敗しても、gzip として完結していれば部分バックアップとして残す(WARN 表示)
#    isucon で入れない環境(入口が ubuntu だけ)なら、ssh_config の User を一時的に入口ユーザーにして実行するか、
#    10 の後に実行する(sudo が非対話で使えれば /home/isucon も sudo tar で取る)
./00-local-backup.sh isu1 isu2 isu3

# 1. 最初の1人がサーバーに入る(入口が ubuntu 等なら sudo -i -u isucon で isucon に切り替え)
#    このリポジトリを clone(public なので認証不要)して鍵を登録
git clone https://github.com/team-hacker-isucon/isucon-setup.git ~/isucon-setup
cd ~/isucon-setup
./10-add-members-keys.sh        # 以後、全員 ssh isucon@<ip> で直接入れる(入口ユーザーにも同じ鍵が入る)

# 2. 手元から: デプロイキーを配置
scp ./deploy_key isu1:.ssh/id_ed25519    # isu2 / isu3 にも同じ鍵を配る
ssh isu1 'chmod 600 ~/.ssh/id_ed25519'

# 3. /home/isucon を git 化して競技 repo(team-hacker-isucon/isucon-env)と合流(1台目のみ)
#    git 化の前に /home/isucon を /home/isucon_archive_<時刻> へ丸ごとコピーし、
#    initial commit(全言語入り)の後に Go 以外の実装を別 commit で消してから合流する(詳細は下)
./20-init-repo.sh

# 4. ツール導入 + git/エディタ設定(先頭で触る前のバックアップも取る)
./30-install-tools.sh

# 5. 以後は競技 repo 側(/home/isucon の Makefile)で作業
#    make set-as-s1 → make get-conf → …(isucon-env の README 参照)
```

### 20-init-repo.sh の安全装置と環境変数

- 実行前チェック: 次のどれかに当たると、理由を表示して**何も変更せずに** exit 1 する
  - `/home/isucon` が無い / isucon ユーザーで実行していない
  - `/home/isucon/.git` が既にある(二重実行防止。2台目以降は下の合流手順)
  - `/home/isucon/webapp` が無い(想定と違う構成。`ls -la /home/isucon` を表示して止まる)
- 自動アーカイブ: `.gitignore` 作成や `merge -X theirs`(README.md / Makefile 等の上書き)より前に `sudo cp -a /home/isucon /home/isucon_archive_<時刻>` を取る。空きが「サイズ + 5GB」未満、またはサイズが取れなければ止まる。コピー失敗・Ctrl-C 時は作りかけを消す。不要になったら `sudo rm -rf /home/isucon_archive_<時刻>` で消す
- 大きいファイルの検査: initial commit の前に 50MB 超のファイルが commit 対象にあれば、一覧を出して止まる(GitHub の 100MB 制限で最後の push だけが失敗する事故を防ぐ)
- 言語実装の削除: initial commit の次の commit で `webapp/` 配下の既知の言語ディレクトリ(nodejs, php, python, ruby, rust など)を `git rm -r` する。`js` / `ts` は静的ファイル置き場と区別できないので対象外。`frontend` / `sql` / `public` など言語名でないものは消さない。戻すときは `git checkout <initial commit> -- webapp/<lang>`(サマリに hash が出る)

| 環境変数 | 既定 | 意味 |
| --- | --- | --- |
| `FORCE=1` | なし | `webapp/` が無くても続行する |
| `SKIP_ARCHIVE=1` | なし | 自動アーカイブを省略する(容量不足で止まったとき。00 の手元バックアップがある前提) |
| `KEEP_LANG` | `go` | 残す言語。カンマ区切りで複数可(例: `KEEP_LANG=go,rust`) |
| `NO_PRUNE_LANG=1` | なし | 言語実装の削除をしない |

### 20 が途中で失敗したときの復旧

- **git 化より前**(実行前チェック・SSH 確認・アーカイブ・50MB 超ファイルの検査)で止まった場合は何も変わっていないので、原因を直して再実行すればよい。50MB 超のファイルがあると `.git` / `.gitignore` を消して止まるので、`.gitignore` に追加するなど手で対処してから再実行する
- **initial commit より前**に失敗した場合は、`rm -rf /home/isucon/.git /home/isucon/.gitignore` してから再実行してよい
- **言語削除・fetch・merge・push** で失敗した場合は `.git` を消さずに続きを手で実行する(失敗表示にも同じコマンドが出る):

```sh
cd /home/isucon
git status                    # 言語削除が未 commit なら git commit -m 'remove non-go implementations'
git remote -v                 # origin が無ければ git remote add origin git@github.com:team-hacker-isucon/isucon-env.git
git fetch origin
git merge origin/main --allow-unrelated-histories -X theirs -m 'merge isucon-env'   # merge 済みなら不要
git push -u origin main
```

⚠️ この段階で `rm -rf .git` して再実行しない。`git rm` で消した言語実装はディスクから消えていて initial commit にしか残っていないため、再実行すると initial commit に入らなくなる(戻すにはアーカイブ `/home/isucon_archive_<時刻>` からコピーするしかない)。

## 2台目以降の合流

2台目以降(s2/s3)は 20-init-repo.sh ではなく、既存の /home/isucon に重ねる(初期状態は全台同一なので reset --hard で安全):

```sh
cd /home/isucon
git init -b main
git remote add origin git@github.com:team-hacker-isucon/isucon-env.git
git fetch origin
git reset --hard origin/main
git branch -u origin/main main   # 初回 push で --set-upstream を聞かれないように
git status --short               # 1台目で消した言語実装(webapp/nodejs 等)は未追跡として残る
# rm -rf webapp/<lang>           # → 消しておく(git add -A で復活させないように)
```

## ログ

10 / 20 / 30 / 90 は実行した全コマンドを時刻付きで表示し、同じ内容をログファイルにも残す(失敗時は何行目の何のコマンドで止まったかとログの場所が出る)。

- 置き場所: `/home/isucon/isucon-setup-logs/<スクリプト名>-<時刻>.log`(書けない場合は `$HOME/isucon-setup-logs/`。ubuntu で 10 を実行した場合など)
- 競技 repo の `.gitignore` 対象(20 が書く)。90 の `GITHUB_TOKEN` はトレースを止めて扱うのでログに残らない
- 00 は手元で実行するため、毎行ログの対象外(結果のサマリだけ画面に出る)
- 20 は git 化以降のフェーズで失敗すると、失敗表示の中に復旧コマンド(下記)を出す

## tmux の全ペイン録画

30 が配る `~/.tmux.conf` で、**tmux の新しいウィンドウ/ペインはすべて自動で録画**される(util-linux の `script` を使うので追加インストール不要)。あとからタイミング付きで再生できる。

- 保存先: `~/local/tmux-rec/<ホスト名>-<開始時刻>-p<ペイン番号>.{tm,out}`(競技 repo で gitignore 済み)
- 設定前から開いているペインは録画されない。30 の実行後は tmux を起動し直す
- 録画しないペインを開くとき: `prefix :` → `new-window bash`

```sh
ls -lt ~/local/tmux-rec/                                      # 一覧
scriptreplay -T X.tm -O X.out -m 1 -d 4                       # 無操作の待ちを最大1秒に詰めて 4倍速で再生
grep -a 'make bench' ~/local/tmux-rec/*.out                   # 中身を文字列検索
ssh -t isu1 scriptreplay -T local/tmux-rec/X.tm -O local/tmux-rec/X.out -m 1   # 手元から再生
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

さらにもしもの時(SSH が全滅した等)は PAT の https 認証でも push できる: `git config --global credential.helper 'cache --timeout=28800'` して、初回 fetch のプロンプトで Username = GitHub ユーザー名 / Password = PAT(Contents: Read and write)。cache はメモリにだけ 8 時間保持し、ファイルには残らない(`store` は ~/.git-credentials に平文で書くので使わない。20 の .gitignore で除外はしているが、git add -A で push される事故を避ける)。競技後に PAT は必ず revoke する。
