#!/usr/bin/env bash

# === Usage === #
usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -config, --config <path>         Path to config file (default: $parent_path/.env)
  -c, --commit_message <message>   Commit message to use for this run
  -d, --debug                      Enable debug output
  -f, --fix                        Run preflight checks and exit
  -h, --help                       Show this help
EOF
}

# === Initialization === #
init() {
    # set dotglob so that bash treats hidden files/folders starting with . correctly when copying them
    shopt -s dotglob

    # Set parent directory path
    parent_path=$(
        cd "$(dirname "${BASH_SOURCE[0]}")"
        pwd -P
    )

    config_path="$parent_path/.env"
    original_args=("$@")

    # Parse config path first so we know which file to source for runtime values.
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        -config | --config)
            if [[ -z "$2" || "$2" =~ ^- ]]; then
                echo "Error: config path expected after $1" >&2
                exit 1
            fi
            config_path="${2/#\~/$HOME}"
            shift 2
            ;;
        *)
            shift
            ;;
        esac
    done

    if [[ ! -f "$config_path" ]]; then
        echo "Error: config file not found: $config_path" >&2
        exit 1
    fi

    source "$config_path"
    source "$parent_path"/utils/utils.func

    backup_folder="$branch_name-backup"
    backup_path="$HOME/$backup_folder"
    allow_empty_commits=${allow_empty_commits:-false}
    git_protocol=${git_protocol:-"https"}
    git_host=${git_host:-"github.com"}
    ssh_user=${ssh_user:-"git"}

    if [[ $git_protocol == "ssh" ]]; then
        full_git_url=$git_protocol"://"$ssh_user"@"$git_host"/"$github_username"/"$github_repository".git"
    else
        full_git_url=$git_protocol"://"$github_token"@"$git_host"/"$github_username"/"$github_repository".git"
    fi
    exclude=${exclude:-"*.swp" "*.tmp" "*.bak" "*.bkp" "*.csv" "*.zip"}
    commit_message_used=false
    debug_output=false
    fix_mode=false
    # Check parameters
    set -- "${original_args[@]}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -config | --config)
            shift 2
            ;;
        -f | --fix)
            fix_mode=true
            shift
            ;;
        -c | --commit_message)
            if [[ -z "$2" || "$2" =~ ^- ]]; then
                echo -e "${CL}${R}Error: commit message expected after $1${NC}" >&2
                exit 1
            else
                commit_message="$2"
                commit_message_used=true
                shift 2
            fi
            ;;
        -d | --debug)
            debug_output=true
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo -e "${CL}${R}Unknown option: $1${NC}"
            usage
            exit 1
            ;;
        esac
    done

    [[ "$debug_output" == true ]] && source "$parent_path"/utils/debug.func
}

