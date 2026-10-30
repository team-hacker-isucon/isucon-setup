# 手動セットアップ

一括実行が止まったときや、作業ごとに結果を確認したいときの手順書。初期状態の退避から、Git 管理・ツール導入・現在の設定の取り込みまでを扱う。各ページのコマンドを1ブロックずつ実行し、失敗したらその段階で原因を確認する。

| 順番 | 手順 | 実行場所 |
| --- | --- | --- |
| 1 | [SSH・バックアップ・作業設定](01-prepare.md) | 手元 → 全サーバー |
| 2 | [メンバー公開鍵・GitHub 認証](02-keys.md) | 全サーバー・手元 |
| 3 | [初台の Git 化と共有](03-first-server.md) | s1 |
| 4 | [他台への合流](04-join-servers.md) | s2 → s3 |
| 5 | [ツール導入・現在の設定の取り込み](05-tools-and-config.md) | 各サーバー |
| 必要時 | [途中停止からの復旧と Git の手作業](06-recovery.md) | 失敗したサーバー |

初台は「3 → 5 → 内容を確認して push」の順で進め、その後に他台で「4 → 5」を進める。初台を共有する前に他台で新しい Git 履歴を作らない。

## 使う設定とファイル

| ファイル | 用途 |
| --- | --- |
| [ssh_config.example](../ssh_config.example) | 手元の `~/.ssh/config` に追加する Host 設定 |
| [setup.conf.example](../setup.conf.example) | 手元の一括実行用。手動手順から一括実行へ戻る際に使用 |
| [server.env.example](server.env.example) | 手動手順で使うサーバー上の作業変数。各台の `~/local/manual-settings.env` にコピー |
| `isucon-env/.gitignore`・`scripts/`・`Makefile` | private repo から取得する Git 初期化・合流・設定取り込みの実装 |
| `isucon-env/templates/` | LTSV・MySQL・pprof など、セットアップ後に使う既存設定例 |

設定の実値は各台の `config.mk` が共有の基準になる。手動用の変数ファイルは一括実行から読み込まれないため、両方を使う場合はアプリの配置や unit 名を揃える。サーバー固有の ID は `make set-as-s1` / `set-as-s2` / `set-as-s3` で指定する。

手元の通常の操作は zsh でよい。サーバーのコマンドは、配列を使うため **isucon ユーザーの Bash** で実行する。`sudo` は APT・ログ権限・現在の設定の読み取りなど、必要なコマンドに付ける。Git とホーム内のファイル操作を root で実行しない。

## 途中から使う場合

| 現在の状態 | 再開先 |
| --- | --- |
| SSH できない、鍵が未配置 | 1・2 |
| ホーム直下に `.git` がない初台 | 3 |
| 初台が push 済みで、他台のホーム直下に `.git` がない | 4 |
| `.git` はあるが初期化・合流の完了が不明 | 6 で履歴とローカルレポートを確認 |
| `config.mk`・Makefile・Git 履歴まで揃っている | 5。`first` / `join` を再実行しない |
| push だけ失敗した | 6。ローカルの履歴を残して接続と共有先を確認 |

完了時には、各台でホームが Git ルートになり、アプリ設定とサーバー ID が一致し、必要なツールと実設定のコピーが揃う。サービスへの設定配布・再起動・計測の有効化は、その後に [isucon-env README](https://github.com/team-hacker-isucon/isucon-env#readme) を確認して行う。
