#!/usr/bin/env bash

parent_path=$(
    cd "$(dirname "${BASH_SOURCE[0]}")/.."
    pwd -P
)
config_path="$parent_path/.env"

while [[ $# -gt 0 ]]; do
    case "$1" in
    -config | --config)
        if [[ -z "$2" || "$2" =~ ^- ]]; then
            echo "Error: config path expected after $1" >&2
            exit 1
        fi
        config_path="${2/#\~/$HOME}"
        shift 2
        ;;
    -h | --help)
        echo "Usage: $(basename "$0") [-config <path>]"
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
    esac
done

if [[ ! -f "$config_path" ]]; then
    echo "Error: config file not found: $config_path" >&2
    exit 1
fi

source "$config_path"
watchlist=""
for path in "${backupPaths[@]}"; do
    for file in $path; do
        if [ ! -h "$file" ]; then
            file_dir=$(dirname "$file")
            if [ "$file_dir" = "." ]; then
                watchlist+=" $HOME/$file"
            else
                watchlist+=" $HOME/$file_dir"
            fi
        fi
    done
done

watchlist=$(echo "$watchlist" | tr ' ' '\n' | sort -u | tr '\n' ' ')

# Convert exclude array to string delimitted by "|"
excludeString=$(printf "|%s" "${exclude[@]}")
excludeString="${excludeString:1}"
excludeString=$(echo "$excludeString" | sed 's/\*\./\./g')

if [[ -z "$extraFilewatchExclude" ]]; then
    exclude_pattern="$excludeString"
else
    exclude_pattern="$excludeString|$extraFilewatchExclude"
fi

if [[ -z "$watchlist" ]]; then
    echo "No watch paths configured in backupPaths. Exiting."
    exit 0
fi

inotifywait -mrP -e close_write -e move -e delete --exclude "$exclude_pattern" $watchlist |
    while read -r path event file; do
        if [ -z "$file" ]; then
            file=$(basename "$path")
        fi
        echo "Event Type: $event, Watched Path: $path, File Name: $file"
        /usr/bin/env bash "$parent_path/script.sh" -config "$config_path" -c "$file modified - $(date +'%x - %X')" >/dev/null 2>&1
    done
