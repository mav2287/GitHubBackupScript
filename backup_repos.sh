#!/usr/bin/env bash
#
# GitHub Backup Script (non-destructive, rename-aware, snapshotting)
#
# - Clones/updates repos into BACKUP_DIR/<owner>/<repo>
# - Refreshes repo list every run (use --no-refresh to reuse)
# - Rename-aware via stable GitHub repo "id" (GraphQL node ID)
# - Transport: SSH by default, or HTTPS with --https
# - Filters: --owners CSV (limit to these owners), --skip CSV (exclude owners)
# - Non-destructive: no deletions, no pruning
# - Safety snapshots: before each fetch, saves refs/remotes/origin/* to refs/paxbackup/<timestamp>/*
# - Retention: keep last --retain <N> snapshot sets per repo (default 60)
# - **State/logs are stored in backup_state/ (separate from repo backups)**
#
# Usage:
#   ./backup_repos.sh [-s] [-c] [--no-refresh] [--https] [--owners o1,o2] [--skip o3,o4] [--retain N] [BACKUP_DIR] [LOG_FILE] [ORPHAN_LOG] [SSH_KEY]
#
# Defaults:
#   BACKUP_DIR     = <script_dir>/github_backup
#   STATE_DIR      = <script_dir>/backup_state
#   LOG_FILE       = $STATE_DIR/backup_log.txt
#   ERROR_LOG_FILE = $STATE_DIR/error_log.txt
#   REPOS_TSV      = $STATE_DIR/repos.tsv            (id<TAB>owner<TAB>name<TAB>ssh_url<TAB>https_url)
#   MAP_TSV        = $STATE_DIR/repo_map.tsv         (id<TAB>abs_path<TAB>owner/name<TAB>remote_url)
#   ORPHAN_LOG     = $STATE_DIR/orphaned_repos.txt
#
# Requires: gh, git; ssh-keyscan (only if using SSH)
# Notes: Designed to be non-destructive. No deletes, no --prune. Snapshots are cheap pointers;
#        real extra space only accrues when upstream rewrites history.

set -euo pipefail

# ------------------------ Flags & Positional Args ------------------------

SILENT=0
ORPHAN_LOG_ONLY=0          # with -c we only log orphans; no changes
REFRESH_LIST=1             # default: refresh every run; --no-refresh toggles off
USE_HTTPS=0                # default: SSH transport
OWNERS_CSV=""              # explicit owners only (users or orgs), comma-separated
SKIP_CSV=""                # owners to exclude from discovery, comma-separated
MAX_RETRIES=3
RETRY_DELAY=5
SNAPSHOT_RETAIN=60         # keep last N snapshot sets per repo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/backup_state"
TEMP_KNOWN_HOSTS="$(mktemp)"
SSH_KEY="${4:-}"  # 4th positional arg if provided

# Parse flags / options (order-agnostic)
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) SILENT=1; shift ;;
    -c) ORPHAN_LOG_ONLY=1; shift ;;
    --no-refresh) REFRESH_LIST=0; shift ;;
    --https) USE_HTTPS=1; shift ;;
    --owners) OWNERS_CSV="${2:-}"; shift 2 ;;
    --skip)   SKIP_CSV="${2:-}"; shift 2 ;;
    --retain) SNAPSHOT_RETAIN="${2:-60}"; shift 2 ;;
    --) shift; break ;;
    -*)
      echo "Invalid option: $1" >&2
      exit 1
      ;;
    *) break ;;
  esac
done

# Remaining = positional args
BACKUP_DIR="${1:-"$SCRIPT_DIR/github_backup"}"
LOG_FILE="${2:-"$STATE_DIR/backup_log.txt"}"
ERROR_LOG_FILE="${STATE_DIR}/error_log.txt"
REPOS_TSV="${STATE_DIR}/repos.tsv"         # id\towner\tname\tssh_url\thttps_url
MAP_TSV="${STATE_DIR}/repo_map.tsv"        # id\tabs_path\towner/name\tremote_url
ORPHAN_LOG="${3:-"$STATE_DIR/orphaned_repos.txt"}"

# ------------------------ Utilities ------------------------

ensure_directory_exists() {
  local dir=$1
  [[ -d "$dir" ]] || mkdir -p "$dir"
}

log_message() {
  [[ "$SILENT" -eq 0 ]] && echo "$1"
  echo "$1" >> "$LOG_FILE"
}

log_error() {
  echo "$1" >> "$ERROR_LOG_FILE"
}

check_command() {
  command -v "$1" >/dev/null 2>&1 || { echo "Error: $1 not found. Please install $1." >&2; exit 1; }
}

