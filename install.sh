#!/usr/bin/env bash
trap 'stty echo; exit' SIGINT

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -config, --config <path>   Path to config file.
                             Default resolution: ./install.conf then ./.env
  -d, --debug                Enable debug output
  -h, --help                 Show this help
EOF
}

is_true() {
    local value
    value=$(echo "${1:-false}" | tr '[:upper:]' '[:lower:]')
    [[ "$value" == "1" || "$value" == "true" || "$value" == "yes" || "$value" == "y" || "$value" == "on" ]]
}

to_abs_path() {
    local path
    path="${1/#\~/$HOME}"
    if [[ "$path" == /* ]]; then
        printf "%s\n" "$path"
        return
    fi

    if [[ -e "$path" ]]; then
        (
            cd "$(dirname "$path")"
            printf "%s/%s\n" "$(pwd -P)" "$(basename "$path")"
        )
    else
        printf "%s/%s\n" "$(pwd -P)" "$path"
    fi
}

escape_sed_replacement() {
    printf "%s" "$1" | sed -e 's/[\/&|]/\\&/g'
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -config | --config)
            if [[ -z "$2" || "$2" =~ ^- ]]; then
                echo -e "${R}●${NC} Error: config path expected after $1"
                exit 1
            fi
            config_path="$2"
            shift 2
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
            echo -e "${R}●${NC} Unknown option: $1"
            usage
            exit 1
            ;;
        esac
    done
}

load_defaults() {
    install_dir=$(to_abs_path "${install_dir:-$HOME/backuptoolbase}")
    repo_url="${repo_url:-https://github.com/Tylerjet/backuptoolbase.git}"
    auto_update_repo="${auto_update_repo:-true}"

    sync_config_to_install="${sync_config_to_install:-true}"
    target_config_path=$(to_abs_path "${target_config_path:-$install_dir/.env}")
    runtime_config_path="${runtime_config_path:-}"

    install_filewatch_service="${install_filewatch_service:-false}"
    install_on_boot_service="${install_on_boot_service:-false}"
    install_cron="${install_cron:-false}"
    install_inotify_tools="${install_inotify_tools:-true}"

    cron_schedule="${cron_schedule:-0 */4 * * *}"
    cron_commit_message="${cron_commit_message:-Cron backup}"

    git_protocol="${git_protocol:-https}"
    branch_name="${branch_name:-main}"
    commit_username="${commit_username:-$(whoami)}"
    commit_email="${commit_email:-$(whoami)@$(getHostnameShort)-$unique_id}"

    if ! declare -p backupPaths >/dev/null 2>&1; then
        backupPaths=()
    fi
}

validate_config() {
    if [[ -z "${github_repository:-}" || "$github_repository" == "REPOSITORY" ]]; then
        echo -e "${R}●${NC} Missing required value: github_repository"
        exit 1
    fi

    if [[ -z "${github_username:-}" || "$github_username" == "USERNAME" ]]; then
        echo -e "${R}●${NC} Missing required value: github_username"
        exit 1
    fi

    if [[ "$git_protocol" != "ssh" ]]; then
        if [[ -z "${github_token:-}" || "$github_token" == "ghp_xxxxxxxxxxxxxxxx" ]]; then
            echo -e "${R}●${NC} Missing required value: github_token (required unless git_protocol=ssh)"
            exit 1
        fi
    fi

    local has_backup_paths=false
    local path
    for path in "${backupPaths[@]}"; do
        if [[ -n "$path" ]]; then
            has_backup_paths=true
            break
        fi
    done

    if ! $has_backup_paths; then
        echo -e "${Y}●${NC} Warning: backupPaths is empty, backups will include no files."
    fi
}

init() {
    parent_path=$(
        cd "$(dirname "${BASH_SOURCE[0]}")"
        pwd -P
    )

    source "$parent_path/utils/utils.func"
    unique_id=$(getUniqueid)
    debug_output=false
    original_args=("$@")

    parse_args "$@"

    if [[ -z "${config_path:-}" ]]; then
        if [[ -f "$parent_path/install.conf" ]]; then
            config_path="$parent_path/install.conf"
        else
            config_path="$parent_path/.env"
        fi
    fi

    config_path=$(to_abs_path "$config_path")
    if [[ ! -f "$config_path" ]]; then
        echo -e "${R}●${NC} Config file not found: $config_path"
        exit 1
    fi

    source "$config_path"
    if [[ "$debug_output" == true ]]; then
        source "$parent_path/utils/install-debug.func"
        debug_install_context
    fi
    load_defaults
    validate_config
}

install_or_update_repo() {
    if [[ -d "$install_dir/.git" ]]; then
        if is_true "$auto_update_repo"; then
            echo -e "${Y}●${NC} Updating existing repository at $install_dir"
            if git -C "$install_dir" pull --ff-only >/dev/null 2>&1; then
                echo -e "${CL}${G}●${NC} Repository update ${G}Done!${NC}"
            else
                echo -e "${CL}${Y}●${NC} Repository update ${Y}Skipped${NC} (uncommitted or diverged changes)"
            fi
        else
            echo -e "${M}●${NC} Repository update ${M}Skipped!${NC}"
        fi
    elif [[ -d "$install_dir" && -n "$(ls -A "$install_dir" 2>/dev/null)" ]]; then
        echo -e "${R}●${NC} Install directory exists and is not empty: $install_dir"
        echo -e "${R}●${NC} Refusing to clone into a non-empty non-git directory."
        exit 1
    else
        echo -e "${Y}●${NC} Cloning repository to $install_dir"
        mkdir -p "$(dirname "$install_dir")"
        if git clone "$repo_url" "$install_dir" >/dev/null 2>&1; then
            echo -e "${CL}${G}●${NC} Repository clone ${G}Done!${NC}"
        else
            echo -e "${CL}${R}●${NC} Repository clone ${R}Failed!${NC}"
            exit 1
        fi
    fi

    chmod +x "$install_dir/script.sh" "$install_dir/install.sh" "$install_dir/utils/filewatch.sh" 2>/dev/null || true
}

prepare_runtime_config() {
    if is_true "$sync_config_to_install"; then
        mkdir -p "$(dirname "$target_config_path")"
        if [[ "$config_path" != "$target_config_path" ]]; then
            cp "$config_path" "$target_config_path"
        fi
        runtime_config_path="${runtime_config_path:-$target_config_path}"
        echo -e "${G}●${NC} Synced config to $target_config_path"
    else
        runtime_config_path="${runtime_config_path:-$config_path}"
        echo -e "${M}●${NC} Config sync ${M}Skipped${NC}; using $runtime_config_path directly."
    fi

    runtime_config_path=$(to_abs_path "$runtime_config_path")
    if [[ ! -f "$runtime_config_path" ]]; then
        echo -e "${R}●${NC} Runtime config file not found: $runtime_config_path"
        exit 1
    fi
}

install_inotify_tools_if_needed() {
    if command -v inotifywait >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${Y}●${NC} Installing inotify-tools"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update >/dev/null 2>&1
        sudo apt-get install -y inotify-tools >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y inotify-tools >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --noconfirm inotify-tools >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        sudo apk add inotify-tools >/dev/null 2>&1
    else
        echo -e "${R}●${NC} Unsupported package manager. Please install inotify-tools manually."
        return 1
    fi

    if command -v inotifywait >/dev/null 2>&1; then
        echo -e "${CL}${G}●${NC} Installing inotify-tools ${G}Done!${NC}"
    else
        echo -e "${R}●${NC} Failed to install inotify-tools."
        return 1
    fi
}

install_filewatch_service_func() {
    if is_true "$install_filewatch_service"; then
        if is_true "$install_inotify_tools"; then
            install_inotify_tools_if_needed || exit 1
        fi

        local service_file="/etc/systemd/system/backuptoolbase-filewatch.service"
        local template_file="$install_dir/install-files/backuptoolbase-filewatch.service"
        local exec_start
        local escaped_exec_start

        exec_start="/usr/bin/env bash \"$install_dir/utils/filewatch.sh\" -config \"$runtime_config_path\""
        escaped_exec_start=$(escape_sed_replacement "$exec_start")

        sudo systemctl stop backuptoolbase-filewatch.service >/dev/null 2>&1 || true
        sudo cp "$template_file" "$service_file"
        sudo sed -i "s/^After=.*/After=$(wantsafter)/" "$service_file"
        sudo sed -i "s/^Wants=.*/Wants=$(wantsafter)/" "$service_file"
        sudo sed -i "s/^User=.*/User=${SUDO_USER:-$USER}/" "$service_file"
        sudo sed -i "s|^ExecStart=.*|ExecStart=$escaped_exec_start|" "$service_file"
        sudo systemctl daemon-reload >/dev/null 2>&1
        sudo systemctl enable backuptoolbase-filewatch.service >/dev/null 2>&1
        sudo systemctl start backuptoolbase-filewatch.service >/dev/null 2>&1
        echo -e "${G}●${NC} Installing filewatch service ${G}Done!${NC}"
    else
        echo -e "${M}●${NC} Installing filewatch service ${M}Skipped!${NC}"
    fi
}

install_backup_service_func() {
    if is_true "$install_on_boot_service"; then
        local service_file="/etc/systemd/system/backuptoolbase-on-boot.service"
        local template_file="$install_dir/install-files/backuptoolbase-on-boot.service"
        local exec_start
        local escaped_exec_start

        exec_start="/usr/bin/env bash \"$install_dir/script.sh\" -config \"$runtime_config_path\" -c \"New Backup on boot\""
        escaped_exec_start=$(escape_sed_replacement "$exec_start")

        sudo systemctl stop backuptoolbase-on-boot.service >/dev/null 2>&1 || true
        sudo cp "$template_file" "$service_file"
        sudo sed -i "s/^After=.*/After=$(wantsafter)/" "$service_file"
        sudo sed -i "s/^Wants=.*/Wants=$(wantsafter)/" "$service_file"
        sudo sed -i "s/^User=.*/User=${SUDO_USER:-$USER}/" "$service_file"
        sudo sed -i "s|^ExecStart=.*|ExecStart=$escaped_exec_start|" "$service_file"
        sudo systemctl daemon-reload >/dev/null 2>&1
        sudo systemctl enable backuptoolbase-on-boot.service >/dev/null 2>&1
        sudo systemctl start backuptoolbase-on-boot.service >/dev/null 2>&1
        echo -e "${G}●${NC} Installing on-boot service ${G}Done!${NC}"
    else
        echo -e "${M}●${NC} Installing on-boot service ${M}Skipped!${NC}"
    fi
}

install_cron_func() {
    if is_true "$install_cron"; then
        local cron_commit_message_escaped
        local cron_entry
        local existing_cron
        local filtered_cron

        cron_commit_message_escaped=${cron_commit_message//\"/\\\"}
        cron_entry="$cron_schedule /usr/bin/env bash \"$install_dir/script.sh\" -config \"$runtime_config_path\" -c \"$cron_commit_message_escaped\""

        existing_cron=$(crontab -l 2>/dev/null || true)
        filtered_cron=$(printf "%s\n" "$existing_cron" | grep -vF "$install_dir/script.sh" || true)

        if [[ -n "$filtered_cron" ]]; then
            {
                printf "%s\n" "$filtered_cron"
                printf "%s\n" "$cron_entry"
            } | crontab -
        else
            printf "%s\n" "$cron_entry" | crontab -
        fi

        echo -e "${G}●${NC} Installing cron task ${G}Done!${NC}"
    else
        echo -e "${M}●${NC} Installing cron task ${M}Skipped!${NC}"
    fi
}

# === Main === #
{
    init "$@"
    sudo -v
    commonDeps
    install_or_update_repo
    prepare_runtime_config
    install_filewatch_service_func
    install_backup_service_func
    install_cron_func
    echo -e "${G}●${NC} Installation Complete!"
    echo -e "${G}●${NC} Runtime config: $runtime_config_path\n"
}
