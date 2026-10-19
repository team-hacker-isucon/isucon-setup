# shellcheck shell=bash
# 20-init-repo.sh から使う「Go 以外の言語実装の削除対象」判定(テストしやすいよう分離)。
# 消してよいのは既知の言語ディレクトリ名だけ。frontend / sql / data / public / docs など
# 言語名でないものは、未知の名前も含めて絶対に対象にしない
PRUNE_LANG_CANDIDATES=(
  nodejs node js typescript ts deno bun perl php python ruby rust
  java kotlin scala csharp dotnet elixir crystal nim zig
)

# 使い方: list_prune_targets <webapp ディレクトリ> <残す言語(カンマ区切り可。例: go)>
# 削除対象のディレクトリ名を1行ずつ出す。対象が無ければ何も出さない
list_prune_targets() {
  local webapp=$1 keep=$2 lang
  for lang in "${PRUNE_LANG_CANDIDATES[@]}"; do
    case ",${keep}," in *",${lang},"*) continue ;; esac
    # symlink は実体が別の場所にあり得るので触らない
    if [ -d "$webapp/$lang" ] && [ ! -L "$webapp/$lang" ]; then
      echo "$lang"
    fi
  done
}
