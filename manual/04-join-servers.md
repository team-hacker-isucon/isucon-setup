# 4. 他台への合流

[一覧](README.md) / [前: 初台](03-first-server.md) / [次: ツールと設定](05-tools-and-config.md)

初台の変更を push した後、s2、s3 の順で行う。各台のバックアップ・鍵・作業設定は [1](01-prepare.md)・[2](02-keys.md) で準備しておく。初台用の `init-repo.sh` を他台で実行しない。

## 共有ブランチと原本を確認する

各サーバーで isucon ユーザーの Bash を使う。

```bash
source "$HOME/local/manual-settings.env"
test ! -e "$ISUCON_HOME/.git" && test ! -L "$ISUCON_HOME/.git"
git ls-remote "$REMOTE" "refs/heads/$BRANCH"
df -h "$ISUCON_HOME" "$(dirname "$ISUCON_HOME")"
```

ホーム直下に `.git` がある場合は再実行せず、[復旧](06-recovery.md) で状態を確認する。指定したリモートブランチが存在すること、アプリの初期配置が初台と同じかを確認する。合流は共有ファイルを配置する操作なので、初台と異なる各台固有の値は、原本から参照できるようにしておく。

env clone がない場合だけ取得し、取得済みなら origin・HEAD・作業差分を確認する。

```bash
git clone --branch "$ENV_REF" "$ENV_REPO" "$ENV_DIR"
git -C "$ENV_DIR" remote -v
git -C "$ENV_DIR" log -1 --oneline
git -C "$ENV_DIR" status --short
```

## 共有履歴を取り込む

```bash
bash "$ENV_DIR/scripts/join-repo.sh" \
  --home "$ISUCON_HOME" --remote "$REMOTE" --branch "$BRANCH"
```

退避先を変える場合は `--archive-dir /別ディスク/新規ディレクトリ名` を追加する。`--app-dir` や `--ignore` はここでは使わず、共有履歴の `config.mk` を引き継ぐ。

既存の通常ファイルと共有ファイルが重なる場合は、helper のサーバー内バックアップが成功したときだけ置き換える。ディレクトリ・シンボリックリンクとの構造の衝突は、バックアップがあっても停止する。`--skip-archive` を付けてもこの確認は省略できない。初台にないローカルファイルや入れ子の `.git` は削除しない。

失敗時には `.git` と原本を残す。[復旧](06-recovery.md) のレポート確認へ進み、`git checkout -f` や `git reset --hard` で進めない。

## 結果を確認し、自分の ID を付ける

```bash
cd "$ISUCON_HOME"
git status --short
git log --oneline -5
git branch -vv
cat config.mk
cat .git/info/isucon-join-report.txt
```

`join_status=success`、origin の共有ブランチへの追従、ホーム・アプリのパスを確認する。全台でホームを揃えると共有しやすい。ホームを変えた場合は `config.mk` にローカル差分が残るので、各台固有のパスをそのまま共有 branch へ commit しない。

ここから [ツールと現設定の取り込み](05-tools-and-config.md) へ進み、**s2 なら `set-as-s2`、s3 なら `set-as-s3`** を使う。各台の設定コピーはそれぞれ `s2/`、`s3/` に保存する。