cleanup_temp_ssh_config() {
  [[ -n "${TEMP_KNOWN_HOSTS:-}" && -f "$TEMP_KNOWN_HOSTS" ]] && rm -f "$TEMP_KNOWN_HOSTS"
}

fetch_github_keys() {
  local keys
  keys="$(ssh-keyscan github.com 2>/dev/null || true)"
  [[ -n "$keys" ]] || { log_message "Error: Could not fetch GitHub host keys."; exit 1; }
  echo "$keys" > "$TEMP_KNOWN_HOSTS"
}

check_ssh_auth() {
  [[ "$USE_HTTPS" -eq 1 ]] && return 0  # skip SSH probe in HTTPS mode
  log_message "Checking SSH access to GitHub..."
  fetch_github_keys
  # GitHub typically exits 1 on a successful auth probe (no interactive shell).
  set +e
  if [[ -n "$SSH_KEY" ]]; then
    ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$TEMP_KNOWN_HOSTS" -i "$SSH_KEY" -T git@github.com &>/dev/null
  else
    ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$TEMP_KNOWN_HOSTS" -T git@github.com &>/dev/null
  fi
  local ec=$?
  set -e
  if [[ "$ec" -eq 1 ]]; then
    log_message "SSH authentication to GitHub looks good."
  else
    log_message "Error: SSH authentication to GitHub failed (exit $ec). Ensure your SSH key/agent is set up."
    cleanup_temp_ssh_config
    exit 1
  fi
}

setup_git_transport_env() {
  if [[ "$USE_HTTPS" -eq 1 ]]; then
    unset GIT_SSH_COMMAND
  else
    if [[ -n "$SSH_KEY" ]]; then
      export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$TEMP_KNOWN_HOSTS -i $SSH_KEY"
    else
      export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$TEMP_KNOWN_HOSTS"
    fi
  fi
}

escape_input() {
  local input="$1"
  # Allow alnum, dash, underscore, dot; replace others with "_"
  echo "${input//[^a-zA-Z0-9._-]/_}"
}

