#!/usr/bin/env bash
# Run on a competition server as isucon. Reuse the keys/tools/env entry points.
set -euo pipefail
usage() {
  cat <<'EOF'
Usage: ./setup-server.sh --mode first|join|existing --server-id s1|s2|s3 [options] [-- ENV_OPTIONS...]
  --home PATH          Competition Git root (default: /home/isucon)
  --clone-dir PATH     isucon-env clone (default: HOME/isucon-env)
  --env-repo URL       Template repository (default: git@github.com:team-hacker-isucon/isucon-env.git)
  --env-ref REF        Template branch or tag to clone (default: main)
  --branch NAME        Competition branch (default: main)
  --remote URL         Competition origin (default: --env-repo)
  --entry-user USER    Extra account receiving members' public keys (10)
  --skip-keys          Do not run 10-add-members-keys.sh
  --skip-tools         Do not run 30-install-tools.sh
  --skip-config        Do not set SERVER_ID or copy config via make get-conf
  --plan               Print actions without running commands
ENV_OPTIONS are forwarded as an argument array to env scripts/init-repo.sh (first)
or scripts/join-repo.sh (join). existing accepts no ENV_OPTIONS. --home, --branch,
and --remote must be supplied before --. Paths use ASCII letters/digits and _./:@+-.
first requires no home .git. join imports shared history after the first server's
manual push; read join-repo.sh --help before running it. existing requires an
already initialized competition repository, including config.mk.
No push, deployment, service restart, or measurement configuration is performed.
EOF
}
fail() { echo "ERROR: $*" >&2; exit 1; }
value() { [[ $# -ge 2 && -n "$2" ]] || fail "$1 requires a value"; }
literal() { [[ -n "$2" && "$2" != *[!a-zA-Z0-9_./:@+-]* ]] || fail "$1 accepts ASCII letters/digits and _./:@+- only"; }
repository() {
  [[ -n "$2" && "$2" != -* && "$2" != *$'\n'* && "$2" != *$'\r'* ]] || fail "invalid $1"
  case "$2" in http://*@*|https://*@*|*://*:*@*|*'?'*|*'#'*) fail "repository URLs must not contain credentials, queries, or fragments" ;; esac
}
# Scope the first-use SSH policy to this process and its Git children. Preserve
# a caller's deliberate transport settings; never disable changed-key checking.
export GIT_SSH_COMMAND=${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
MODE= SERVER_ID= HOME_DIR=/home/isucon CLONE_DIR= ENV_REPO=git@github.com:team-hacker-isucon/isucon-env.git ENV_REF=main
BRANCH=main REMOTE= ENTRY_USER= PLAN=0 SKIP_KEYS=0 SKIP_TOOLS=0 SKIP_CONFIG=0
ENV_OPTIONS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) value "$@"; MODE=$2; shift 2 ;;
    --server-id) value "$@"; SERVER_ID=$2; shift 2 ;;
    --home) value "$@"; HOME_DIR=$2; shift 2 ;;
    --clone-dir) value "$@"; CLONE_DIR=$2; shift 2 ;;
    --env-repo) value "$@"; ENV_REPO=$2; shift 2 ;;
    --env-ref) value "$@"; ENV_REF=$2; shift 2 ;;
    --branch) value "$@"; BRANCH=$2; shift 2 ;;
    --remote) value "$@"; REMOTE=$2; shift 2 ;;
    --entry-user) value "$@"; ENTRY_USER=$2; shift 2 ;;
    --skip-keys) SKIP_KEYS=1; shift ;;
    --skip-tools) SKIP_TOOLS=1; shift ;;
    --skip-config) SKIP_CONFIG=1; shift ;;
    --plan) PLAN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; ENV_OPTIONS=("$@"); break ;;
    *) fail "unknown option: $1" ;;
  esac
