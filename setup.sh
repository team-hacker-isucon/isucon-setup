#!/usr/bin/env bash
# Run on a team member's computer. No credentials are accepted as argument values.
set -euo pipefail
usage() {
  cat <<'EOF'
Usage: ./setup.sh --mode first|join|existing --server HOST:s1 [--server HOST:s2 ...] [options] [-- SERVER_OPTIONS...]
  --config FILE             Load a local Bash configuration before CLI overrides
  --deploy-key FILE         Registered deploy private key; content is sent over SSH stdin
  --skip-deploy-key         Keep the server's existing Git authentication
  --home PATH               Competition Git root (default: /home/isucon)
  --entry-user USER         Extra public-key recipient for server script 10
  --setup-repo URL          Setup clone URL (default: https://github.com/team-hacker-isucon/isucon-setup.git)
  --setup-ref REF           Setup branch/tag to clone (default: main)
  --setup-clone-dir PATH    Server setup clone (default: HOME/isucon-setup)
  --backup-dir PATH         Local backup output directory (default: this clone/backup)
  --skip-backup             Skip the local initial backup (server helpers still try theirs)
  --env-repo URL / --env-ref REF / --clone-dir PATH
                            Template repository, ref, and server clone directory
  --branch NAME / --remote URL
                            Competition branch and origin
  --app-dir PATH / --app-service NAME / --app-bin NAME
                            First-server application settings
  --mysql-conf-dir PATH / --nginx-access-log PATH / --mysql-slow-log PATH
                            First-server configuration and log paths
  --ignore PATTERN          First-server extra ignore; repeatable (replaces config list)
  --archive-dir PATH / --skip-archive / --max-file-size-mib N
                            Helper backup settings / first-server size threshold
  --skip-keys / --skip-tools / --skip-config
                            Skip a server setup stage
  --plan                    Print actions without SSH, copies, or file changes
All options can be supplied directly. The legacy -- SERVER_OPTIONS -- ENV_OPTIONS
syntax is also accepted. CLI values override configuration regardless of the
position of --config. See setup.conf.example for supported configuration fields.
Configuration is sourced as Bash, including in --plan; use only trusted files.
first accepts one server only. After reviewing and manually pushing its history,
run join for the other servers. existing resumes keys/tools/config on an already
initialized home. SSH user/IP/authentication come from ~/.ssh/config; --entry-user
only selects script 10's extra authorized_keys account. Non-isucon SSH sessions
need passwordless sudo to run the server steps as isucon.
Deploy keys are installed in the isucon account's actual home. A different existing
key is never overwritten. Repository URLs must not include tokens/passwords.
This command never pushes, deploys config, or restarts competition services.
EOF
}
fail() { echo "ERROR: $*" >&2; exit 1; }
value() { [[ $# -ge 2 && -n "$2" ]] || fail "$1 requires a value"; }
literal() { [[ -n "$2" && "$2" != *[!a-zA-Z0-9_./:@+-]* ]] || fail "$1 accepts ASCII letters/digits and _./:@+- only"; }
repository() {
  [[ -n "$2" && "$2" != -* && "$2" != *$'\n'* && "$2" != *$'\r'* ]] || fail "invalid $1"
  case "$2" in http://*@*|https://*@*|*://*:*@*|*'?'*|*'#'*) fail "repository URLs must not contain credentials, queries, or fragments" ;; esac
}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
MODE= KEY_FILE= SKIP_KEY=0 HOME_DIR=/home/isucon ENTRY_USER=
SETUP_REPO=https://github.com/team-hacker-isucon/isucon-setup.git SETUP_REF=main SETUP_CLONE_DIR=
BACKUP_DIR=$SCRIPT_DIR/backup SKIP_BACKUP=0 PLAN=0 SERVERS=() IDS=() SERVER_OPTIONS=()
ENV_REPO= ENV_REF= CLONE_DIR= BRANCH= REMOTE= SKIP_KEYS=0 SKIP_TOOLS=0 SKIP_CONFIG=0
APP_DIR= APP_SERVICE= APP_BIN= MYSQL_CONF_DIR= NGINX_ACCESS_LOG= MYSQL_SLOW_LOG=
ARCHIVE_DIR= SKIP_ARCHIVE=0 MAX_FILE_SIZE_MIB= EXTRA_IGNORES=()
ISUCON_HOME=$HOME_DIR DEPLOY_KEY_FILE= SKIP_DEPLOY_KEY=0 CONFIG_FILE=
# Load configuration before parsing overrides, regardless of --config's position.
CLI_ARGS=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      value "$@"; [[ -z "$CONFIG_FILE" ]] || fail "only one --config is supported"
      CONFIG_FILE=$2; shift 2 ;;
    --) break ;;
    -h|--help) usage; exit 0 ;;
    --skip-deploy-key|--skip-backup|--skip-keys|--skip-tools|--skip-config|--skip-archive|--plan) shift ;;
    *) value "$@"; shift 2 ;;
  esac
