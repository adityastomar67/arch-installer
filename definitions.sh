#!/usr/bin/env bash

## --- color and output helpers ----------------------------------------------

# Prefer tput when available for portability; otherwise fall back to ANSI escapes.
# Colors can be disabled by setting NO_COLOR=1 or when stdout is not a tty.
_colors_init() {
    # detect whether we should use colors
    if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then
        USE_COLORS=0
    else
        USE_COLORS=1
    fi

    # helper to get SGR sequence (tput if possible)
    _tput() {
        local cap="$1"
        if command -v tput >/dev/null 2>&1; then
            tput "$cap" 2>/dev/null || true
        else
            # fallback mapping for common capabilities when tput missing
            case "$cap" in
                bold) printf '\033[1m' ;;
                smul) printf '\033[4m' ;;   # underline
                rev)  printf '\033[7m' ;;
                setaf) ;; # handled below with color number
            esac
        fi
    }

    # use tput setaf/setab if available, otherwise default ANSI codes
    if command -v tput >/dev/null 2>&1; then
        CLR_RESET="$(_tput sgr0)"
        CLR_BOLD="$(_tput bold)"
        CLR_UNDER="$(_tput smul)"
        CLR_RED="$(_tput setaf 1)"
        CLR_GREEN="$(_tput setaf 2)"
        CLR_YELLOW="$(_tput setaf 3)"
        CLR_BLUE="$(_tput setaf 4)"
        CLR_PURPLE="$(_tput setaf 5)"
        CLR_WHITE="$(_tput setaf 7)"
        CLR_TAN="$CLR_YELLOW"   # tput doesn't give tan; reuse yellow
        CLR_BRIGHT_GREEN="$(printf '%b' "${CLR_BOLD}${CLR_GREEN}")"
    else
        # ANSI fallback
        CLR_RESET='\033[0m'
        CLR_BOLD='\033[1m'
        CLR_UNDER='\033[4m'
        CLR_RED='\033[0;31m'
        CLR_GREEN='\033[1;32m'
        CLR_YELLOW='\033[0;33m'
        CLR_BLUE='\033[0;34m'
        CLR_PURPLE='\033[0;35m'
        CLR_WHITE='\033[0;37m'
        CLR_TAN="$CLR_YELLOW"
        CLR_BRIGHT_GREEN="${CLR_BOLD}${CLR_GREEN}"
    fi

    # If colors are disabled, make all sequences empty
    if (( USE_COLORS == 0 )); then
        CLR_RESET=''
        CLR_BOLD=''
        CLR_UNDER=''
        CLR_RED=''
        CLR_GREEN=''
        CLR_YELLOW=''
        CLR_BLUE=''
        CLR_PURPLE=''
        CLR_WHITE=''
        CLR_TAN=''
        CLR_BRIGHT_GREEN=''
    fi

    # Export short, friendly names to match your prior variables (but corrected)
    WHITE="${CLR_WHITE}"
    PURPLE="${CLR_PURPLE}"
    RED="${CLR_RED}"
    GREEN="${CLR_GREEN}"
    BRIGHT_GREEN="${CLR_BRIGHT_GREEN}"
    TAN="${CLR_TAN}"
    YELLOW="${CLR_YELLOW}"
    BLUE="${CLR_BLUE}"
    BOLD="${CLR_BOLD}"
    UNDERLINE="${CLR_UNDER}"
    RESET="${CLR_RESET}"

    # associative map for programmatic access (Bash 4+)
    if declare -p COLORS >/dev/null 2>&1; then :; fi
    declare -gA COLORS=(
        [white]="$WHITE" [purple]="$PURPLE" [red]="$RED" [green]="$GREEN"
        [bright_green]="$BRIGHT_GREEN" [tan]="$TAN" [yellow]="$YELLOW"
        [blue]="$BLUE" [bold]="$BOLD" [underline]="$UNDERLINE" [reset]="$RESET"
    )
}

# Call init early so variables exist
_colors_init

# Print a colored message: colorize "green" "text"
colorize() {
    local color="$1"; shift
    local text="$*"
    local seq="${COLORS[$color]:-}"
    printf "%b%s%b\n" "${seq}" "${text}" "${RESET}"
}

# Common helpers
_info()    { colorize purple "$@"; }   # neutral info
_success() { colorize green "$@"; }
_warn()    { colorize yellow "Warning: $*"; }
_error()   { colorize red "Error: $*"; >&2; }

# Examples:
# _info "This is an info line"
# _warn "This partition will be erased"
# _error "Bad selection" && exit 1

# ---------------- helpers for device selection ------------------------------
# list devices via lsblk in a nice, parseable way (name + rest)
_list_devices() {
    local  ="$1"
    if [[ "$type" == "disk" ]]; then
        lsblk -dn -o NAME,SIZE,MODEL 2>/dev/null | sed 's/  */ /g'
    else
        lsblk -dn -o NAME,SIZE,MOUNTPOINT 2>/dev/null | sed 's/  */ /g'
    fi
}

