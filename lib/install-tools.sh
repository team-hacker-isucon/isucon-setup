# shellcheck shell=bash
# Helpers shared by 30-install-tools.sh and its isolated regression tests.

apt_with_lock_retry() {
  local timeout=${APT_LOCK_WAIT_SECONDS:-300}
  local interval=${APT_LOCK_RETRY_SECONDS:-5}
  if [[ ! "$timeout" =~ ^[0-9]{1,5}$ || ! "$interval" =~ ^[0-9]{1,5}$ ]]; then
    echo "ERROR: APT_LOCK_WAIT_SECONDS/APT_LOCK_RETRY_SECONDS must be integers" >&2
    return 2
  fi
  timeout=$((10#$timeout))
  interval=$((10#$interval))
  if (( interval < 1 )); then
    echo "ERROR: APT_LOCK_RETRY_SECONDS must be positive" >&2
    return 2
  fi
  local deadline=$((SECONDS + timeout)) output rc remaining delay
  # apt 1.6 (Ubuntu 18.04) does not implement DPkg::Lock::Timeout.
  # Retry only EAGAIN/known lock-holder failures; never remove locks or kill owners.
  local busy='^E: Could not get lock .*(Resource temporarily unavailable|[Ii]t is held by process)'
  local lock_lines='^E: (Could not get lock .*|Unable to acquire the dpkg frontend lock .*|Unable to lock (directory|the administration directory) .*)$'
  while :; do
    if output=$(sudo LC_ALL=C DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get "$@" 2>&1); then
      printf '%s\n' "$output"
      return 0
    else
      rc=$?
    fi
    printf '%s\n' "$output" >&2
    if [[ "$rc" != 100 ]] || ! grep -Eq "$busy" <<<"$output" ||
       { grep '^E:' <<<"$output" | grep -Ev "$lock_lines" >/dev/null; }; then
      return "$rc"
    fi
    remaining=$((deadline - SECONDS))
    if (( remaining <= 0 )); then
      echo "ERROR: APT lock wait timed out after ${timeout}s; leave the lock owner running and retry later" >&2
      return "$rc"
    fi
    delay=$interval
    (( delay <= remaining )) || delay=$remaining
    echo "WARN: APT is locked; retrying in ${delay}s (up to ${remaining}s remaining)" >&2
    sleep "$delay"
  done
}

record_backup() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3"
  if [[ -n "${BACKUP_REPORT:-}" ]]; then
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$BACKUP_REPORT" ||
      echo "WARN: could not update backup report: $BACKUP_REPORT" >&2
  fi
}

backup_component() {
  local name=$1 base=$2 member=$3
  shift 3
  local archive="$BACKUP_DIR/backup-$TIMESTAMP-$name.tar.gz"
  local partial="$archive.partial" need_kb free_kb
  if ! need_kb=$(sudo du -sk "$base/$member" 2>/dev/null | awk 'NR==1 {print $1}') ||
     ! free_kb=$(df -Pk "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print $4}') ||
     [[ ! "$need_kb" =~ ^[0-9]+$ || ! "$free_kb" =~ ^[0-9]+$ ]]; then
    echo "WARN: backup skipped ($name): source size/free space unavailable" >&2
    record_backup "$name" skipped capacity-check-unavailable
    return 0
  fi
  if (( need_kb + 1024 * 1024 > free_kb )); then
    echo "WARN: backup skipped ($name): insufficient space (reserve: 1 GiB)" >&2
    record_backup "$name" skipped insufficient-space
    return 0
  fi
  if [[ -e "$archive" || -L "$archive" || -e "$partial" || -L "$partial" ]]; then
    echo "WARN: backup skipped ($name): destination already exists" >&2
    record_backup "$name" skipped destination-exists
    return 0
  fi
  # A full-home archive can contain private keys. Reserve a private regular file
  # before sudo writes it; do not depend on sudoers' umask or follow an existing link.
  if ! (umask 077; set -C; : > "$partial"); then
    echo "WARN: backup failed ($name): could not reserve a private archive" >&2
    record_backup "$name" failed destination-unavailable
    return 0
  fi
  echo "  - $name ..."
  if sudo tar -czf "$partial" "$@" -C "$base" "$member" && mv -- "$partial" "$archive"; then
    record_backup "$name" success "$archive"
  else
    echo "WARN: backup failed ($name); any incomplete archive is kept as $partial" >&2
    record_backup "$name" failed "$partial"
  fi
}

backup_before_install() {
  BACKUP_REPORT=
  if ! mkdir -p "$BACKUP_DIR"; then
    echo "WARN: backups skipped: cannot create $BACKUP_DIR; continuing tool installation" >&2
    return 0
  fi
  BACKUP_REPORT="$BACKUP_DIR/backup-$TIMESTAMP-report.txt"
  if ! : > "$BACKUP_REPORT"; then
    echo "WARN: backup report unavailable: $BACKUP_REPORT" >&2
    BACKUP_REPORT=
  fi
  backup_component mysql / var/lib/mysql
  backup_component nginx / etc/nginx
  backup_component systemd / etc/systemd/system
  # local/ contains this archive/report, so including it would recurse into itself.
  backup_component home-isucon "$ISUCON_HOME" . \
    --exclude=./local --exclude=./.git --exclude=./isucon-setup-logs
  [[ -z "$BACKUP_REPORT" ]] || echo "Backup results: $BACKUP_REPORT"
}