done
if [[ -n "$CONFIG_FILE" ]]; then
  [[ -f "$CONFIG_FILE" && -r "$CONFIG_FILE" ]] || fail "cannot read configuration: $CONFIG_FILE"
  CONFIG_FILE=$(cd "$(dirname "$CONFIG_FILE")" && pwd -P)/$(basename "$CONFIG_FILE")
  # Explicitly selected local Bash code. Never source configuration from a server.
  source "$CONFIG_FILE"
  HOME_DIR=$ISUCON_HOME KEY_FILE=$DEPLOY_KEY_FILE SKIP_KEY=$SKIP_DEPLOY_KEY
  # Local paths in config are relative to its directory; CLI paths use cwd.
  for name in KEY_FILE BACKUP_DIR; do
    if [[ -n "${!name}" && "${!name}" != /* ]]; then
      printf -v "$name" '%s/%s' "${CONFIG_FILE%/*}" "${!name}"
    fi
  done
fi
set -- ${CLI_ARGS[@]+"${CLI_ARGS[@]}"}
SCOPE=local CLI_KEY_MODE= CLI_IGNORES=0 FIRST_CLI_OPTIONS=0 HELPER_CLI_OPTIONS=0 SERVER_PLAN=0
while [[ $# -gt 0 ]]; do
  if [[ "$SCOPE" != local ]]; then
    case "$1" in
      --config|--mode|--server|--home|--entry-user|--deploy-key|--skip-deploy-key|--setup-repo|--setup-ref|--setup-clone-dir|--backup-dir|--skip-backup)
        fail "$1 must be supplied to setup.sh directly" ;;
    esac
  fi
  case "$1" in
    --config) value "$@"; shift 2 ;;
    --mode) value "$@"; MODE=$2; shift 2 ;;
    --server)
      value "$@"; item=$2; host=${item%:*}; sid=${item##*:}
      [[ "$host" != "$item" && -n "$host" && "$host" != -* && "$host" != *[!a-zA-Z0-9_.@-]* ]] || fail "--server requires SSH_HOST:s1|s2|s3"
      case "$sid" in s1|s2|s3) ;; *) fail "--server requires SSH_HOST:s1|s2|s3" ;; esac
      for old in ${SERVERS[@]+"${SERVERS[@]}"}; do [[ "$old" != "$host" ]] || fail "duplicate server: $host"; done
      for old in ${IDS[@]+"${IDS[@]}"}; do [[ "$old" != "$sid" ]] || fail "duplicate server ID: $sid"; done
      SERVERS+=("$host"); IDS+=("$sid"); shift 2 ;;
    --deploy-key)
      value "$@"; [[ "$CLI_KEY_MODE" != skip ]] || fail "--deploy-key and --skip-deploy-key are mutually exclusive"
      CLI_KEY_MODE=deploy KEY_FILE=$2 SKIP_KEY=0; shift 2 ;;
    --skip-deploy-key)
      [[ "$CLI_KEY_MODE" != deploy ]] || fail "--deploy-key and --skip-deploy-key are mutually exclusive"
      CLI_KEY_MODE=skip SKIP_KEY=1 KEY_FILE=; shift ;;
    --home) value "$@"; HOME_DIR=$2; shift 2 ;;
    --entry-user) value "$@"; ENTRY_USER=$2; shift 2 ;;
    --setup-repo) value "$@"; SETUP_REPO=$2; shift 2 ;;
    --setup-ref) value "$@"; SETUP_REF=$2; shift 2 ;;
    --setup-clone-dir) value "$@"; SETUP_CLONE_DIR=$2; shift 2 ;;
    --backup-dir) value "$@"; BACKUP_DIR=$2; shift 2 ;;
    --skip-backup) SKIP_BACKUP=1; shift ;;
    --env-repo) value "$@"; ENV_REPO=$2; shift 2 ;;
    --env-ref) value "$@"; ENV_REF=$2; shift 2 ;;
    --clone-dir) value "$@"; CLONE_DIR=$2; shift 2 ;;
    --branch) value "$@"; BRANCH=$2; shift 2 ;;
    --remote) value "$@"; REMOTE=$2; shift 2 ;;
    --skip-keys) SKIP_KEYS=1; shift ;;
    --skip-tools) SKIP_TOOLS=1; shift ;;
    --skip-config) SKIP_CONFIG=1; shift ;;
    --app-dir|--app-service|--app-bin|--mysql-conf-dir|--nginx-access-log|--mysql-slow-log|--max-file-size-mib)
      value "$@"; FIRST_CLI_OPTIONS=1
      case "$1" in
        --app-dir) APP_DIR=$2 ;; --app-service) APP_SERVICE=$2 ;; --app-bin) APP_BIN=$2 ;;
        --mysql-conf-dir) MYSQL_CONF_DIR=$2 ;; --nginx-access-log) NGINX_ACCESS_LOG=$2 ;;
        --mysql-slow-log) MYSQL_SLOW_LOG=$2 ;; --max-file-size-mib) MAX_FILE_SIZE_MIB=$2 ;;
      esac
      shift 2 ;;
    --ignore)
      value "$@"; FIRST_CLI_OPTIONS=1
      if [[ "$CLI_IGNORES" = 0 ]]; then EXTRA_IGNORES=(); CLI_IGNORES=1; fi
      EXTRA_IGNORES+=("$2"); shift 2 ;;
    --archive-dir) value "$@"; ARCHIVE_DIR=$2; HELPER_CLI_OPTIONS=1; shift 2 ;;
    --skip-archive) SKIP_ARCHIVE=1; HELPER_CLI_OPTIONS=1; shift ;;
    --plan)
      if [[ "$SCOPE" = local ]]; then PLAN=1; else SERVER_PLAN=1; fi
      shift ;;
    -h|--help) usage; exit 0 ;;
    --)
      case "$SCOPE" in local) SCOPE=server ;; server) SCOPE=helper ;; *) fail "unexpected --" ;; esac
      shift ;;
    *) fail "unknown option: $1" ;;
  esac
done
case "$MODE" in first|join|existing) ;; *) fail "--mode first|join|existing is required" ;; esac
[[ "$MODE" = first || "$FIRST_CLI_OPTIONS" = 0 ]] || fail "application settings and --ignore are only supported in first mode"
[[ "$MODE" != existing || "$HELPER_CLI_OPTIONS" = 0 ]] || fail "existing accepts no helper backup options"
for name in SKIP_KEY SKIP_BACKUP SKIP_KEYS SKIP_TOOLS SKIP_CONFIG SKIP_ARCHIVE; do
  case "${!name}" in 0|1) ;; *) fail "$name must be 0 or 1" ;; esac
done
[[ ${#SERVERS[@]} -gt 0 ]] || fail "at least one --server HOST:sN is required"
[[ "$MODE" != first || ${#SERVERS[@]} -eq 1 ]] || fail "first accepts one server; push its reviewed history before join on the others"
literal --home "$HOME_DIR"
HOME_DIR=${HOME_DIR%/}
[[ "$HOME_DIR" = /* && -n "$HOME_DIR" ]] || fail "--home must be absolute and must not be /"
SETUP_CLONE_DIR=${SETUP_CLONE_DIR:-$HOME_DIR/isucon-setup}
literal --setup-clone-dir "$SETUP_CLONE_DIR"
[[ "$SETUP_CLONE_DIR" = /* && "$SETUP_CLONE_DIR" != / && "$SETUP_CLONE_DIR" != "$HOME_DIR" ]] || fail "invalid --setup-clone-dir"
for path in "$HOME_DIR" "$SETUP_CLONE_DIR"; do
  case "/${path#/}/" in */../*|*/./*) fail "paths must not contain . or .. components" ;; esac
done
literal --setup-ref "$SETUP_REF"; [[ "$SETUP_REF" != -* ]] || fail "invalid --setup-ref"
repository --setup-repo "$SETUP_REPO"
[[ -z "$ENTRY_USER" ]] || { literal --entry-user "$ENTRY_USER"; [[ "$ENTRY_USER" != -* && "$ENTRY_USER" != */* ]] || fail "invalid entry user"; }
if [[ "$SKIP_KEY" = 0 ]]; then
  [[ -n "$KEY_FILE" && -f "$KEY_FILE" && -r "$KEY_FILE" && -s "$KEY_FILE" ]] || fail "provide --deploy-key FILE or --skip-deploy-key"