done
case "$MODE" in first|join|existing) ;; *) fail "--mode first|join|existing is required" ;; esac
case "$SERVER_ID" in s1|s2|s3) ;; *) fail "--server-id s1|s2|s3 is required" ;; esac
literal --home "$HOME_DIR"
[[ "$HOME_DIR" = /* && "$HOME_DIR" != / ]] || fail "--home must be an absolute directory other than /"
HOME_DIR=${HOME_DIR%/}
CLONE_DIR=${CLONE_DIR:-$HOME_DIR/isucon-env}
CLONE_DIR=${CLONE_DIR%/}
literal --clone-dir "$CLONE_DIR"
[[ "$CLONE_DIR" = /* && "$CLONE_DIR" != "$HOME_DIR" && "$CLONE_DIR" != / ]] || fail "--clone-dir must be absolute and separate from --home"
for path in "$HOME_DIR" "$CLONE_DIR"; do
  case "/${path#/}/" in */../*|*/./*) fail "paths must not contain . or .. components" ;; esac
done
HOME_DIR=${HOME_DIR%/}; CLONE_DIR=${CLONE_DIR%/}
literal --env-ref "$ENV_REF"; literal --branch "$BRANCH"
[[ "$ENV_REF" != -* && "$BRANCH" != -* ]] || fail "branch/ref must not start with -"
[[ -z "$ENTRY_USER" ]] || { literal --entry-user "$ENTRY_USER"; [[ "$ENTRY_USER" != -* && "$ENTRY_USER" != */* ]] || fail "invalid entry user"; }
REMOTE=${REMOTE:-$ENV_REPO}
repository --env-repo "$ENV_REPO"; repository --remote "$REMOTE"
for arg in ${ENV_OPTIONS[@]+"${ENV_OPTIONS[@]}"}; do
  case "$arg" in --home|--home=*|--branch|--branch=*|--remote|--remote=*) fail "$arg must precede --" ;; esac
