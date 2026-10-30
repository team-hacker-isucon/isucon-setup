# 3. 初台の Git 化と共有

[一覧](README.md) / [前: 鍵](02-keys.md) / [次: 他台](04-join-servers.md)

ここは s1 だけで実行する。ホーム全体を Git のルートにし、private な isucon-env のテンプレートと合流させる。サーバー上のアプリや設定を public な isucon-setup へ追加しない。

## テンプレートを取得する

isucon ユーザーの Bash で設定を読み込む。

```bash
source "$HOME/local/manual-settings.env"
test ! -e "$ISUCON_HOME/.git" && test ! -L "$ISUCON_HOME/.git"
```

`.git` がある場合はここで止め、[復旧](06-recovery.md) へ進む。まだ env clone がない場合だけ取得する。

```bash
git clone --branch "$ENV_REF" "$ENV_REPO" "$ENV_DIR"
git -C "$ENV_DIR" status --short
git -C "$ENV_DIR" remote -v
git -C "$ENV_DIR" log -1 --oneline
```

既存 clone は上の確認だけを実行し、使う ref と一致しているか確かめる。テンプレートには clone 内のコミット済み HEAD を使うため、未コミットの編集は取り込まれない。

## ホームを初期化する

先行バックアップの結果と空き容量を確認してから実行する。

```bash
df -h "$ISUCON_HOME" "$(dirname "$ISUCON_HOME")"
init_args=(
  --home "$ISUCON_HOME" --branch "$BRANCH" --remote "$REMOTE"
  --app-dir "$APP_DIR" --app-service "$APP_SERVICE" --app-bin "$APP_BIN"
  --mysql-conf-dir "$MYSQL_CONF_DIR"
  --nginx-access-log "$NGINX_ACCESS_LOG" --mysql-slow-log "$MYSQL_SLOW_LOG"
  --max-file-size-mib "$MAX_FILE_SIZE_MIB"
)
for pattern in "${EXTRA_IGNORES[@]}"; do
  init_args+=(--ignore "$pattern")
done
bash "$ENV_DIR/scripts/init-repo.sh" "${init_args[@]}"
```

サーバー内の退避先は既定でホームの兄弟ディレクトリになる。別ディスクを使う場合は、親ディレクトリを先に用意し、`init_args+=(--archive-dir /別ディスク/新規ディレクトリ名)` を実行直前に追加する。既存の保存先は再利用しない。

初期化は「ホームの退避 → 除外設定 → 初期状態のコミット → テンプレート履歴の合流 → config.mk の作成」と進む。退避が失敗しても初期化は続くので、終了コードだけでバックアップ成功と判断しない。初期状態の追跡ファイルは履歴に残り、除外されたファイルは成功したアーカイブの `<退避先>/home/` に残る。

この helper が動かない、または入れ子の Git 検出などで止まった場合は、[Git を手作業で進める方法](06-recovery.md#git-を手作業で進める) を使う。`.git` を削除して繰り返さない。

## 結果を確認する

```bash
cd "$ISUCON_HOME"
git rev-parse --show-toplevel
git status --short
git log --oneline -5
git remote -v
cat config.mk
cat .git/info/isucon-init-report.txt
cat .git/info/isucon-large-files.txt
cat .git/info/isucon-python-envs.txt
git ls-files --stage | awk '$1 == "160000" { print }'
```

Git ルートが `ISUCON_HOME` と一致し、`config.mk` のアプリ・unit・ログ設定が正しいことを確認する。mode 160000 はソース本体ではなく入れ子の Git を指すため、表示された場合は先に扱いを決める。大容量ファイルや仮想環境の一覧は、必要な原本まで除外していないか確認する。

## 現設定を取り込み、内容を確認して共有する

先に s1 で [ツール導入と現設定の取り込み](05-tools-and-config.md) を済ませる。取り込む設定には DB 認証情報などが含まれ得るため、確認は自分の端末で行う。追跡対象の一覧を見て、秘密鍵・バックアップ・ツール clone が含まれていないことも確かめる。

```bash
cd "$ISUCON_HOME"
git status --short
git ls-files
git diff --stat
git diff -- config.mk
git add -- s1
git diff --cached --stat
# ステージした内容を確認し、変更がある場合に実行する
git commit -m 'capture s1 configuration'
git push -u origin "$BRANCH"
```

`config.mk` なども編集した場合は、確認して明示的に `git add` する。`origin` が private な競技 repo であることを確認してから push する。初期化時に作られたコミットにはホームの原本が入っているため、現在の差分だけでなく追跡ファイルと初期コミットも確認する。

push 成功後に [他台への合流](04-join-servers.md) へ進む。