contains_csv() { # contains_csv "a,b,c" "b" -> 0 if found
  local csv="$1" needle="$2"
  IFS=',' read -r -a arr <<< "$csv"
  for x in "${arr[@]}"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

# ------------------------ Owner Discovery ------------------------

build_owner_list() {
  OWNERS=()
  if [[ -n "$OWNERS_CSV" ]]; then
    IFS=',' read -r -a OWNERS <<< "$OWNERS_CSV"
    return 0
  fi

  local USER_NAME
  USER_NAME="$(gh api user --jq '.login' 2>/dev/null || true)"
  [[ -n "$USER_NAME" ]] || { log_message "Error: Unable to fetch GitHub user via gh."; exit 1; }

  if [[ -z "$SKIP_CSV" || $(contains_csv "$SKIP_CSV" "$USER_NAME"; echo $?) -ne 0 ]]; then
    OWNERS+=("$USER_NAME")
  fi

  while read -r org; do
    [[ -z "$org" ]] && continue
    if [[ -z "$SKIP_CSV" || $(contains_csv "$SKIP_CSV" "$org"; echo $?) -ne 0 ]]; then
      OWNERS+=("$org")
    fi
  done < <(gh api user/orgs --jq '.[].login' 2>/dev/null || true)
}

# ------------------------ Repo List & Map ------------------------

refresh_repo_list() {
  : > "$REPOS_TSV"
  build_owner_list
  log_message "Owners to back up: ${OWNERS[*]}"

  for owner in "${OWNERS[@]}"; do
    gh repo list "$owner" --limit 5000 --json name,owner,sshUrl,id,nameWithOwner \
      --jq '.[] | [.id, .owner.login, .name, .sshUrl, ("https://github.com/" + .nameWithOwner + ".git")] | @tsv' \
      >> "$REPOS_TSV"
  done

  # Dedupe by repo ID (field 1)
  awk -F'\t' '!seen[$1]++' "$REPOS_TSV" > "${REPOS_TSV}.tmp" && mv "${REPOS_TSV}.tmp" "$REPOS_TSV"
  log_message "Repo list contains $(wc -l < "$REPOS_TSV") unique repositories."
}

seed_map_from_local() {
  [[ -s "$MAP_TSV" ]] && return 0
  : > "$MAP_TSV"

  while IFS= read -r repo_path; do
    [[ -d "$repo_path/.git" ]] || continue
    local origin_url
    origin_url="$(git -C "$repo_path" remote get-url origin 2>/dev/null || true)"
    if [[ "$origin_url" =~ github.com[:/]+([^/]+)/([^/.]+)(\.git)?$ ]]; then
      local owner="${BASH_REMATCH[1]}"
      local name="${BASH_REMATCH[2]}"
      local rid
      rid="$(gh repo view "${owner}/${name}" --json id --jq '.id' 2>/dev/null || true)"
      [[ -n "$rid" ]] || continue
      local abs_path
      abs_path="$(cd "$repo_path" && pwd)"
      echo -e "${rid}\t${abs_path}\t${owner}/${name}\t${origin_url}" >> "$MAP_TSV"
    fi
  done < <(find "$BACKUP_DIR" -mindepth 2 -maxdepth 2 -type d 2>/dev/null || true)
}

lookup_map_path_by_id() {
  local id="$1"
  awk -F'\t' -v id="$id" '$1==id {print $2; exit}' "$MAP_TSV" 2>/dev/null || true
}

upsert_map_row() {
  local id="$1" path="$2" full="$3" url="$4"
  local tmp="${MAP_TSV}.tmp"
  if [[ -s "$MAP_TSV" ]] && awk -F'\t' -v id="$id" '$1==id {found=1} END{exit !found}' "$MAP_TSV"; then
    awk -F'\t' -v OFS='\t' -v id="$id" -v p="$path" -v f="$full" -v u="$url" \
      '{ if ($1==id) {print id,p,f,u} else {print $0} }' "$MAP_TSV" > "$tmp" && mv "$tmp" "$MAP_TSV"
  else
    echo -e "${id}\t${path}\t${full}\t${url}" >> "$MAP_TSV"
  fi
}

# ------------------------ Snapshot / Retention ------------------------

snapshot_remote_refs() {
  local repo="$1"
  local ts
  ts="$(date +"%Y%m%d-%H%M%S")"
  # Save each origin ref to refs/paxbackup/<ts>/<branch>
  git -C "$repo" for-each-ref 'refs/remotes/origin/*' --format='%(refname:short) %(objectname)' \
    | while read -r shortref sha; do
        local branch="${shortref#origin/}"
        git -C "$repo" update-ref "refs/paxbackup/${ts}/${branch}" "$sha"
      done
}

prune_old_snapshots() {
  local repo="$1" keep="$2"
  # List all snapshot refs, extract timestamp dir names, unique & sorted desc
  local tmp_ts="${repo}/.pax_ts.$$"
  git -C "$repo" for-each-ref --format='%(refname)' 'refs/paxbackup/*' 2>/dev/null \
    | awk -F'/' 'NF>=4 {print $3}' | sort -r | awk '!seen[$0]++' > "$tmp_ts"

  local count=0
  while read -r ts; do
    [[ -z "$ts" ]] && continue
    count=$((count+1))
    if (( count > keep )); then
      git -C "$repo" for-each-ref --format='%(refname)' "refs/paxbackup/${ts}/*" \
        | while read -r ref; do
            git -C "$repo" update-ref -d "$ref"
          done
    fi
  done < "$tmp_ts"
  rm -f "$tmp_ts"
}

apply_repo_safety_config() {
  local repo="$1"
  # Make history sticky; avoid automatic garbage-collection
  git -C "$repo" config fetch.prune false
  git -C "$repo" config gc.auto 0
  git -C "$repo" config gc.pruneExpire never
  git -C "$repo" config gc.reflogExpire "3650.days"
  git -C "$repo" config gc.reflogExpireUnreachable "3650.days"
}

# ------------------------ Clone / Update ------------------------

remote_url_for() {
  local ssh_url="$1" https_url="$2"
  if [[ "$USE_HTTPS" -eq 1 ]]; then
    echo "$https_url"
  else
    echo "$ssh_url"
  fi
}

safe_clone_or_fetch() {
  local abs_path="$1" remote_url="$2" label="$3"

  local retries=0 success=0
  while [[ $retries -lt $MAX_RETRIES ]]; do
    if [[ ! -d "$abs_path/.git" ]]; then
      ensure_directory_exists "$(dirname "$abs_path")"
      log_message "Cloning $label ..."
      if git clone "$remote_url" "$abs_path" >/dev/null 2>&1; then
        success=1
        apply_repo_safety_config "$abs_path"
      else
        log_message "Clone failed for $label, will retry..."
      fi
    else
      log_message "Snapshotting remote refs for $label ..."
      snapshot_remote_refs "$abs_path"
      prune_old_snapshots "$abs_path" "$SNAPSHOT_RETAIN"

      log_message "Fetching $label ..."
      # Non-destructive: NO --prune
      if git -C "$abs_path" fetch --all >/dev/null 2>&1; then
        success=1
      else
        log_message "Fetch failed for $label, will retry..."
      fi
    fi

    [[ $success -eq 1 ]] && return 0
    retries=$((retries+1))
    log_message "Retry $retries/$MAX_RETRIES after ${RETRY_DELAY}s for $label..."
    sleep "$RETRY_DELAY"
  done

  # If we created a non-git dir, keep it but mark as FAILED_*
  if [[ -d "$abs_path" && ! -d "$abs_path/.git" ]]; then
    local n=1 newpath
    while true; do
      newpath="$(dirname "$abs_path")/FAILED_${n}_$(basename "$abs_path")"
      [[ ! -e "$newpath" ]] && break
      n=$((n+1))
    done
    mv "$abs_path" "$newpath"
    log_message "Left failed attempt at: $newpath"
  fi
  log_message "Failed to sync $label after $MAX_RETRIES attempts."
  log_error   "Failed to sync $label after $MAX_RETRIES attempts."
  return 1
}

ensure_remote_url() {
  local abs_path="$1" remote_url="$2"
  if [[ -d "$abs_path/.git" ]]; then
    local current
    current="$(git -C "$abs_path" remote get-url origin 2>/dev/null || true)"
    if [[ "$current" != "$remote_url" ]]; then
      git -C "$abs_path" remote set-url origin "$remote_url" >/dev/null 2>&1 || true
    fi
  fi
}

process_all_repos() {
  while IFS=$'\t' read -r rid owner name ssh_url https_url; do
    [[ -z "$rid" || -z "$owner" || -z "$name" ]] && continue
    local remote_url
    remote_url="$(remote_url_for "$ssh_url" "$https_url")"

    local owner_dir repo_dir
    owner_dir="$(escape_input "$owner")"
    repo_dir="$(escape_input "$name")"
    local desired_path="${BACKUP_DIR}/${owner_dir}/${repo_dir}"
    local label="${owner}/${name}"

    # If we already know where this repo lives, use that path (handles renames)
    local known_path
    known_path="$(lookup_map_path_by_id "$rid")"
    local target_path="${known_path:-$desired_path}"

    # Ensure origin URL matches selected transport/URL
    ensure_remote_url "$target_path" "$remote_url"

    # Clone or fetch (with snapshots before fetch)
    safe_clone_or_fetch "$target_path" "$remote_url" "$label" || continue

    # Record / update mapping
    local abs_path
    abs_path="$(cd "$target_path" && pwd)"
    upsert_map_row "$rid" "$abs_path" "$owner/$name" "$remote_url"
  done < "$REPOS_TSV"
}

# ------------------------ Orphan Logging ------------------------

log_orphans_if_requested() {
  [[ "$ORPHAN_LOG_ONLY" -eq 1 ]] || return 0
  log_message "Scanning for orphans (local repos not present in the refreshed list)..."
  : > "$ORPHAN_LOG"

  local ids_file="${STATE_DIR}/.current_ids"
  awk -F'\t' '{print $1}' "$REPOS_TSV" > "$ids_file"

  awk -F'\t' 'NR==FNR {seen[$1]=1; next} { if (!seen[$1]) print $0 }' "$ids_file" "$MAP_TSV" \
    | while IFS=$'\t' read -r rid path full remote; do
        echo -e "$rid\t$full\t$path" >> "$ORPHAN_LOG"
      done

  rm -f "$ids_file"
  log_message "Orphan scan complete. Logged to $ORPHAN_LOG (no changes made)."
}

# ------------------------ Main ------------------------

main() {
  ensure_directory_exists "$BACKUP_DIR"
  ensure_directory_exists "$STATE_DIR"
  ensure_directory_exists "$(dirname "$LOG_FILE")"
  ensure_directory_exists "$(dirname "$ERROR_LOG_FILE")"
  ensure_directory_exists "$(dirname "$ORPHAN_LOG")"

  : > "$LOG_FILE" || true
  : > "$ERROR_LOG_FILE" || true

  log_message "Backup started at $(date)"

  check_command gh
  check_command git
  if [[ "$USE_HTTPS" -ne 1 ]]; then
    check_command ssh-keyscan
  fi

  check_ssh_auth
  setup_git_transport_env

  if [[ $REFRESH_LIST -eq 1 || ! -s "$REPOS_TSV" ]]; then
    refresh_repo_list
  else
    log_message "Reusing existing repo list: $REPOS_TSV"
    awk -F'\t' '!seen[$1]++' "$REPOS_TSV" > "${REPOS_TSV}.tmp" && mv "${REPOS_TSV}.tmp" "$REPOS_TSV"
  fi

  seed_map_from_local
  process_all_repos
  log_orphans_if_requested

  cleanup_temp_ssh_config
  log_message "Backup finished at $(date)"
}

main
