#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Ensure we run under bash and as root
# if [[ "$(id -u)" -ne 0 ]]; then
#     echo "This installer must be run as root." >&2
#     exit 1
# fi

# Use working directory where definitions/packages live, or adjust as needed
WORKDIR="${WORKDIR:-$(pwd)}"
cd "$WORKDIR"

# Fetch helper files (fail fast on network error)
_fetch() {
    local url="$1" out="$2"
    if ! curl -fsSL "$url" -o "$out"; then
        echo "Failed to download $url" >&2
        exit 1
    fi
}

# Download definitions and packages if missing
[[ -f definitions.sh ]] || _fetch "https://raw.githubusercontent.com/adityastomar67/Arch-I/master/definitions.sh" definitions.sh
[[ -f packages.sh ]]    || _fetch "https://raw.githubusercontent.com/adityastomar67/Arch-I/master/packages.sh" packages.sh

# Load functions/variables into current shell for interactive steps
# definitions.sh should contain color helpers and utility functions; packages.sh the package arrays
source ./definitions.sh
source ./packages.sh

# Interactive/host-side steps
header
setup_variables    # collects ROOT_DEVICE, DE, USR, PASSWD, etc.
configure_pacman   # optional pre-chroot tweaks if you want on live system
update_keyring
partition_and_mount
install_base       # pacstrap -> populates /mnt

# ---- Prepare files that must exist inside chroot
# Write the correct files into /mnt so inside-chroot sourcing works.
# Order matters: definitions (functions) -> packages -> vars
install -m 644 definitions.sh /mnt/definitions.sh
install -m 644 packages.sh /mnt/packages.sh
install -m 600 vars.sh /mnt/vars.sh    # contains secrets/exports, keep mode restrictive

# ---- Enter the chroot and run the rest inside the target system
# Use absolute paths inside chroot to avoid ambiguity
arch-chroot /mnt /bin/bash -e <<'CHROOT_EOF'
set -euo pipefail
# Source helper files in the order we expect: definitions (functions), packages, vars
# definitions.sh inside chroot is /definitions.sh (we copied it above)
source /definitions.sh
source /packages.sh
source /vars.sh

# Now run the in-chroot steps (these functions must be defined in definitions.sh or packages.sh)
configure_pacman      # re-run inside installed system
setup_network
prepare_system
setup_users
prepare_gui
install_applications
enable_services
install_dotfiles

# leave chroot
CHROOT_EOF

# ---- cleanup & reboot
rm -fv /mnt/definitions.sh /mnt/packages.sh /mnt/vars.sh || true

# Unmount politely
umount -R /mnt || {
    echo "Unmount failed — you may need to unmount manually." >&2
}

echo "Installation finished. Reboot now? (y/N)"
read -r REBOOT
if [[ "${REBOOT,,}" == "y" ]]; then
    reboot
else
    echo "Reboot skipped. You can reboot manually when ready."
fi