done
[[ "$MODE" != existing || ${#ENV_OPTIONS[@]} -eq 0 ]] || fail "existing accepts no ENV_OPTIONS"
# Reject unsupported/missing arguments before any public-key changes. Helpers
# still perform their full semantic validation before initializing the home.
i=0
while [[ $i -lt ${#ENV_OPTIONS[@]} ]]; do
  option=${ENV_OPTIONS[$i]}
  case "$option" in
    --skip-archive) i=$((i + 1)); continue ;;
    --archive-dir) ;;
    --ignore|--max-file-size-mib|--app-dir|--app-service|--app-bin|--mysql-conf-dir|--nginx-access-log|--mysql-slow-log)
      [[ "$MODE" = first ]] || fail "$option is only supported in first mode" ;;
    *) fail "unsupported $MODE helper option: $option" ;;
  esac
  [[ $((i + 1)) -lt ${#ENV_OPTIONS[@]} && -n "${ENV_OPTIONS[$((i + 1))]}" ]] || fail "$option requires a value"
  case "$option" in
    --app-dir|--app-service|--app-bin|--mysql-conf-dir|--nginx-access-log|--mysql-slow-log) literal "$option" "${ENV_OPTIONS[$((i + 1))]}" ;;
  esac
  i=$((i + 2))
done
show() { printf ' +'; printf ' %q' "$@"; printf '\n'; }
run() { show "$@"; [[ "$PLAN" = 1 ]] || "$@"; }
echo "== server $SERVER_ID: $MODE; home=$HOME_DIR =="
if [[ "$PLAN" = 0 ]]; then
  [[ "$(id -un)" = isucon ]] || fail "run as isucon (use sudo -iu isucon for an entry account)"
  [[ -d "$HOME_DIR" ]] || fail "home does not exist: $HOME_DIR"
  HOME_DIR=$(cd "$HOME_DIR" && pwd -P)
  [[ "$HOME_DIR" != / ]] || fail "home resolves to the filesystem root"
  if [[ "$MODE" = existing ]]; then
    [[ "$(git -C "$HOME_DIR" rev-parse --show-toplevel 2>/dev/null)" = "$HOME_DIR" ]] || fail "existing requires a Git repository rooted at --home"
    [[ -f "$HOME_DIR/config.mk" && -f "$HOME_DIR/Makefile" && -f "$HOME_DIR/scripts/init-repo.sh" ]] || fail "home initialization is incomplete; inspect Git state before resuming"
  else
    [[ ! -e "$HOME_DIR/.git" && ! -L "$HOME_DIR/.git" ]] || fail "home already has .git; inspect state, then use --mode existing after completing initialization"
  fi
fi
if [[ "$SKIP_KEYS" = 0 ]]; then run env "ENTRY_USER=$ENTRY_USER" bash "$SCRIPT_DIR/10-add-members-keys.sh"; fi
if [[ "$MODE" != existing ]]; then
  if [[ "$PLAN" = 1 || ! -e "$CLONE_DIR" ]]; then
    run git clone --branch "$ENV_REF" -- "$ENV_REPO" "$CLONE_DIR"
  fi
  if [[ "$PLAN" = 0 ]]; then
    actual=$(cd "$CLONE_DIR" && pwd -P)
    [[ "$(git -C "$CLONE_DIR" rev-parse --show-toplevel)" = "$actual" ]] || fail "clone-dir is not a separate Git checkout"
    [[ "$(git -C "$CLONE_DIR" config --get remote.origin.url)" = "$ENV_REPO" ]] || fail "existing template origin differs from --env-repo; select that URL explicitly"
    [[ -z "$(git -C "$CLONE_DIR" status --porcelain --untracked-files=no)" ]] || fail "template has uncommitted changes; commit or choose another clone-dir"
    [[ "$(git -C "$CLONE_DIR" rev-parse HEAD)" = "$(git -C "$CLONE_DIR" rev-parse --verify "$ENV_REF^{commit}")" ]] || fail "template HEAD does not match --env-ref; choose the correct checkout explicitly"
  fi
  if [[ "$MODE" = first ]]; then
    args=(--home "$HOME_DIR" --branch "$BRANCH" --remote "$REMOTE")
    case "$SCRIPT_DIR" in "$HOME_DIR"/*) args+=(--ignore "${SCRIPT_DIR#"$HOME_DIR"/}/") ;; esac
    run bash "$CLONE_DIR/scripts/init-repo.sh" ${args[@]+"${args[@]}"} ${ENV_OPTIONS[@]+"${ENV_OPTIONS[@]}"}
  else
    run bash "$CLONE_DIR/scripts/join-repo.sh" --home "$HOME_DIR" --branch "$BRANCH" --remote "$REMOTE" ${ENV_OPTIONS[@]+"${ENV_OPTIONS[@]}"}
  fi
fi
# Keep a custom setup clone out of the competition index on join as well as
# first. Never delete its .git or register it as a submodule.
if [[ "$PLAN" = 0 ]]; then
  case "$SCRIPT_DIR" in
    "$HOME_DIR"/*)
      pattern=$(printf '%s' "${SCRIPT_DIR#"$HOME_DIR"/}" | sed 's/[][\\*?!#]/\\&/g')
      printf '/%s/\n' "$pattern" >> "$HOME_DIR/.git/info/exclude"
      ;;
  esac
fi
if [[ "$SKIP_TOOLS" = 0 ]]; then
  tool_env=("ISUCON_HOME=$HOME_DIR")
  if [[ "$PLAN" = 0 ]]; then
    # Read Make's resolved values without sourcing the competition env.sh.
    logs=$(make --no-print-directory -s -C "$HOME_DIR" -f Makefile -f - __setup_log_paths <<'EOF'
__setup_log_paths:
	@printf '%s\n' '$(NGINX_ACCESS_LOG)' '$(MYSQL_SLOW_LOG)'
EOF
)
    nginx_log=${logs%%$'\n'*}; mysql_log=${logs#*$'\n'}
    literal NGINX_ACCESS_LOG "$nginx_log"; literal MYSQL_SLOW_LOG "$mysql_log"
    [[ "$nginx_log" = /* && "$mysql_log" = /* ]] || fail "log paths must be absolute"
    tool_env+=("NGINX_ACCESS_LOG=$nginx_log" "MYSQL_SLOW_LOG=$mysql_log")
  fi
  run env ${tool_env[@]+"${tool_env[@]}"} bash "$SCRIPT_DIR/30-install-tools.sh"
fi
if [[ "$SKIP_CONFIG" = 0 ]]; then
  echo '== Set SERVER_ID in home/env.sh; copy current nginx/MySQL/app unit/env.sh into the private competition repository =='
  run make -C "$HOME_DIR" "ISUCON_HOME=$HOME_DIR" "set-as-$SERVER_ID"
  run make -C "$HOME_DIR" "ISUCON_HOME=$HOME_DIR" get-conf
fi
echo '== Review Git status, config.mk, and backup reports. Commit/push explicitly when ready. =='
