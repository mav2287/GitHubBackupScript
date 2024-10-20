#!/bin/bash

# Other Variables
SILENT=0
ORPHAN_CLEANUP=0
MAX_RETRIES=3  # Maximum number of retries for failed operations
RETRY_DELAY=5  # Delay between retries
TEMP_KNOWN_HOSTS=$(mktemp)  # Temporary known_hosts file
SSH_KEY="${4:-}"  # Optionally pass SSH key path, or leave empty to use agent

# Parse command-line options
while getopts ":sc" opt; do
  case $opt in
    s) SILENT=1 ;;
    c) ORPHAN_CLEANUP=1 ;;
    \?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
  esac
done

# Shift parsed options to leave positional arguments
shift $((OPTIND-1))

# Set default backup directory to the script's parent directory if not passed
BACKUP_DIR="${1:-$(dirname "$(realpath "$0")")/github_backup}"
LOG_FILE="${2:-$BACKUP_DIR/backup_log.txt}"
ERROR_LOG_FILE="${BACKUP_DIR}/error_log.txt"  # New log to track long-term failures
REPOS_FILE="${BACKUP_DIR}/repos.txt"  # Consolidated repos list
ORPHAN_LOG="${3:-$BACKUP_DIR/orphaned_repos.txt}"

# Ensure backup, log, and orphan directories exist safely
ensure_directory_exists() {
    local dir=$1
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" || { echo "Failed to create directory: $dir" && exit 1; }
    fi
}

# Ensure the backup and log directories are ready
ensure_directory_exists "$BACKUP_DIR"
ensure_directory_exists "$(dirname "$LOG_FILE")"
ensure_directory_exists "$(dirname "$ERROR_LOG_FILE")"
ensure_directory_exists "$(dirname "$ORPHAN_LOG")"

# Function to log messages
log_message() {
    if [ "$SILENT" -eq 0 ]; then
        echo "$1"
    fi
    echo "$1" >> "$LOG_FILE"
}

# Function to log errors for long-term review
log_error() {
    echo "$1" >> "$ERROR_LOG_FILE"
}

# Function to check if commands exist
check_command() {
    command -v "$1" > /dev/null 2>&1 || {
        log_message "Error: $1 command not found. Please install $1."
        exit 1
    }
}

# Check for required commands (both gh and git)
check_command "gh"
check_command "git"
check_command "ssh-keyscan"

# Fetch GitHub keys once and store them in the temporary known_hosts file
fetch_github_keys() {
    GITHUB_KEYS=$(ssh-keyscan github.com 2>/dev/null)
    if [ -z "$GITHUB_KEYS" ]; then
        log_message "Error: Could not fetch GitHub keys."
        exit 1
    fi
    echo "$GITHUB_KEYS" > "$TEMP_KNOWN_HOSTS"
}

# Function to test SSH key authentication to GitHub
check_ssh_auth() {
    log_message "Checking SSH access to GitHub..."

    fetch_github_keys

    if [ -n "$SSH_KEY" ]; then
        ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$TEMP_KNOWN_HOSTS" -i "$SSH_KEY" -T git@github.com &>/dev/null
    else
        ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$TEMP_KNOWN_HOSTS" -T git@github.com &>/dev/null
    fi

    if [ $? -ne 1 ]; then
        log_message "Error: SSH authentication to GitHub failed. Ensure your SSH key is set up."
        cleanup_temp_ssh_config
        exit 1
    fi
    log_message "SSH authentication to GitHub successful."
}

# Function to set up the GIT_SSH_COMMAND using known_hosts and optional SSH key
setup_git_ssh_command() {
    if [ -n "$SSH_KEY" ]; then
        export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$TEMP_KNOWN_HOSTS -i $SSH_KEY"
    else
        export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$TEMP_KNOWN_HOSTS"
    fi
}

cleanup_temp_ssh_config() {
    if [ -n "$TEMP_KNOWN_HOSTS" ] && [ -f "$TEMP_KNOWN_HOSTS" ]; then
        rm -f "$TEMP_KNOWN_HOSTS"
    fi
}

# Detect the default branch of a repository
get_default_branch() {
    local repo_path=$1
    git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@'
}

# Generate a new folder name with DUPLICATE_# suffix if a folder already exists
generate_duplicate_folder() {
    local base_path=$1
    local counter=1

    while [ -d "${base_path}_DUPLICATE_${counter}" ]; do
        counter=$((counter + 1))
    done

    echo "${base_path}_DUPLICATE_${counter}"
}

# Function to safely escape repo and org/user names to avoid issues
escape_input() {
    local input="$1"
    echo "${input//[^a-zA-Z0-9_-]/_}"
}