else
  [[ -z "$KEY_FILE" ]] || fail "--deploy-key and --skip-deploy-key are mutually exclusive"
fi
# Normalize both invocation styles into the server/helper argument arrays.
for name in ENV_REPO REMOTE; do
  [[ -z "${!name}" ]] || repository "$name" "${!name}"
done
for name in ENV_REF CLONE_DIR BRANCH; do
  [[ -z "${!name}" ]] || literal "$name" "${!name}"
done
for setting in env-repo:ENV_REPO env-ref:ENV_REF clone-dir:CLONE_DIR branch:BRANCH remote:REMOTE; do
  name=${setting#*:}
  if [[ -n "${!name}" ]]; then SERVER_OPTIONS+=("--${setting%%:*}" "${!name}"); fi
done
[[ "$SKIP_KEYS" = 0 ]] || SERVER_OPTIONS+=(--skip-keys)
[[ "$SKIP_TOOLS" = 0 ]] || SERVER_OPTIONS+=(--skip-tools)
[[ "$SKIP_CONFIG" = 0 ]] || SERVER_OPTIONS+=(--skip-config)
[[ "$SERVER_PLAN" = 0 ]] || SERVER_OPTIONS+=(--plan)
ENV_OPTIONS=()
if [[ "$MODE" = first ]]; then
  for setting in app-dir:APP_DIR app-service:APP_SERVICE app-bin:APP_BIN mysql-conf-dir:MYSQL_CONF_DIR nginx-access-log:NGINX_ACCESS_LOG mysql-slow-log:MYSQL_SLOW_LOG max-file-size-mib:MAX_FILE_SIZE_MIB; do
    name=${setting#*:}
    if [[ -n "${!name}" ]]; then
      literal "$name" "${!name}"
      ENV_OPTIONS+=("--${setting%%:*}" "${!name}")
    fi
  done
  for pattern in ${EXTRA_IGNORES[@]+"${EXTRA_IGNORES[@]}"}; do ENV_OPTIONS+=(--ignore "$pattern"); done
fi
if [[ "$MODE" != existing ]]; then
  [[ -z "$ARCHIVE_DIR" ]] || ENV_OPTIONS+=(--archive-dir "$ARCHIVE_DIR")
  [[ "$SKIP_ARCHIVE" = 0 ]] || ENV_OPTIONS+=(--skip-archive)
fi
if [[ ${#ENV_OPTIONS[@]} -gt 0 ]]; then
  SERVER_OPTIONS+=(-- ${ENV_OPTIONS[@]+"${ENV_OPTIONS[@]}"})
fi
show() { printf ' +'; printf ' %q' "$@"; printf '\n'; }
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
# SSH joins command arguments as shell text. Single-quote for a POSIX login
# shell, then quote the whole command again for bash -c under sudo.
quote_arg() {
  local escaped=${1//\'/\'\\\'\'}
  printf "'%s'" "$escaped"
}
quote_command() {
  local arg
  for arg in "$@"; do quote_arg "$arg"; printf ' '; done
}
as_isucon() {
  local quoted
  quoted=$(quote_arg "$1")
  printf 'if [ "$(id -un)" = isucon ]; then bash -c %s; else sudo -n -H -u isucon bash -c %s; fi' "$quoted" "$quoted"
}
if [[ "$SKIP_BACKUP" = 0 ]]; then
  show env "REMOTE_HOME=$HOME_DIR" "OUT_DIR=$BACKUP_DIR" bash "$SCRIPT_DIR/00-local-backup.sh" ${SERVERS[@]+"${SERVERS[@]}"}
  if [[ "$PLAN" = 0 ]]; then
    env "REMOTE_HOME=$HOME_DIR" "OUT_DIR=$BACKUP_DIR" bash "$SCRIPT_DIR/00-local-backup.sh" ${SERVERS[@]+"${SERVERS[@]}"} || echo 'WARN: local backup failed or partial; continuing. Review backup output before relying on recovery.' >&2
  fi
fi
KEY_INSTALL_SCRIPT=$(cat <<'EOF'
set -euo pipefail
umask 077
[[ ! -L "$HOME/.ssh" ]] || { echo 'ERROR: .ssh is a symlink; inspect it before installing a key' >&2; exit 1; }
install -d -m 700 "$HOME/.ssh"
tmp=$(mktemp "$HOME/.ssh/.setup-deploy-key.XXXXXX")
trap 'rm -f "$tmp"' EXIT
cat > "$tmp"
chmod 600 "$tmp"
dest="$HOME/.ssh/id_ed25519"
[[ ! -L "$dest" ]] || { echo 'ERROR: existing deploy key is a symlink' >&2; exit 1; }
if [[ -e "$dest" ]]; then
  cmp -s "$tmp" "$dest" || { echo 'ERROR: a different deploy key already exists; it was not overwritten' >&2; exit 1; }
  chmod 600 "$dest"
  echo 'deploy key already installed (same content)'
else
  # Same-filesystem hard link publishes the complete 600-mode key atomically.
  # If another process created dest after the check, ln fails without replacing it.
  ln "$tmp" "$dest"
  echo 'deploy key installed'
fi
EOF
)
printf '== setup clone: repo=%s ref=%s dir=%s ==\n' "$SETUP_REPO" "$SETUP_REF" "$SETUP_CLONE_DIR"
for ((i=0; i<${#SERVERS[@]}; i++)); do
  host=${SERVERS[$i]}; sid=${IDS[$i]}
  echo "== $host ($sid): $MODE =="
  if [[ "$SKIP_KEY" = 0 ]]; then
    echo " + install deploy key from file to isucon account over SSH stdin (existing different key: stop)"
    [[ "$PLAN" = 1 ]] || ssh ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} "$host" "$(as_isucon "$KEY_INSTALL_SCRIPT")" < "$KEY_FILE"
  fi
  args=(bash "$SETUP_CLONE_DIR/setup-server.sh" --mode "$MODE" --server-id "$sid" --home "$HOME_DIR")
  [[ -z "$ENTRY_USER" ]] || args+=(--entry-user "$ENTRY_USER")
  args+=(${SERVER_OPTIONS[@]+"${SERVER_OPTIONS[@]}"})
  bootstrap=$(cat <<'EOF'
set -euo pipefail
export GIT_SSH_COMMAND=${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10}
clone=$1; repo=$2; ref=$3; shift 3
if [[ ! -e "$clone" ]]; then
  git clone --branch "$ref" -- "$repo" "$clone"
fi
actual=$(cd "$clone" && pwd -P)
[[ "$(git -C "$clone" rev-parse --show-toplevel)" = "$actual" ]] || { echo 'ERROR: setup clone-dir is not a separate checkout' >&2; exit 1; }
[[ "$(git -C "$clone" config --get remote.origin.url)" = "$repo" ]] || { echo 'ERROR: setup origin differs from --setup-repo; select that URL explicitly' >&2; exit 1; }
[[ -z "$(git -C "$clone" status --porcelain --untracked-files=no)" ]] || { echo 'ERROR: setup checkout has uncommitted changes' >&2; exit 1; }
[[ "$(git -C "$clone" rev-parse HEAD)" = "$(git -C "$clone" rev-parse --verify "$ref^{commit}")" ]] || { echo 'ERROR: setup HEAD does not match --setup-ref; checkout the correct ref explicitly' >&2; exit 1; }
[[ -f "$clone/setup-server.sh" ]] || { echo 'ERROR: setup ref does not contain setup-server.sh; publish/select the runner branch first' >&2; exit 1; }
exec "$@"
EOF
)
  command=$(quote_command bash -c "$bootstrap" setup-bootstrap "$SETUP_CLONE_DIR" "$SETUP_REPO" "$SETUP_REF" ${args[@]+"${args[@]}"})
  show ssh ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} "$host" ${args[@]+"${args[@]}"}
  [[ "$PLAN" = 1 ]] || ssh ${SSH_OPTS[@]+"${SSH_OPTS[@]}"} "$host" "$(as_isucon "$command")"
done
echo '== Finished. Review each server before any manual commit/push or deployment. =='