# === Functions === #
fix() {
    fix_errors=()
    fix_warnings=()
    local dep
    local path
    local has_backup_paths=false

    if [[ -z "${github_username:-}" || "$github_username" == "USERNAME" ]]; then
        fix_errors+=("Missing required value: github_username")
    fi

    if [[ -z "${github_repository:-}" || "$github_repository" == "REPOSITORY" ]]; then
        fix_errors+=("Missing required value: github_repository")
    fi

    if [[ "$git_protocol" != "ssh" ]]; then
        if [[ -z "${github_token:-}" || "$github_token" == "ghp_xxxxxxxxxxxxxxxx" ]]; then
            fix_errors+=("Missing required value: github_token (required unless git_protocol=ssh)")
        fi
    fi

    for dep in git jq curl rsync; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            fix_errors+=("Missing required command: $dep")
        fi
    done

    if declare -p backupPaths >/dev/null 2>&1; then
        for path in "${backupPaths[@]}"; do
            if [[ -n "$path" ]]; then
                has_backup_paths=true
                break
            fi
        done
    fi

    if ! $has_backup_paths; then
        fix_warnings+=("backupPaths is empty. Backup runs will not include files.")
    fi

    if [[ ! -d "$HOME" ]]; then
        fix_errors+=("\$HOME does not exist or is not a directory: $HOME")
    elif [[ ! -r "$HOME" ]]; then
        fix_errors+=("\$HOME is not readable: $HOME")
    fi

    echo -e "${Y}●${NC} Running preflight checks..."

    if [[ ${#fix_warnings[@]} -gt 0 ]]; then
        local warning
        for warning in "${fix_warnings[@]}"; do
            echo -e "${Y}●${NC} Warning: $warning"
        done
    fi

    if [[ ${#fix_errors[@]} -gt 0 ]]; then
        local error
        for error in "${fix_errors[@]}"; do
            echo -e "${R}●${NC} Error: $error"
        done
        echo -e "${R}●${NC} Preflight failed.\n"
        return 1
    fi

    echo -e "${G}●${NC} Preflight passed.\n"
    return 0
}

checkUpdates() {
    local local_commit
    local upstream_ref
    local upstream_remote
    local upstream_branch
    local remote_commit

    local_commit=$(git -C "$parent_path" rev-parse HEAD 2>/dev/null || true)
    if [[ -z "$local_commit" ]]; then
        echo -e "${Y}●${NC} Unable to determine local project commit. Skipping update check.\n"
        return 0
    fi

    upstream_ref=$(git -C "$parent_path" rev-parse --abbrev-ref @{u} 2>/dev/null || true)
    if [[ -z "$upstream_ref" ]]; then
        echo -e "${Y}●${NC} No upstream configured for project repository. Skipping update check.\n"
        return 0
    fi

    upstream_remote="${upstream_ref%%/*}"
    upstream_branch="${upstream_ref#*/}"
    remote_commit=$(git -C "$parent_path" ls-remote "$upstream_remote" "$upstream_branch" 2>/dev/null | cut -f1 | head -n1)
    if [[ -z "$remote_commit" ]]; then
        echo -e "${Y}●${NC} Unable to resolve remote commit for $upstream_ref. Skipping update check.\n"
        return 0
    fi

    if [[ "$local_commit" == "$remote_commit" ]]; then
        echo -e "Up to date\n"
    else
        echo -e "${Y}●${NC} Update ${Y}Available!${NC}\n"
    fi
}

createBackupFolder() {
    if [ ! -d "$backup_path" ]; then
        mkdir -p "$backup_path"
    fi

    gotoBackupFolder

    if [ ! -d ".git" ]; then
        mkdir .git
        echo "[init]
    defaultBranch = "$branch_name"" >>.git/config #Add desired branch name to config before init
        git init
        git config pull.rebase false # configure default reconciliation when pulling
    # Check if the current checked out branch matches the branch name given in .env if not branch listed in .env
    elif [[ $(git symbolic-ref --short -q HEAD) != "$branch_name" ]]; then
        echo -e "Branch: $branch_name in .env does not match the currently checked out branch of: $(git symbolic-ref --short -q HEAD)."
        # Create branch if it does not exist
        if git show-ref --quiet --verify "refs/heads/$branch_name"; then
            git checkout "$branch_name" >/dev/null
        else
            git checkout -b "$branch_name" >/dev/null
        fi
    fi
    # Check if remote origin already exists and create if one does not
    if [ -z "$(git remote get-url origin 2>/dev/null)" ]; then
        git remote add origin "$full_git_url"
    fi

    # Check if remote origin changed and update when it is
    if [[ "$full_git_url" != $(git remote get-url origin) ]]; then
        git remote set-url origin "$full_git_url"
    fi

    # Check if branch exists on remote (newly created repos will not yet have a remote) and pull any new changes
    if git ls-remote --exit-code --heads origin $branch_name >/dev/null 2>&1; then
        git pull origin "$branch_name"
        # Delete the pulled files so that the directory is empty again before copying the new backup
        # The pull is only needed so that the repository nows its on latest and does not require rebases or merges
        find "$backup_path" -maxdepth 1 -mindepth 1 ! -name '.git' ! -name '.gitmodules' ! -name 'README.md' -exec rm -rf {} \;
    fi
}

checkEnv() {
    # # Check if .env is v1 version
    # if [[ ! -v backupPaths ]]; then
    #     echo ".env file is not using version 2 config, upgrading to V2"
    #     if bash $parent_path/utils/v1convert.sh; then
    #         echo "Upgrade complete restarting script.sh"
    #         sleep 2.5
    #         exec "$parent_path/script.sh" "$args"
    #     fi
    # fi
    # Check if username is defined in .env
    if [[ "$commit_username" != "" ]]; then
        git config user.name "$commit_username"
    else
        git config user.name "$(whoami)"
    fi

    # Check if email is defined in .env
    if [[ "$commit_email" != "" ]]; then
        git config user.email "$commit_email"
    else
        unique_id=$(date +%s%N | md5sum | head -c 7)
        user_email=$(whoami)@$(getHostnameShort)-$unique_id
        git config user.email "$user_email"
    fi
}

copyFiles() {
    # Iterate through backupPaths array and copy files to the backup folder while ignoring symbolic links
    for path in "${backupPaths[@]}"; do
        local search_pattern
        search_pattern="$HOME/$path"

        if [[ -d "$search_pattern" ]]; then
            if [[ "$search_pattern" =~ /$ ]]; then
                search_pattern="${search_pattern}*"
            else
                search_pattern="${search_pattern%/}/*"
            fi
        fi

        if compgen -G "$search_pattern" >/dev/null; then
            while IFS= read -r file; do
                if [[ -h "$file" ]]; then
                    echo "Skipping symbolic link: $file"
                elif find "$file" -regex '.*/\.git*' -print -quit | grep -q '.'; then
                    echo ".git folder: $file detected, don't add back to backup"
                else
                    local resolved_file
                    resolved_file=$(readlink -e "$file")
                    if [[ -z "$resolved_file" ]]; then
                        continue
                    fi
                    echo "Backing up: $resolved_file"
                    rsync -Rr "${resolved_file##"$HOME"/}" "$backup_path"
                fi
            done < <(compgen -G "$search_pattern")
        fi
    done

    # # Debug output: $backup_path content after running rsync
    # if [ "$debug_output" = true ]; then
    #     debug_backuppathafter
    # fi

    cp "$parent_path"/.gitignore "$backup_path/.gitignore"

    # utilize gits native exclusion file .gitignore to add files that should not be uploaded to remote.
    # Loop through exclude array and add each element to the end of .gitignore
    for i in "${exclude[@]}"; do
        # add new line to end of .gitignore if there is not one
        [[ $(tail -c1 "$backup_path/.gitignore" | wc -l) -eq 0 ]] && echo "" >>"$backup_path/.gitignore"
        echo "$i" >>"$backup_path/.gitignore"
    done
}

pre-commitCleanup() {
    git rm -r --cached . >/dev/null 2>&1
}

pushCommit() {
    # Individual commit message, if no parameter is set, use the current timestamp as commit message
    if ! $commit_message_used; then
        commit_message="New backup from $(date +"%x - %X")"
    fi
    git add .
    git commit -m "$commit_message"
    # Check if HEAD still matches remote (Means there are no updates to push) and create a empty commit just informing that there are no new updates to push
    if $allow_empty_commits && [[ $(git rev-parse HEAD) == $(git ls-remote $(git rev-parse --abbrev-ref @{u} 2>/dev/null | sed 's/\// /g') | cut -f1) ]]; then
        git commit --allow-empty -m "$commit_message - No new changes pushed"
    fi
    git push -u origin "$branch_name"
}

cleanUp() {
    find "$backup_path" -maxdepth 1 -mindepth 1 ! -name '.git' ! -name '.gitmodules' ! -name 'README.md' -exec rm -rf {} \;
}

# === Main === #
init "$@"
if $fix_mode; then
    fix
    exit $?
fi
commonDeps
checkUpdates
createBackupFolder
checkEnv
gotoHome
copyFiles
gotoBackupFolder
pre-commitCleanup
pushCommit
cleanUp
