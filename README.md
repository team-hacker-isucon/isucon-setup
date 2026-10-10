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
- 入口が `ubuntu` 等の別ユーザーの環境(EC2 素の構成や multipass)では、ポータル/クラウドが配置した鍵で最初の1人だけが入れる。その1人が `sudo -i -u isucon` してこのリポジトリを clone し、`10-add-members-keys.sh` を実行すれば、**以後は全員 isucon 直ログイン**になる(ubuntu 側に鍵を足す必要はない。sudo 経由の入り方はこの初回だけ)
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
#    ※ 10-add-members-keys.sh の MEMBERS は記入済み(Lumonde-software / oshamashama / ryouta-uemura)
```

## 当日の初動(サーバーごと)

```sh
# 0. 最初の1人がサーバーに入る(入口が ubuntu 等なら sudo -i -u isucon で isucon に切り替え)

# 1. このリポジトリを clone(public なので認証不要)して鍵を登録
git clone https://github.com/team-hacker-isucon/isucon-setup.git ~/isucon-setup
cd ~/isucon-setup
./10-add-members-keys.sh        # 以後、全員 ssh isucon@<ip> で直接入れる

# 2. 手元から: ssh_config の IP を埋める → デプロイキーを配置
scp ./deploy_key isu1:.ssh/id_ed25519    # isu2 / isu3 にも同じ鍵を配る
ssh isu1 'chmod 600 ~/.ssh/id_ed25519'

# 3. /home/isucon を git 化して競技 repo(team-hacker-isucon/isucon-env)と合流(1台目のみ)
./20-init-repo.sh

# 4. ツール導入 + git/エディタ設定(先頭で触る前のバックアップも取る)
./30-install-tools.sh

# 5. 以後は競技 repo 側(/home/isucon の Makefile)で作業
#    make set-as-s1 → make get-conf → …(isucon-env の README 参照)
```

2台目以降(s2/s3)は 20-init-repo.sh ではなく、既存の /home/isucon に重ねる(初期状態は全台同一なので reset --hard で安全):

```sh
cd /home/isucon
git init -b main
git remote add origin git@github.com:team-hacker-isucon/isucon-env.git
git fetch origin
git reset --hard origin/main
```

## フォールバック: デプロイキーを当日生成して登録する

事前登録を忘れた・秘密鍵を持ってくるのを忘れた場合。サーバー上で鍵を生成し、GitHub REST API(curl)で登録する:

```sh
# GITHUB_TOKEN: fine-grained PAT(対象 repo 限定 + Administration: Read and write)。
# 登録にしか使わないので、このコマンドだけ手元から実行してもよい
GITHUB_TOKEN=<token> ./90-fallback-deploy-key.sh

# token が無い場合は引数なしで実行 → 表示された公開鍵を
# isucon-env の Settings → Deploy keys に手で貼る(Allow write access にチェック)
./90-fallback-deploy-key.sh
```

さらにもしもの時(SSH が全滅した等)は PAT の https 認証でも push できる: `git config --global credential.helper store` して、初回 fetch のプロンプトで Username = GitHub ユーザー名 / Password = PAT(Contents: Read and write)。~/.git-credentials に平文で残るので競技後に必ず revoke する。
