#!/bin/bash
# Git initialization moved to isucon-env. Do not run the retired destructive flow.
set -euo pipefail
cat >&2 <<'EOF'
20-init-repo.sh は廃止しました。ホームは変更していません (exit 2)。
Git 初期化は isucon-env の scripts/init-repo.sh を使ってください。
  https://github.com/team-hacker-isucon/isucon-env
  cd ~/isucon-env
  ./scripts/init-repo.sh --home /home/isucon --app-dir isucari/webapp/go --ignore xbuild/
上は ISUCON9 の配置例です。app-dir と ignore は実際の配置に合わせてください。
必要な変更: https://github.com/team-hacker-isucon/isucon-env/pull/1
PR が未マージなら、その変更を含むブランチを明示して clone してください。
旧引数や FORCE/KEEP_LANG 等は引き継ぎません。新スクリプトの --help を確認してください。
途中まで実行したホームの .git は消さず、README の復旧手順を確認してください。
EOF
exit 2