# Function to handle cloning/updating repos with duplicate handling and retries
clone_or_update_repo() {
    local repo_name=$1
    local repo_url=$2
    local entity_dir=$3
    local retries=0
    local success=0
    local repo_path="$entity_dir/$repo_name"

    # Check if a folder with the same name already exists
    if [ -d "$repo_path" ]; then
        if [ ! -d "$repo_path/.git" ]; then
            log_message "Directory exists but is not a git repository. Renaming the folder."
            local new_repo_path
            new_repo_path=$(generate_duplicate_folder "$repo_path")
            mv "$repo_path" "$new_repo_path"
            repo_path="$new_repo_path"
            log_message "Renamed to $repo_path"
        fi
    fi

    while [ $retries -lt $MAX_RETRIES ]; do
        if [ ! -d "$repo_path/.git" ]; then
            log_message "Cloning $repo_name into $entity_dir..."
            if [ "$SILENT" -eq 1 ]; then
                if git clone "$repo_url" "$repo_path" &>/dev/null; then
                    success=1
                else
                    log_message "Error cloning $repo_name, retrying..."
                fi
            else
                if git clone "$repo_url" "$repo_path"; then
                    success=1
                else
                    log_message "Error cloning $repo_name, retrying..."
                fi
            fi
        else
            log_message "Fetching all branches for $repo_name..."
            if [ "$SILENT" -eq 1 ]; then
                if git -C "$repo_path" fetch --all &>/dev/null; then
                    success=1
                else
                    log_message "Error fetching branches for $repo_name, retrying..."
                fi
            else
                if git -C "$repo_path" fetch --all; then
                    success=1
                else
                    log_message "Error fetching branches for $repo_name, retrying..."
                fi
            fi
        fi

        if [ "$success" -eq 1 ]; then
            break
        fi

        retries=$((retries + 1))
        log_message "Retrying operation for $repo_name ($retries/$MAX_RETRIES)..."
        sleep "$RETRY_DELAY"
    done

    if [ "$success" -eq 0 ]; then
        log_message "Failed to sync repository $repo_name after $MAX_RETRIES attempts."
        log_error "Failed to sync repository $repo_name after $MAX_RETRIES attempts."
        if [ -d "$repo_path" ] && [ ! -d "$repo_path/.git" ]; then
            log_message "Cleaning up incomplete clone for $repo_name."
            rm -rf "$repo_path"
        fi
    fi
}

# Function to fetch and save repos to the repos.txt file
fetch_repos_with_limit() {
    local entity=$1
    local entity_type=$2
    local total_limit=5000

    log_message "Fetching repositories for $entity ($entity_type)..."
    if ! gh repo list "$entity" --limit "$total_limit" --json name,sshUrl --jq '.[] | "'"$entity_type"' ['"$entity"'] " + .name + " " + .sshUrl' >> "$REPOS_FILE"; then
        log_message "Failed to fetch repositories for $entity."
    fi
}

# Function to read repos from repos.txt and clone/update them
process_repos_from_file() {
    while IFS= read -r line; do
        # Parse the entry format: USER/ORG [name] repo_name repo_url
        local entity_type entity_name repo_name repo_url
        entity_type=$(echo "$line" | awk '{print $1}')
        entity_name=$(echo "$line" | awk '{print $2}' | sed 's/[][]//g')  # Remove brackets from the name
        repo_name=$(echo "$line" | awk '{print $3}')
        repo_url=$(echo "$line" | awk '{print $4}')

        # Escape any special characters to prevent issues
        entity_name=$(escape_input "$entity_name")
        repo_name=$(escape_input "$repo_name")

        local entity_dir="$BACKUP_DIR/$entity_name"
        ensure_directory_exists "$entity_dir"

        # Clone or update the repository in the appropriate directory
        clone_or_update_repo "$repo_name" "$repo_url" "$entity_dir"
    done < "$REPOS_FILE"
}

# Function to handle orphaned repositories by renaming them safely
log_orphaned_repos() {
    log_message "Logging orphaned repositories..."
    find "$BACKUP_DIR" -mindepth 2 -maxdepth 2 -type d | while IFS= read -r dir; do
        repo_name=$(basename "$dir")
        if ! grep -q "$repo_name" "$REPOS_FILE"; then
            log_message "Orphaned repo detected: $repo_name (renaming)"
            new_name="ORPHAN_$repo_name"
            mv "$dir" "$(dirname "$dir")/$new_name"
            echo "$new_name" >> "$ORPHAN_LOG"
        fi
    done
}

# Main function
main() {
    true > "$LOG_FILE" || true
    true > "$ERROR_LOG_FILE" || true  # Clear previous errors
    log_message "Backup started at $(date)"

    check_ssh_auth
    setup_git_ssh_command

    USER_NAME=$(gh api user --jq '.login' 2>/dev/null)
    if [ -z "$USER_NAME" ]; then
        log_message "Error: Unable to fetch GitHub user details. Exiting."
        cleanup_temp_ssh_config
        exit 1
    fi

    log_message "Authenticated as user: $USER_NAME"

    # Backup user repositories
    fetch_repos_with_limit "$USER_NAME" "USER"

    # Fetch and backup organization repositories
    ORG_LIST=$(gh api user/orgs --jq '.[].login' 2>/dev/null)
    for org in $ORG_LIST; do
        fetch_repos_with_limit "$org" "ORG"
    done

    # Process all repositories from the consolidated repos.txt file
    process_repos_from_file

    if [ "$ORPHAN_CLEANUP" -eq 1 ]; then
        log_orphaned_repos
    fi

    cleanup_temp_ssh_config
    log_message "Backup finished at $(date)"
}

# Parse command-line options
while getopts "sc" opt; do
    case $opt in
        s) SILENT=1 ;;
        c) ORPHAN_CLEANUP=1 ;;
        *) echo "Invalid option"; exit 1 ;;
    esac
done

# Run the main process
main