# choose_partition "prompt" type(disk|part) allow_none(yes|no)
choose_partition() {
    local prompt="$1"; local type="$2"; local allow_none="${3:-no}"
    local -a raw
    mapfile -t raw < <(_list_devices "$type")
    if ((${#raw[@]} == 0)); then
        _warn "No devices found for type: $type"
        return 1
    fi

    # build labelled options
    local -a opts=()
    for line in "${raw[@]}"; do
        local name="${line%% *}"
        local rest="${line#${name}}"
        rest="${rest#" "}"
        opts+=("${name} — ${rest}")
    done
    if [[ "$allow_none" == "yes" ]]; then
        opts+=("None")
    fi

    # PS3 must contain raw escape sequences (no newline) for colorized prompt
    local ps3_prefix="${COLORS[purple]}"
    local ps3_suffix="${COLORS[reset]}"
    PS3="${ps3_prefix}${prompt}${ps3_suffix} "

    local choice
    select choice in "${opts[@]}"; do
        if [[ -n "$choice" ]]; then
            if [[ "$choice" == "None" ]]; then
                echo "None"
                return 0
            fi
            # return /dev/<name>
            local dev="$(awk '{print $1}' <<<"$choice")"
            echo "/dev/${dev}"
            return 0
        else
            _warn "Invalid selection. Please choose a valid number."
        fi
    done
}

# ---------------- optimized setup_variables --------------------------------
setup_variables() {
    # show disks for root selection
    # echo
    _info "\nChoose the device you want to install Arch Linux on:"
    _error "NOTE: The chosen device will be completely erased and all its data will be lost!"
    # echo
    _warn "\nAvailable disks:"
    lsblk -dn -o NAME,SIZE,MODEL | sed 's/  */ /g'
    echo

    # Root device
    ROOT_DEVICE=""
    ROOT_DEVICE="$(choose_partition "Select root disk (number):" disk no)" || {
        _error "Failed to select a root device."; return 1
    }
    if [[ -z "$ROOT_DEVICE" ]]; then
        _error "No root device selected. Aborting."
        return 1
    fi
    export ROOT_DEVICE
    _success "Root device -> ${ROOT_DEVICE}"

    # Windows partition (optional)
    header 2>/dev/null || true
    _info "Choose your Windows partition to setup dual-boot (or choose None):"
    WIN_CHOICE="$(choose_partition "Select Windows partition (number):" part yes)" || WIN_CHOICE="None"
    if [[ "$WIN_CHOICE" == "None" || -z "$WIN_CHOICE" ]]; then
        unset WIN_DEVICE
        _info "No Windows partition selected."
    else
        WIN_DEVICE="$WIN_CHOICE"
        export WIN_DEVICE
        _success "Windows partition -> ${WIN_DEVICE}"
    fi

    # Storage partition (optional)
    header 2>/dev/null || true
    _info "Choose an extra partition to use as Storage (or choose None):"
    STRG_CHOICE="$(choose_partition "Select Storage partition (number):" part yes)" || STRG_CHOICE="None"
    if [[ "$STRG_CHOICE" == "None" || -z "$STRG_CHOICE" ]]; then
        unset STRG_DEVICE
        _info "No storage partition selected."
    else
        STRG_DEVICE="$STRG_CHOICE"
        export STRG_DEVICE
        _success "Storage partition -> ${STRG_DEVICE}"
    fi

    # Username
    header 2>/dev/null || true
    while true; do
        read -rp "$(printf '%b' "${COLORS[purple]}Enter your username:${COLORS[reset]} ")" USR
        if [[ -z "${USR:-}" ]]; then
            _warn "Username cannot be empty."
            continue
        fi
        if [[ ! "$USR" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            _warn "Invalid username. Use lowercase letters, numbers, '-', '_' and start with a letter or underscore."
            continue
        fi
        export USR
        _success "Username -> ${USR}"
        break
    done

    # Password
    while true; do
        printf "%b" "${COLORS[purple]}Enter your password:${COLORS[reset]} "
        read -rs PASSWD; echo
        printf "%b" "${COLORS[purple]}Re-enter your password:${COLORS[reset]} "
        read -rs CONF_PASSWD; echo
        if [[ "$PASSWD" != "$CONF_PASSWD" ]]; then
            _warn "Passwords don't match. Try again."
            continue
        fi
        if (( ${#PASSWD} < 6 )); then
            _warn "Password must be at least 6 characters long."
            continue
        fi
        export PASSWD
        _success "Password set."
        break
    done

    # Hostname
    header 2>/dev/null || true
    while true; do
        read -rp "$(printf '%b' "${COLORS[purple]}Enter this machine's hostname:${COLORS[reset]} ")" HOSTNAME
        if [[ -z "${HOSTNAME:-}" ]]; then
            _warn "Hostname cannot be empty."
            continue
        fi
        export HOSTNAME
        _success "Hostname -> ${HOSTNAME}"
        break
    done

    # Dotfiles question
    header 2>/dev/null || true
    _info "Do you want to install dotfiles?:"
    PS3="${COLORS[purple]}Choose (1-2): ${COLORS[reset]}"
    select DOTFILES in "Yes" "No"; do
        if [[ -n "${DOTFILES:-}" ]]; then
            export DOTFILES
            _success "Dotfiles -> ${DOTFILES}"
            break
        fi
    done

    # Wifi detection
    WIFI="n"
    if lspci -d ::280 >/dev/null 2>&1; then
        WIFI="y"
    fi
    export WIFI
    _info "WiFi card detected: ${WIFI}"

    # Desktop environment selection (ENVIRONMENTS must be defined)
    header 2>/dev/null || true
    if [[ -z "${ENVIRONMENTS[*]:-}" ]]; then
        _error "ENVIRONMENTS array is empty. Define available DEs in ENVIRONMENTS before running."
        return 1
    fi
    _info "Choose your desktop environment:"
    PS3="${COLORS[purple]}Select DE (number): ${COLORS[reset]}"
    PS3=$'\n> ' # restore a neutral PS3 for later prompts
    select DE in "${ENVIRONMENTS[@]}"; do
        if [[ -n "${DE:-}" ]]; then
            export DE
            _success "DE -> ${DE}"
            break
        else
            _warn "Invalid selection."
        fi
    done

    # ensure ENVIRONMENTS exists
    if [[ -z "${ENVIRONMENTS[*]:-}" ]]; then
        _error "No desktop environments defined. Aborting."
        return 1
    fi

    _info "Choose your desktop environment:"
    PS3="${COLORS[purple]}Select DE (number): ${COLORS[reset]}"
    PS3=$'\n> ' # restore a neutral PS3 for later prompts
    select DE in "${ENVIRONMENTS[@]}"; do
        if [[ -n "${DE:-}" ]]; then
            export DE
            _success "Desktop Environment selected -> ${DE}"
            break
        else
            _warn "Invalid selection. Please try again."
        fi
    done

    # lowercase key for package lookup and assembly
    DE_KEY="${DE,,}"   # e.g. "GNOME" -> "gnome"

    # build final package list (include general APPS if you want, here "Yes" for example)
    assemble_packages "$DE_KEY" "Yes"

    # Write variables to vars.sh safely (values quoted)
    cat > vars.sh <<-EOL
		# autogenerated by setup_variables
		export DE="${DE}"
		export USR="${USR}"
		export PASSWD="${PASSWD}"
		export HOSTNAME="${HOSTNAME}"
		export WIFI="${WIFI}"
		export DOTFILES="${DOTFILES}"
	EOL
    chmod 600 vars.sh
    # remove in-memory password copy
    unset PASSWD CONF_PASSWD

    print_summary 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Example: define ENVIRONMENTS before calling setup_variables
# ENVIRONMENTS=( "i3" "gnome" "plasma" "xfce" )
# setup_variables

print_summary() {
    # show header if available
    header 2>/dev/null || true
    echo

    # Title
    printf "%b" "${COLORS[underline]:-}"
    _info "Summary:-"
    printf "%b" "${COLORS[reset]:-}"
    echo

    # Strong warning about root device
    printf "%b" "${COLORS[bold]:-}${COLORS[red]:-}"
    printf "The installer will erase all data on the "
    printf "%b%s%b\n" "${COLORS[yellow]:-}" "${ROOT_DEVICE:-<not selected>}" "${COLORS[reset]:-}"

    # Optional storage partition
    if [[ -n "${STRG_DEVICE:-}" ]]; then
        printf "It will use %b%s%b as a storage medium and mount it on %b%s%b\n" \
            "${COLORS[yellow]:-}" "${STRG_DEVICE}" "${COLORS[reset]:-}" \
            "${COLORS[yellow]:-}" "/mnt/Storage" "${COLORS[reset]:-}"
    else
        _info "No extra storage partition selected."
    fi

    # Optional Windows partition
    if [[ -n "${WIN_DEVICE:-}" ]]; then
        printf "It will use %b%s%b as a Windows partition and mount it on %b%s%b\n" \
            "${COLORS[yellow]:-}" "${WIN_DEVICE}" "${COLORS[reset]:-}" \
            "${COLORS[yellow]:-}" "/mnt/Windows" "${COLORS[reset]:-}"
    else
        _info "No Windows partition selected."
    fi

    # Basic info lines
    printf "Your username will be %b%s%b\n" "${COLORS[yellow]:-}" "${USR:-<not set>}" "${COLORS[reset]:-}"
    printf "The machine's hostname will be %b%s%b\n" "${COLORS[yellow]:-}" "${HOSTNAME:-<not set>}" "${COLORS[reset]:-}"
    printf "Your Desktop Environment will be %b%s%b\n" "${COLORS[yellow]:-}" "${DE:-<not set>}" "${COLORS[reset]:-}"

    # Toggles
    if [[ "${DOTFILES:-No}" == "Yes" ]]; then
        _warn "Installer will configure dotfiles."
    else
        _info "Dotfiles will not be configured."
    fi
    echo

    # preview plan to user
    print_package_plan FINAL_PKGS

    # Confirmation (default No)
    printf "%b" "${COLORS[purple]:-}Proceed with installation? [y/N]: ${COLORS[reset]:-}"
    read -r ANS
    if [[ "${ANS,,}" != "y" ]]; then   # case-insensitive check
        _error "Installation aborted by user."
        exit 1
    fi

    _success "Proceeding with installation..."
}

# -----------------------------------------------------------
# Function: configure_pacman
# Purpose : Configure /etc/pacman.conf with useful options
#            - Enables colored output in pacman
#            - Enables verbose package lists
#            - Enables multilib repository (for 64-bit)
#            - Sets ParallelDownloads = 10 and adds ILoveCandy
# Notes   : Safe to run multiple times (idempotent)
# Requires: Root privileges and pacman installed
# -----------------------------------------------------------

configure_pacman() {
    local conf="/etc/pacman.conf"

    # Ensure pacman.conf exists
    if [[ ! -f "$conf" ]]; then
        _error "Pacman configuration file not found at $conf"
        return 1
    fi

    _info "Configuring pacman..."

    # -----------------------------------------------------------
    # 1️⃣ Enable colored output in pacman
    # -----------------------------------------------------------
    # Uncomment '#Color' if found, or add 'Color' if missing.
    if grep -q '^#Color' "$conf"; then
        sed -i 's/^#Color/Color/' "$conf"
    elif ! grep -q '^Color' "$conf"; then
        echo "Color" >> "$conf"
    fi

    # -----------------------------------------------------------
    # 2️⃣ Enable verbose package list output
    # -----------------------------------------------------------
    # This makes pacman show both old → new version info clearly.
    if grep -q '^#VerbosePkgLists' "$conf"; then
        sed -i 's/^#VerbosePkgLists/VerbosePkgLists/' "$conf"
    elif ! grep -q '^VerbosePkgLists' "$conf"; then
        echo "VerbosePkgLists" >> "$conf"
    fi

    # -----------------------------------------------------------
    # 3️⃣ Enable [multilib] repository (for 64-bit systems)
    # -----------------------------------------------------------
    # This repo provides 32-bit compatibility libraries.
    if grep -q '^\[multilib\]' "$conf"; then
        # If already defined but commented, uncomment all lines
        sed -i '/^\[multilib\]/,/^Include/s/^#//' "$conf"
    else
        # If not defined at all, append the block
        cat <<EOF >> "$conf"

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
    fi

    # -----------------------------------------------------------
    # 4️⃣ Increase parallel downloads & enable ILoveCandy
    # -----------------------------------------------------------
    # ParallelDownloads speeds up installation.
    # ILoveCandy adds a fun Pac-Man progress bar.
    if grep -q '^#ParallelDownloads' "$conf"; then
        # Uncomment and modify the existing line
        sed -i "s/^#ParallelDownloads = .*/ParallelDownloads = 10\nILoveCandy/" "$conf"
    elif ! grep -q '^ParallelDownloads' "$conf"; then
        # Add the lines if not present at all
        echo -e "ParallelDownloads = 10\nILoveCandy" >> "$conf"
    else
        # Ensure ILoveCandy exists if user already had ParallelDownloads
        grep -q '^ILoveCandy' "$conf" || echo "ILoveCandy" >> "$conf"
    fi

    _success "Pacman configuration updated successfully."
}

# -----------------------------------------------------------
# Function: update_keyring
# Purpose : Ensure system clock is synced and Arch keyring is up-to-date
# Notes   :
#   - Needed when installing from an outdated ISO
#   - Prevents key verification errors during installation
#   - Uses colorized log output and safe commands
# -----------------------------------------------------------

update_keyring() {
    _info "Updating Arch Linux keyring..."

    # 1️⃣ Ensure pacman exists before proceeding
    if ! command -v pacman &>/dev/null; then
        _error "Pacman not found. Cannot update keyring."
        return 1
    fi

    # 2️⃣ Enable network time synchronization
    if timedatectl set-ntp true &>/dev/null; then
        _success "NTP enabled successfully."
    else
        _warn "Failed to enable NTP. Continuing anyway..."
    fi

    # 3️⃣ Sync hardware clock to system clock
    if hwclock --systohc &>/dev/null; then
        _success "Hardware clock synchronized."
    else
        _warn "Could not synchronize hardware clock. Continuing..."
    fi

    # 4️⃣ Check for active network connection
    if ! ping -c 1 -W 2 archlinux.org &>/dev/null; then
        _error "No internet connection. Cannot update keyring."
        return 1
    fi

    # 5️⃣ Update Arch Linux keyring
    # --ask=127 allows re-downloading keys if some are broken
    # --noconfirm prevents prompt interruption
    if pacman --noconfirm --ask=127 -Sy archlinux-keyring &>/dev/null; then
        _success "Arch Linux keyring updated successfully."
    else
        _error "Failed to update Arch Linux keyring."
        return 1
    fi
}

# ------------------------------------------------------------
# partition_and_mount, partition_and_mount_uefi, partition_and_mount_bios
# Purpose: Partition the selected ROOT_DEVICE and mount filesystems at /mnt
# Notes :
#  - Requires root
#  - Uses sgdisk for GPT/UEFI partitioning and sfdisk for a minimal BIOS layout
#  - Automatically finds created partitions via lsblk (works for nvme/pci names)
#  - Creates mountpoints: /mnt, /mnt/boot (UEFI), /mnt/Storage, /mnt/Windows (optional)
#  - Optionally refreshes mirrorlist using reflector if available
# ------------------------------------------------------------

partition_and_mount() {
    # Ensure running as root
    if [[ $EUID -ne 0 ]]; then
        _error "partition_and_mount must be run as root."
        return 1
    fi

    # Validate ROOT_DEVICE
    if [[ -z "${ROOT_DEVICE:-}" ]]; then
        _error "ROOT_DEVICE not set. Aborting partition step."
        return 1
    fi
    if [[ ! -b "$ROOT_DEVICE" ]]; then
        _error "Root device '$ROOT_DEVICE' is not a block device."
        return 1
    fi

     # check for required tools
    for cmd in sgdisk mkfs.fat mkfs.ext4 wipefs partprobe lsblk mount mkdir; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            _error "Required command '$cmd' not found. Install it and retry."
            return 1
        fi
    done

    _info "Detected firmware: checking for UEFI..."
    if [[ -d /sys/firmware/efi/efivars ]]; then
        UEFI=y
        _info "System appears to be UEFI. Running UEFI partitioning."
        partition_and_mount_uefi || return 1
    else
        UEFI=n
        _info "System appears to be BIOS. Running legacy partitioning."
        partition_and_mount_bios || return 1
    fi

     # optional: refresh mirrorlist if reflector is available
    if command -v reflector >/dev/null 2>&1; then
        _info "Refreshing mirrorlist with reflector..."
        reflector --latest 20 --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null && _success "Mirrorlist updated."
    else
        _info "reflector not installed; skipping mirrorlist refresh."
    fi

    # Record firmware type for later steps
    # ensure vars.sh exists and contains UEFI value (overwrite or append)
    if [[ -w ./vars.sh ]]; then
        # Remove existing UEFI line if present then append
        sed -i '/^UEFI=/d' ./vars.sh 2>/dev/null || true
        echo "UEFI=$UEFI" >> ./vars.sh
    fi

    _success "Partitioning and mount step finished."
}

# # ---------------- UEFI partitioner: create GPT with EFI + ROOT ------------
# partition_and_mount_uefi() {
#     local dev="$ROOT_DEVICE"
#     local efi_size="512M"   # EFI partition size
#     local efi_type="ef00"   # GPT type code for EFI System
#     local label_root="ROOT"

#     _info "Wiping filesystem signatures on ${dev} (this will destroy data!)"
#     wipefs --all --force "$dev" || {
#         _warn "wipefs returned non-zero; continuing with caution..."
#     }

#     _info "Creating GPT layout on ${dev}: EFI ${efi_size} + root (remaining)"
#     # Create partitions: 1 = EFI, 2 = ROOT (rest of disk)
#     # sgdisk: -n <partnum>:start:end ; use +size for end
#     sgdisk --clear --mbrtogpt --zap-all "$dev" >/dev/null 2>&1 || true
#     sgdisk -o "$dev" >/dev/null 2>&1            # create new GPT
#     sgdisk -n 1:0:+${efi_size} -t 1:${efi_type} -c 1:"EFI" "$dev" >/dev/null 2>&1
#     sgdisk -n 2:0:0 -t 2:8300 -c 2:"${label_root}" "$dev" >/dev/null 2>&1

#     # ensure kernel sees new partitions
#     partprobe "$dev" || sleep 1

#     # detect created partitions robustly (handles nvme names with 'p')
#     mapfile -t PARTS < <(lsblk -ln -o NAME -r "$dev" | tail -n +2)
#     if ((${#PARTS[@]} < 2)); then
#         _error "Failed to detect new partitions on ${dev}."
#         return 1
#     fi

#     local efi_part="/dev/${PARTS[0]}"
#     local root_part="/dev/${PARTS[1]}"

#     _info "Formatting EFI partition ${efi_part} (FAT32) and ROOT ${root_part} (ext4)"
#     mkfs.fat -F32 "$efi_part" >/dev/null || { _error "mkfs.fat failed on ${efi_part}"; return 1; }
#     mkfs.ext4 -F -L ROOT "$root_part" >/dev/null || { _error "mkfs.ext4 failed on ${root_part}"; return 1; }

#     # mount hierarchy
#     _info "Mounting root partition ${root_part} to /mnt"
#     mkdir -p /mnt
#     mount "$root_part" /mnt || { _error "Failed to mount ${root_part} to /mnt"; return 1; }

#     _info "Mounting EFI partition ${efi_part} to /mnt/boot"
#     mkdir -p /mnt/boot
#     mount "$efi_part" /mnt/boot || { _error "Failed to mount ${efi_part} to /mnt/boot"; return 1; }

#     # optional mounts: storage and windows
#     if [[ -n "${STRG_DEVICE:-}" ]]; then
#         if [[ -b "$STRG_DEVICE" ]]; then
#             _info "Mounting storage device ${STRG_DEVICE} to /mnt/Storage"
#             mkdir -p /mnt/Storage
#             mount "$STRG_DEVICE" /mnt/Storage || _warn "Failed to mount ${STRG_DEVICE} to /mnt/Storage"
#         else
#             _warn "STRG_DEVICE '${STRG_DEVICE}' is not a block device; skipping Storage mount"
#         fi
#     fi

#     if [[ -n "${WIN_DEVICE:-}" ]]; then
#         if [[ -b "$WIN_DEVICE" ]]; then
#             _info "Mounting Windows partition ${WIN_DEVICE} to /mnt/Windows"
#             mkdir -p /mnt/Windows
#             mount "$WIN_DEVICE" /mnt/Windows || _warn "Failed to mount ${WIN_DEVICE} to /mnt/Windows"
#         else
#             _warn "WIN_DEVICE '${WIN_DEVICE}' is not a block device; skipping Windows mount"
#         fi
#     fi

#     _success "UEFI partitioning and mounting done."
# }

# # ---------------- BIOS partitioner: single partition for root -------------
# partition_and_mount_bios() {
#     local dev="$ROOT_DEVICE"
#     local label_root="ROOT"

#     _info "Wiping filesystem signatures on ${dev} (this will destroy data!)"
#     wipefs --all --force "$dev" || {
#         _warn "wipefs returned non-zero; continuing with caution..."
#     }

#     _info "Creating single partition on ${dev} that spans the whole disk (BIOS/legacy)"
#     # Use sfdisk with a simple layout: one primary partition
#     printf 'label: dos\nlabel-id: 0x%08x\n, , L\n' "$RANDOM" | sfdisk --wipe always --wipe-partitions always "$dev" >/dev/null 2>&1

#     # ensure kernel sees new partitions
#     partprobe "$dev" || sleep 1

#     # detect created partitions (should be at index 1)
#     mapfile -t PARTS < <(lsblk -ln -o NAME -r "$dev" | tail -n +2)
#     if ((${#PARTS[@]} < 1)); then
#         _error "Failed to detect new partition on ${dev}."
#         return 1
#     fi

#     local root_part="/dev/${PARTS[0]}"

#     _info "Formatting root partition ${root_part} (ext4)"
#     mkfs.ext4 -F -L "${label_root}" "$root_part" >/dev/null || { _error "mkfs.ext4 failed on ${root_part}"; return 1; }

#     # mount root
#     _info "Mounting ${root_part} to /mnt"
#     mkdir -p /mnt
#     mount "$root_part" /mnt || { _error "Failed to mount ${root_part} to /mnt"; return 1; }

#     # optional mounts: storage and windows
#     if [[ -n "${STRG_DEVICE:-}" ]]; then
#         if [[ -b "$STRG_DEVICE" ]]; then
#             _info "Mounting storage device ${STRG_DEVICE} to /mnt/Storage"
#             mkdir -p /mnt/Storage
#             mount "$STRG_DEVICE" /mnt/Storage || _warn "Failed to mount ${STRG_DEVICE} to /mnt/Storage"
#         else
#             _warn "STRG_DEVICE '${STRG_DEVICE}' is not a block device; skipping Storage mount"
#         fi
#     fi

#     if [[ -n "${WIN_DEVICE:-}" ]]; then
#         if [[ -b "$WIN_DEVICE" ]]; then
#             _info "Mounting Windows partition ${WIN_DEVICE} to /mnt/Windows"
#             mkdir -p /mnt/Windows
#             mount "$WIN_DEVICE" /mnt/Windows || _warn "Failed to mount ${WIN_DEVICE} to /mnt/Windows"
#         else
#             _warn "WIN_DEVICE '${WIN_DEVICE}' is not a block device; skipping Windows mount"
#         fi
#     fi

#     _success "BIOS partitioning and mounting done."
# }

# ---------------- Shared helpers ----------------

# Wipe any existing signatures (non-fatal if wipefs complains)
_wipe_device() {
    local dev="$1"
    _info "Wiping filesystem signatures on ${dev} (this will destroy data!)"
    wipefs --all --force "$dev" || _warn "wipefs returned non-zero; continuing with caution..."
}

# Ensure kernel sees new partitions
_rescan_parts() {
    local dev="$1"
    partprobe "$dev" || sleep 1
}

# Populate global array DETECTED_PARTS with children of a device (handles nvme 'p')
_detect_parts() {
    local dev="$1"
    mapfile -t DETECTED_PARTS < <(lsblk -ln -o NAME -r "$dev" | tail -n +2)
}

# Mount helper with mkdir -p + error handling
_mount_to() {
    local src="$1" dst="$2"
    _info "Mounting ${src} to ${dst}"
    mkdir -p "$dst"
    mount "$src" "$dst" || { _warn "Failed to mount ${src} to ${dst}"; return 1; }
}

# Format filesystems with consistent messages
_mkfs_fat32() { local p="$1"; _info "Formatting ${p} (FAT32)"; mkfs.fat -F32 "$p" >/dev/null || { _error "mkfs.fat failed on ${p}"; return 1; }; }
_mkfs_ext4()  { local p="$1" label="$2"; _info "Formatting ${p} (ext4, label=${label})"; mkfs.ext4 -F -L "$label" "$p" >/dev/null || { _error "mkfs.ext4 failed on ${p}"; return 1; }; }

# Optional mounts block (Storage/Windows)
_mount_optional_devices() {
    if [[ -n "${STRG_DEVICE:-}" ]]; then
        if [[ -b "$STRG_DEVICE" ]]; then
            _info "Mounting storage device ${STRG_DEVICE} to /mnt/Storage"
            _mount_to "$STRG_DEVICE" /mnt/Storage || _warn "Failed to mount ${STRG_DEVICE} to /mnt/Storage"
        else
            _warn "STRG_DEVICE '${STRG_DEVICE}' is not a block device; skipping Storage mount"
        fi
    fi

    if [[ -n "${WIN_DEVICE:-}" ]]; then
        if [[ -b "$WIN_DEVICE" ]]; then
            _info "Mounting Windows partition ${WIN_DEVICE} to /mnt/Windows"
            _mount_to "$WIN_DEVICE" /mnt/Windows || _warn "Failed to mount ${WIN_DEVICE} to /mnt/Windows"
        else
            _warn "WIN_DEVICE '${WIN_DEVICE}' is not a block device; skipping Windows mount"
        fi
    fi
}

# ---------------- UEFI partitioner: create GPT with EFI + ROOT ------------
partition_and_mount_uefi() {
    local dev="$ROOT_DEVICE"
    local efi_size="512M"   # EFI partition size
    local efi_type="ef00"   # GPT type code for EFI System
    local label_root="ROOT"

    _wipe_device "$dev"

    _info "Creating GPT layout on ${dev}: EFI ${efi_size} + root (remaining)"
    sgdisk --clear --mbrtogpt --zap-all "$dev" >/dev/null 2>&1 || true
    sgdisk -o "$dev" >/dev/null 2>&1
    sgdisk -n 1:0:+${efi_size} -t 1:${efi_type} -c 1:"EFI" "$dev" >/dev/null 2>&1
    sgdisk -n 2:0:0            -t 2:8300       -c 2:"${label_root}" "$dev" >/dev/null 2>&1

    _rescan_parts "$dev"
    _detect_parts "$dev"
    if ((${#DETECTED_PARTS[@]} < 2)); then
        _error "Failed to detect new partitions on ${dev}."
        return 1
    fi

    local efi_part="/dev/${DETECTED_PARTS[0]}"
    local root_part="/dev/${DETECTED_PARTS[1]}"

    _mkfs_fat32 "$efi_part" || return 1
    _mkfs_ext4  "$root_part" "${label_root}" || return 1

    _mount_to "$root_part" /mnt || { _error "Failed to mount ${root_part} to /mnt"; return 1; }
    _mount_to "$efi_part"  /mnt/boot || { _error "Failed to mount ${efi_part} to /mnt/boot"; return 1; }

    _mount_optional_devices
    _success "UEFI partitioning and mounting done."
}

# ---------------- BIOS partitioner: single partition for root -------------
partition_and_mount_bios() {
    local dev="$ROOT_DEVICE"
    local label_root="ROOT"

    _wipe_device "$dev"

    _info "Creating single partition on ${dev} that spans the whole disk (BIOS/legacy)"
    printf 'label: dos\nlabel-id: 0x%08x\n, , L\n' "$RANDOM" | sfdisk --wipe always --wipe-partitions always "$dev" >/dev/null 2>&1

    _rescan_parts "$dev"
    _detect_parts "$dev"
    if ((${#DETECTED_PARTS[@]} < 1)); then
        _error "Failed to detect new partition on ${dev}."
        return 1
    fi

    local root_part="/dev/${DETECTED_PARTS[0]}"

    _mkfs_ext4 "$root_part" "${label_root}" || return 1
    _mount_to "$root_part" /mnt || { _error "Failed to mount ${root_part} to /mnt"; return 1; }

    _mount_optional_devices
    _success "BIOS partitioning and mounting done."
}


# Simple install_base: minimal, readable, and functional
install_base() {
    mountpoint -q /mnt || { _error "/mnt is not mounted"; return 1; }
    [[ ${#BASE[@]:-0} -gt 0 ]] || { _error "BASE array is empty"; return 1; }

    _info "Refreshing mirrorlist (if reflector available)..."
    if command -v reflector >/dev/null 2>&1; then
        reflector --latest 20 --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null || \
            _warn "reflector failed — continuing with existing mirrorlist"
    fi

    _info "Installing base packages..."
    pacstrap /mnt --noconfirm --needed "${BASE[@]}" || { _error "pacstrap failed"; return 1; }

    _info "Generating /mnt/etc/fstab..."
    genfstab -U /mnt > /mnt/etc/fstab || { _error "genfstab failed"; return 1; }

    # Add nofail to optional mounts if present
    if grep -q "/mnt/Windows" /mnt/etc/fstab 2>/dev/null; then
        awk '{
            if ($2=="/mnt/Windows" && index($4,"nofail")==0) $4 = $4 ",nofail";
            print
        }' /mnt/etc/fstab > /mnt/etc/fstab.tmp && mv /mnt/etc/fstab.tmp /mnt/etc/fstab
    fi

    if grep -q "/mnt/Storage" /mnt/etc/fstab 2>/dev/null; then
        awk '{
            if ($2=="/mnt/Storage" && index($4,"nofail")==0) $4 = $4 ",nofail";
            print
        }' /mnt/etc/fstab > /mnt/etc/fstab.tmp && mv /mnt/etc/fstab.tmp /mnt/etc/fstab
    fi

    _success "Base installation complete."
    return 0
}

# ------------------------------------------------------------
# setup_network
# Purpose : Configure timezone, locale, hostname, and hosts file
# Notes   : Run inside chroot (/mnt)
# ------------------------------------------------------------
setup_network() {
    _info "Setting up system timezone, locale, and network..."

    # 1️⃣ Timezone
    ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
    hwclock --systohc
    _success "Timezone set to Asia/Kolkata"

    # 2️⃣ Locale (assuming configure_locale function exists)
    if declare -f configure_locale >/dev/null 2>&1; then
        configure_locale
    else
        _warn "configure_locale() not found — skipping locale setup."
    fi

    # 3️⃣ Hostname
    if [[ -n "${HOSTNAME:-}" ]]; then
        echo "${HOSTNAME}" > /etc/hostname
        _success "Hostname set to ${HOSTNAME}"
    else
        _warn "HOSTNAME variable is empty — skipping /etc/hostname."
    fi

    # 4️⃣ Hosts file
    cat > /etc/hosts <<-EOF
		127.0.0.1   localhost
		::1         localhost
		127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
	EOF
    _success "/etc/hosts configured."

    # 5️⃣ Root password
    if [[ -n "${PASSWD:-}" ]]; then
        echo -e "${PASSWD}\n${PASSWD}" | passwd root >/dev/null 2>&1 && \
            _success "Root password set successfully." || \
            _error "Failed to set root password."
    else
        _warn "PASSWD variable empty — root password not set."
    fi

    _success "Network and basic system configuration complete."
}

# ------------------------------------------------------------
# configure_locale
# Purpose : Enable and generate system locales
# Notes   : Called from setup_network(); uses _info/_warn/_success/_error
# ------------------------------------------------------------
configure_locale() {
    _info "Configuring system locale..."

    # 1️⃣ Enable desired locales in /etc/locale.gen
    if [[ -f /etc/locale.gen ]]; then
        sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
        sed -i 's/^#es_AR.UTF-8 UTF-8/es_AR.UTF-8 UTF-8/' /etc/locale.gen
        _success "Locales enabled in /etc/locale.gen"
    else
        _error "/etc/locale.gen not found! Skipping locale configuration."
        return 1
    fi

    # 2️⃣ Generate locales
    if locale-gen >/dev/null 2>&1; then
        _success "Locale generation completed."
    else
        _error "Failed to generate locales."
        return 1
    fi

    # 3️⃣ Set system-wide default language
    echo "LANG=en_US.UTF-8" > /etc/locale.conf
    _success "Default language set to en_US.UTF-8"

    _success "Locale configuration completed."
}

# ------------------------------------------------------------------------
# prepare_system
# - Installs essential packages from BASE_APPS
# - Initializes pacman keys
# - Installs CPU microcode (via install_cpu_ucode function)
# - Installs and configures GRUB for UEFI or BIOS
# ------------------------------------------------------------------------
prepare_system() {
    # Add wifi packages if requested
    if [[ "${WIFI:-n}" == "y" ]]; then
        BASE_APPS+=( wpa_supplicant wireless_tools )
    fi

    _info "Refreshing package databases..."
    pacman -Sy --noconfirm || { _error "pacman -Sy failed"; return 1; }

    _info "Installing base packages..."
    pacman --needed --noconfirm --ask=127 -S "${BASE_APPS[@]}" || { _error "Failed to install base packages"; return 1; }
    _success "Base packages installed."

    # Initialize and populate pacman keyring if needed (safe to re-run)
    if ! pacman-key --list-keys >/dev/null 2>&1; then
        _info "Initializing pacman keyring..."
        pacman-key --init || _warn "pacman-key --init returned non-zero"
    fi
    _info "Populating pacman keyring..."
    pacman-key --populate archlinux || _warn "pacman-key --populate returned non-zero"
    _success "Pacman keyring ready."

    # Install CPU microcode if helper exists
    if declare -f install_cpu_ucode >/dev/null 2>&1; then
        _info "Installing CPU microcode..."
        install_cpu_ucode || _warn "install_cpu_ucode reported an issue"
    else
        _warn "install_cpu_ucode() not defined — skipping microcode install"
    fi

    # Install GRUB
    if [[ "${UEFI:-n}" == "y" ]]; then
        _info "Installing GRUB for UEFI systems..."
        # ensure /boot exists and is mounted (for chroot environment usually /boot is mounted)
        mkdir -p /boot
        if ! command -v grub-install >/dev/null 2>&1; then
            _error "grub-install not found. Install grub package and retry."
            return 1
        fi
        grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Arch || {
            _error "grub-install (UEFI) failed"; return 1; }
    else
        _info "Installing GRUB for BIOS (legacy) systems..."
        if ! command -v grub-install >/dev/null 2>&1; then
            _error "grub-install not found. Install grub package and retry."
            return 1
        fi
        grub-install --target=i386-pc "$ROOT_DEVICE" || { _error "grub-install (BIOS) failed"; return 1; }
    fi
    _success "GRUB installed."

    # Configure GRUB: ensure os-prober runs (avoid duplicate lines)
    _info "Configuring GRUB defaults..."
    sed -i '/^GRUB_DISABLE_OS_PROBER=/d' /etc/default/grub 2>/dev/null || true
    printf '\nGRUB_DISABLE_OS_PROBER=false\n' >> /etc/default/grub

    # Generate grub config if grub-mkconfig exists
    if command -v grub-mkconfig >/dev/null 2>&1; then
        grub-mkconfig -o /boot/grub/grub.cfg || { _warn "grub-mkconfig returned non-zero"; }
        _success "GRUB configuration generated."
    else
        _warn "grub-mkconfig not found; skipping config generation."
    fi

    return 0
}

# ------------------------------------------------------------
# install_cpu_ucode
# Purpose : Detect CPU vendor and install appropriate microcode
# Notes   : Uses _info/_warn/_success/_error for log output
# ------------------------------------------------------------
install_cpu_ucode() {
    _info "Detecting CPU vendor for microcode installation..."

    # Make sure lscpu exists
    if ! command -v lscpu >/dev/null 2>&1; then
        _error "lscpu not found. Cannot detect CPU vendor."
        return 1
    fi

    # Extract vendor string
    local CPU_VENDOR
    CPU_VENDOR=$(lscpu | awk -F: '/Vendor ID/ {gsub(/^[ \t]+/, "", $2); print $2}')

    if [[ -z "$CPU_VENDOR" ]]; then
        _warn "Unable to detect CPU vendor. Skipping microcode installation."
        return 0
    fi

    case "$CPU_VENDOR" in
        AuthenticAMD)
            _info "AMD CPU detected — installing amd-ucode..."
            pacman --needed --noconfirm -S amd-ucode && \
                _success "AMD microcode installed successfully." || \
                _error "Failed to install amd-ucode."
            ;;
        GenuineIntel)
            _info "Intel CPU detected — installing intel-ucode..."
            pacman --needed --noconfirm -S intel-ucode && \
                _success "Intel microcode installed successfully." || \
                _error "Failed to install intel-ucode."
            ;;
        *)
            _warn "Unknown CPU vendor ($CPU_VENDOR). Skipping microcode installation."
            ;;
    esac
}

# ------------------------------------------------------------
# setup_users
# Purpose : Create user account, set password, configure sudo
# Notes   : Uses chpasswd, creates sudoers snippets safely
# ------------------------------------------------------------
setup_users() {
    # validate username and password
    if [[ -z "${USR:-}" ]]; then
        _error "USR is not set. Cannot create user."
        return 1
    fi
    if [[ -z "${PASSWD:-}" ]]; then
        _warn "PASSWD is empty — user will be created without a password."
    fi

    local shell_path="${SHELL:-/bin/zsh}"
    # create user if it doesn't exist
    if id -u "${USR}" >/dev/null 2>&1; then
        _info "User ${USR} already exists — skipping creation."
    else
        _info "Creating user '${USR}' with home directory and groups..."
        useradd -m -s "${shell_path}" -G wheel,video,audio,optical,storage,games "${USR}" || {
            _error "useradd failed for ${USR}"; return 1
        }
        _success "User ${USR} created."
    fi

    # set password (use chpasswd for non-interactive and safer handling)
    if [[ -n "${PASSWD:-}" ]]; then
        printf '%s:%s\n' "${USR}" "${PASSWD}" | chpasswd || {
            _error "Failed to set password for ${USR}"; return 1
        }
        _success "Password set for ${USR}."
    fi

    # export the user's home directory
    export USR_HOME
    USR_HOME=$(getent passwd "${USR}" | cut -d: -f6)
    _info "User home: ${USR_HOME}"

    # ensure /etc/sudoers.d exists
    mkdir -p /etc/sudoers.d
    chmod 755 /etc/sudoers.d

    # create wheel sudoers file (grant wheel group full sudo)
    local wheel_conf="/etc/sudoers.d/wheel_sudo"
    printf '%%wheel ALL=(ALL:ALL) ALL\n' > "${wheel_conf}"
    chmod 0440 "${wheel_conf}"
    # validate with visudo
    if visudo -c -f "${wheel_conf}" >/dev/null 2>&1; then
        _success "Sudoers for wheel group installed."
    else
        _error "Sudoers syntax error in ${wheel_conf}; removing file."
        rm -f "${wheel_conf}"
    fi

    # optional: add 'Defaults insults' as a separate file
    local insults_conf="/etc/sudoers.d/insults"
    printf 'Defaults insults\n' > "${insults_conf}"
    chmod 0440 "${insults_conf}"
    if visudo -c -f "${insults_conf}" >/dev/null 2>&1; then
        _success "Sudo insults enabled."
    else
        _warn "Could not enable sudo insults (syntax error); removing ${insults_conf}."
        rm -f "${insults_conf}"
    fi

    # clear sensitive variable from environment
    unset PASSWD

    _success "User setup complete."
    return 0
}

# ------------------------------------------------------------
# prepare_gui
# Purpose : Populate DE_PACKAGES for the chosen desktop environment
#           and add/display-manager services to SERVICES (deduped)
# Notes   : - Expects DE to be set (e.g. "GNOME", "BSPWM")
#           - Uses DE_PKGS associative map (preferred) or FALLBACK array (AWESOME, BSPWM, ...)
#           - Uses _info/_warn/_success for logging
# ------------------------------------------------------------
prepare_gui() {
    _info "Preparing GUI packages and services for DE='${DE:-<unset>}'"

    if [[ -z "${DE:-}" ]]; then
        _error "DE not set. Call setup_variables() first."
        return 1
    fi

    # Keep the original selection name and create a lowercase key
    DE_NAME="$DE"
    DE_KEY="${DE,,}"   # e.g. GNOME -> gnome

    # 1) Populate DE_PACKAGES array
    DE_PACKAGES=()
    if declare -p DE_PKGS &>/dev/null && [[ -n "${DE_PKGS[$DE_KEY]:-}" ]]; then
        # DE_PKGS holds a space-separated string for this DE
        read -r -a DE_PACKAGES <<< "${DE_PKGS[$DE_KEY]}"
        _info "Using DE packages from DE_PKGS[$DE_KEY] (count=${#DE_PACKAGES[@]})"
    else
        # Fallback: try to use an array named exactly like the uppercase DE (AWESOME, BSPWM, etc.)
        if declare -p "${DE_NAME}" &>/dev/null; then
            local -n _fallback="${DE_NAME}"
            DE_PACKAGES=("${_fallback[@]}")
            _info "Using fallback array '${DE_NAME}' for DE packages (count=${#DE_PACKAGES[@]})"
        else
            _warn "No package list found for DE='${DE_NAME}'. DE_PACKAGES is empty."
        fi
    fi

    # 2) Map DE -> display manager services (ensure no duplicates in SERVICES)
    # helper to append service only if not already present
    _add_service_if_missing() {
        local svc="$1"
        for s in "${SERVICES[@]:-}"; do
            [[ "$s" == "$svc" ]] && return 0
        done
        SERVICES+=("$svc")
    }

    case "$DE_NAME" in
        AWESOME|BUDGIE|BSPWM|CINNAMON|DEEPIN|ENLIGHTENMENT|MATE|QTILE|XFCE)
            _add_service_if_missing "lightdm"
            ;;
        GNOME)
            _add_service_if_missing "gdm"
            ;;
        KDE|LXQT)
            _add_service_if_missing "sddm"
            ;;
        *)
            _warn "Unknown DE '${DE_NAME}': no display manager added automatically."
            ;;
    esac

    _success "GUI preparation complete. DE_PACKAGES=${#DE_PACKAGES[@]} pkgs; SERVICES=${#SERVICES[@]} items."
    return 0
}

# ------------------------------------------------------------------------
# install_applications
# Installs desktop packages, GPU drivers and user apps via paru (AUR helper)
# - Runs necessary installs as the non-root user using runuser
# - Temporarily gives wheel NOPASSWD, backing up previous file and restoring it
# - Uses safe array expansions and checks
# ------------------------------------------------------------------------
install_applications() {
    if [[ -z "${USR:-}" ]]; then
        _error "USR is not set. Cannot install user applications."
        return 1
    fi

    local paru_cmd="paru --needed --noconfirm -S"
    local sudo_wheel="/etc/sudoers.d/wheel_sudo"
    local sudo_bak="${sudo_wheel}.bak"

    # 1) Backup existing wheel sudoers (if any) and set temporary NOPASSWD
    if [[ -f "$sudo_wheel" ]]; then
        cp -f "$sudo_wheel" "$sudo_bak" || {
            _warn "Could not back up existing $sudo_wheel"
        }
    fi
    printf '%%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n' > "$sudo_wheel"
    chmod 0440 "$sudo_wheel"
    _info "Temporarily enabled passwordless sudo for wheel group."

    # 2) Ensure paru is installed (install_paru should install paru as the regular user)
    if command -v paru >/dev/null 2>&1; then
        _info "paru already installed; skipping."
    else
        if ! id -u "$USR" >/dev/null 2>&1; then
            _error "User ${USR} does not exist — cannot install paru as that user."
        else
            _info "Installing paru as user ${USR}..."
            runuser -u "$USR" -- /bin/bash -lc '
                set -e
                # avoid re-cloning if paru already exists in home
                AUR_BUILD_DIR="$HOME/aur-paru"
                if [[ -d "$AUR_BUILD_DIR" ]]; then
                    echo "Using existing $AUR_BUILD_DIR"
                else
                    git clone https://aur.archlinux.org/paru.git "$AUR_BUILD_DIR"
                fi
                cd "$AUR_BUILD_DIR"
                # ensure dependencies are present; the builder will ask if missing,
                # but --noconfirm is dangerous here; assume the live environment prepared them.
                makepkg -si --noconfirm || exit 1
            ' && _success "paru installed successfully." || _warn "paru installation failed."
        fi
    fi

    # helper to run paru as the regular user for a given package array
    _run_paru_as_user() {
        local -n _arr=$1
        if [[ ${#_arr[@]:-0} -eq 0 ]]; then
            return 0
        fi
        # join array into safely quoted string for the shell invoked as user
        # We use printf %q to escape each argument for sh -c
        local args=""
        local pkg
        for pkg in "${_arr[@]}"; do
            args+=" $(printf '%q' "$pkg")"
        done
        _info "Installing (${#_arr[@]}) packages as ${USR}..."
        runuser -u "$USR" -- /bin/sh -c "${paru_cmd}${args}" || {
            _warn "paru installation returned non-zero for some packages."
            return 1
        }
        return 0
    }

    # 3) Install DE packages: prefer DE_PACKAGES (set by prepare_gui), fallback to DE (if array)
    if declare -p DE_PACKAGES >/dev/null 2>&1 && [[ ${#DE_PACKAGES[@]:-0} -gt 0 ]]; then
        _run_paru_as_user DE_PACKAGES || _warn "Issues while installing DE packages."
    elif declare -p DE >/dev/null 2>&1 && [[ ${#DE[@]:-0} -gt 0 ]]; then
        _run_paru_as_user DE || _warn "Issues while installing DE packages from DE array."
    else
        _info "No DE packages to install."
    fi

    # 4) Detect GPU drivers (populate GPU_DRIVERS) and install them if present
    if declare -f detect_drivers >/dev/null 2>&1; then
        _info "Detecting GPU drivers..."
        detect_drivers || _warn "detect_drivers returned non-zero."
    else
        _warn "detect_drivers() not defined — skipping GPU driver auto-detection."
    fi

    if [[ ${#GPU_DRIVERS[@]:-0} -gt 0 ]]; then
        _run_paru_as_user GPU_DRIVERS || _warn "Issues while installing GPU drivers."
    else
        _info "No GPU drivers detected/required."
    fi

    # 5) Install general user applications (APPS)
    if [[ ${#APPS[@]:-0} -gt 0 ]]; then
        _run_paru_as_user APPS || _warn "Issues while installing APPS."
    else
        _info "No APPS to install."
    fi

    # 6) Gaming apps if selected
    if [[ "${GAMING:-No}" == "Yes" && ${#GAMING_APPS[@]:-0} -gt 0 ]]; then
        _run_paru_as_user GAMING_APPS || _warn "Issues while installing GAMING_APPS."
    fi

    # 7) Restore wheel sudoers to prior state (or to sane default)
    if [[ -f "$sudo_bak" ]]; then
        mv -f "$sudo_bak" "$sudo_wheel"
        _info "Restored previous $sudo_wheel"
    else
        printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$sudo_wheel"
        chmod 0440 "$sudo_wheel"
        _info "Restored wheel sudoers to require password."
    fi

    _success "Application installation complete."
    return 0
}

# ------------------------------------------------------------
# detect_drivers
# Purpose : Detect GPU vendor and populate GPU_DRIVERS array
# Notes   :
#   - Uses lspci for detection
#   - Supports NVIDIA, AMD, and Intel GPUs
#   - Appends the proper driver packages to GPU_DRIVERS
# ------------------------------------------------------------
detect_drivers() {
    _info "Detecting GPU hardware..."

    # ensure lspci exists
    if ! command -v lspci >/dev/null 2>&1; then
        _error "lspci command not found — cannot detect GPU."
        return 1
    fi

    # detect all VGA/3D controllers
    local gpu_info
    gpu_info=$(lspci | grep -Ei 'vga|3d' | cut -d ':' -f3- | tr -s ' ')

    if [[ -z "$gpu_info" ]]; then
        _warn "No GPU detected by lspci."
        return 0
    fi

    # reset GPU_DRIVERS before populating
    GPU_DRIVERS=()

    # NVIDIA
    if grep -qi "nvidia" <<< "$gpu_info"; then
        GPU_DRIVERS+=(nvidia nvidia-utils lib32-nvidia-utils)
        _success "Detected NVIDIA GPU — added NVIDIA drivers."

    # AMD / ATI
    elif grep -Eqi "amd|ati" <<< "$gpu_info"; then
        GPU_DRIVERS+=(
            mesa lib32-mesa mesa-vdpau lib32-mesa-vdpau
            xf86-video-amdgpu vulkan-radeon lib32-vulkan-radeon
            libva-mesa-driver lib32-libva-mesa-driver
        )
        _success "Detected AMD GPU — added Mesa/AMDGPU drivers."

    # Intel
    elif grep -qi "intel" <<< "$gpu_info"; then
        GPU_DRIVERS+=(mesa lib32-mesa vulkan-intel)
        _success "Detected Intel GPU — added Intel/Mesa drivers."

    else
        _warn "Unknown or unsupported GPU vendor detected:"
        echo "      ${gpu_info}"
    fi

    # show summary
    if [[ ${#GPU_DRIVERS[@]} -gt 0 ]]; then
        _info "GPU drivers selected: ${GPU_DRIVERS[*]}"
    else
        _warn "No GPU drivers were added to GPU_DRIVERS."
    fi
}

# ------------------------------------------------------------
# enable_services
# Purpose : Enable all systemd services defined in SERVICES array
# Notes   : Safe to run multiple times (idempotent)
# ------------------------------------------------------------
enable_services() {
    _info "Enabling system services..."

    # Check if SERVICES array is set and not empty
    if [[ -z "${SERVICES[*]:-}" ]]; then
        _warn "No services defined in SERVICES array. Skipping."
        return 0
    fi

    local enabled_count=0

    for service in "${SERVICES[@]}"; do
        # Skip empty entries
        [[ -z "$service" ]] && continue

        # Check if the unit exists
        if ! systemctl list-unit-files | grep -q "^${service}.service"; then
            _warn "Service '${service}.service' not found — skipping."
            continue
        fi

        # Enable the service (idempotent)
        if systemctl enable "${service}.service" >/dev/null 2>&1; then
            _success "Enabled service: ${service}"
            ((enabled_count++))
        else
            _error "Failed to enable ${service}.service"
        fi
    done

    if (( enabled_count > 0 )); then
        _success "Successfully enabled ${enabled_count} service(s)."
    else
        _warn "No services were enabled."
    fi
}

# ------------------------------------------------------------
# header
# Purpose : Clear the screen and print the Arch install banner
# Notes   : Uses terminal width dynamically (COLUMNS) for centering
# ------------------------------------------------------------
header() {
    clear

    # Safely handle COLUMNS (default to 80 if undefined)
    local width="${COLUMNS:-80}"

    printf "%${width}s\n" "█████╗ ██████╗  █████╗ ██╗  ██╗      ██╗    ██████╗██╗  ██╗"
    printf "%${width}s\n" "██╔══██╗██╔══██╗██╔══██╗██║  ██║      ██║   ██╔════╝██║  ██║"
    printf "%${width}s\n" "███████║██████╔╝██║  ╚═╝███████║█████╗██║   ╚█████╗ ███████║"
    printf "%${width}s\n" "██╔══██║██╔══██╗██║  ██╗██╔══██║╚════╝██║    ╚═══██╗██╔══██║"
    printf "%${width}s\n" "██║  ██║██║  ██║╚█████╔╝██║  ██║      ██║██╗██████╔╝██║  ██║"
    printf "%${width}s\n" "╚═╝  ╚═╝╚═╝  ╚═╝ ╚════╝ ╚═╝  ╚═╝      ╚═╝╚═╝╚═════╝ ╚═╝  ╚═╝"
    printf "%${width}s\n" "█▄▄ █▄█   ▄▄   ▄▀█ █▀▄ █ ▀█▀ █▄█ ▄▀█ █▀ ▀█▀ █▀█ █▀▄▀█ ▄▀█ █▀█ █▄▄ ▀▀█"
    printf "%${width}s\n" "█▄█  █         █▀█ █▄▀ █  █   █  █▀█ ▄█  █  █▄█ █ ▀ █ █▀█ █▀▄ █▄█   █"
    echo
}

# ------------------------------------------------------------
# install_dotfiles
# Purpose : Optionally install user dotfiles and add daily cron jobs
# Notes   : - Uses runuser to run commands as the installed user
#           - Validates inputs and avoids recursion
# ------------------------------------------------------------
install_dotfiles() {
    # Only run when user opted in
    if [[ "${DOTFILES:-No}" != "Yes" ]]; then
        _info "Dotfiles installation not requested; skipping."
        return 0
    fi

    # Basic validation
    if [[ -z "${USR:-}" ]]; then
        _error "USR not set; cannot install dotfiles."
        return 1
    fi

    # Resolve user's home directory
    USR_HOME=$(getent passwd "${USR}" | cut -d: -f6)
    if [[ -z "${USR_HOME:-}" ]]; then
        _error "Could not determine home for user ${USR}. Aborting dotfiles install."
        return 1
    fi

    _info "Installing dotfiles for user ${USR} (home: ${USR_HOME})"

    # ---------------------
    # 1) Add daily cron jobs
    # ---------------------
    _info "Creating daily maintenance scripts in /etc/cron.daily"

    # updatedb script (shebang + safe invocation)
    cat > /etc/cron.daily/updatedb <<'EOF'
#!/bin/sh
# update mlocate database (if mlocate is installed)
if command -v updatedb >/dev/null 2>&1; then
    updatedb
fi
EOF
    chmod 0755 /etc/cron.daily/updatedb

    # clean cache script - remove files older than 7 days under user caches and root cache
    cat > /etc/cron.daily/clean_cache <<'EOF'
#!/bin/sh
# clean caches older than 7 days
# be conservative: only look under user home dirs for ".cache"
find /home -xdev -type f -path '*/.cache/*' -mtime +7 -exec rm -f {} \;
find /root -xdev -type f -path '/root/.cache/*' -mtime +7 -exec rm -f {} \;
EOF
    chmod 0755 /etc/cron.daily/clean_cache

    _success "Cron daily jobs installed."

    # ---------------------
    # 2) Ensure firefox profile dir exists (optional)
    # ---------------------
    if runuser -u "$USR" -- /bin/sh -c 'command -v firefox >/dev/null 2>&1'; then
        _info "Creating a default Firefox profile (headless) for the user..."
        # run briefly as user to let firefox initialize profile directories; ignore errors
        runuser -u "$USR" -- /bin/sh -c 'timeout 1s firefox --headless >/dev/null 2>&1 || true'
        _success "Firefox profile initialization attempted."
    else
        _info "Firefox not found for user environment; skipping headless profile init."
    fi

    # ---------------------
    # 3) Ask which dotfiles to install and perform the install as the user
    # ---------------------
    _info "Which dotfiles would you like to install?"
    printf "  a) gh0stzk\n  b) adityastomar67\n"
    read -rp "Choose [a/b] (default b): " choice
    choice=${choice:-b}
    choice=${choice,,}  # lowercase

    case "$choice" in
        a)
            _info "Installing gh0stzk dotfiles..."
            DOT_REPO="https://raw.githubusercontent.com/adityastomar67/dots/master/Installer"
            # download installer script to user's home and run it as the user
            runuser -u "$USR" -- /bin/sh -c "
                set -e
                cd \"\$HOME\"
                curl -fsSL '${DOT_REPO}' -o gh0stzkInstaller || exit 1
                chmod +x gh0stzkInstaller
                ./gh0stzkInstaller || exit 1
            " && _success "gh0stzk dotfiles installed." || _warn "gh0stzk installer returned non-zero."
            ;;
        b|*)
            _info "Installing adityastomar67 dotfiles via the Fresh-Install script..."
            # note: piping remote scripts to sh is risky; we run it as the non-root user
            runuser -u "$USR" -- /bin/sh -c "
                set -e
                cd \"\$HOME\"
                curl -fsSL 'https://bit.ly/Fresh-Install' | sh -s -- --dots || exit 1
            " && _success "adityastomar67 dotfiles installed." || _warn "Fresh-Install dotfiles step returned non-zero."
            ;;
    esac

    # Ensure the dotfiles directory (if any) is owned by the user
    if [[ -d \"${USR_HOME}/.dotfiles\" ]]; then
        chown -R "${USR}:${USR}" "${USR_HOME}/.dotfiles" || _warn "Failed to chown ${USR_HOME}/.dotfiles"
    fi

    _success "Dotfiles installation step complete."
    return 0
}
