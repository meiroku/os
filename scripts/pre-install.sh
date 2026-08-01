#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="config.json"

for cmd in jq lsblk awk grep; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        printf "[!] Error: '%s' command is required but not installed.\n" "$cmd" >&2
        exit 1
    fi
done

if [ ! -f "$CONFIG_FILE" ]; then
    printf "[!] Error: %s not found in the current directory.\n" "$CONFIG_FILE" >&2
    exit 1
fi

TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT

printf "[?] Please select the disk to install the OS on (e.g. /dev/sda):\n\n"

mapfile -t DISK_LIST < <(lsblk -d -n -p -o NAME,SIZE,MODEL | grep -v -E "loop|airootfs|zram|rom" || true)

if [ ${#DISK_LIST[@]} -eq 0 ]; then
    printf "[!] No disks found. Exiting.\n" >&2
    exit 1
fi

for i in "${!DISK_LIST[@]}"; do
    printf "%d. %s\n" "$((i + 1))" "${DISK_LIST[i]}"
done
printf "\n"

while true; do
    read -rp "[?] Enter the number corresponding to the disk: " DISK_INDEX
    if [[ "$DISK_INDEX" =~ ^[0-9]+$ ]] && [ "$DISK_INDEX" -ge 1 ] && [ "$DISK_INDEX" -le "${#DISK_LIST[@]}" ]; then
        SELECTED_DISK=$(printf "%s" "${DISK_LIST[DISK_INDEX-1]}" | awk '{print $1}')
        printf "[*] Selected disk: %s\n" "$SELECTED_DISK"
        break
    else
        printf "[!] Invalid selection. Please try again.\n" >&2
    fi
done

printf "\n[*] Calculating disk size...\n\n"

TOTAL_BYTES=$(lsblk -b -n -o SIZE "$SELECTED_DISK" | awk 'NR==1{print $1}')

if [[ ! "$TOTAL_BYTES" =~ ^[0-9]+$ ]]; then
    printf "[!] Error: Failed to retrieve the size of %s.\n" "$SELECTED_DISK" >&2
    exit 1
fi

START_BYTES=1074790400
MARGIN=2097152
BTRFS_SIZE=$(( TOTAL_BYTES - START_BYTES - MARGIN ))

printf "  Target     : %s\n" "$SELECTED_DISK"
printf "  Total Size : %d bytes\n" "$TOTAL_BYTES"
printf "  BTRFS Size : %d bytes\n\n" "$BTRFS_SIZE"

if [ "$BTRFS_SIZE" -le 0 ]; then
    printf "[!] Not enough space on the selected disk. Exiting.\n" >&2
    exit 1
fi

printf "[*] Configuration file (%s) will be updated.\n\n" "$CONFIG_FILE"

jq --arg dev "$SELECTED_DISK" \
   --argjson size "$BTRFS_SIZE" '
   .disk_config.device_modifications[0].device = $dev |
   .disk_config.device_modifications[0].partitions[1].size.value = $size
' "$CONFIG_FILE" > "$TMP_FILE"

if [ -s "$TMP_FILE" ]; then
    cat "$TMP_FILE" > "$CONFIG_FILE"
else
    printf "[!] Error: jq output is empty. %s was not modified.\n" "$CONFIG_FILE" >&2
    exit 1
fi

printf "[+] Done! %s has been optimized.\n" "$CONFIG_FILE"
