# ---------- core package groups (small, well-commented) --------------------

# Core system components (always installed)
BASE=( base linux linux-firmware )

# Basic system utilities
BASE_APPS=(
  archlinux-keyring pacman-contrib base-devel cronie dialog dosfstools efibootmgr
  git grub linux-headers man-db mtools mtpfs network-manager-applet networkmanager
  openssh os-prober python reflector usbutils wget zsh
)

# Useful user applications (opt-in)
APPS=(
  alsa-utils exa ffmpeg firefox flameshot mpv neofetch neovim
  ntfs-3g numlockx p7zip pavucontrol pipewire pipewire-alsa pipewire-pulse
  python-pynvim ripgrep unrar unzip xclip zathura zathura-pdf-mupdf zenity
  xorg-xrandr zip
)

# Gaming stack (opt-in)
GAMING_APPS=(
  discord gamescope lutris mangohud steam steam-native-runtime wine
  wine-gecko wine-mono winetricks
)

# Services to enable on the target system
SERVICES=( NetworkManager cronie mpd sshd )

# Desktop environments list (presentation only) — kept uppercase for UI display
ENVIRONMENTS=( AWESOME BUDGIE BSPWM CINNAMON DEEPIN ENLIGHTENMENT GNOME KDE LXQT MATE QTILE XFCE )

# Map DE name -> space-separated package list (use lowercase keys)
declare -A DE_PKGS
DE_PKGS[awesome]="alacritty awesome-git breeze-gtk dex dunst engrampa feh gnome-keyring lightdm lightdm-gtk-greeter mate-polkit mpd papirus-icon-theme picom-pijulius-git rofi thunar wmctrl xdg-desktop-portal xdg-desktop-portal-gtk xorg-server xorg-xrandr"
DE_PKGS[budgie]="budgie-desktop lightdm lightdm-gtk-greeter xdg-desktop-portal xdg-desktop-portal-gtk xorg-server"
DE_PKGS[bspwm]="bspwm polybar sxhkd alacritty brightnessctl dunst rofi lsd jq polkit-gnome git playerctl mpd ncmpcpp geany ranger mpc picom feh ueberzug maim pamixer libwebp lightdm lightdm-gtk-greeter webp-pixbuf-loader xorg-xprop xorg-xkill physlock papirus-icon-theme ttf-jetbrains-mono ttf-jetbrains-mono-nerd ttf-terminus-nerd ttf-inconsolata ttf-joypixels"
DE_PKGS[cinnamon]="cinnamon lightdm lightdm-gtk-greeter xdg-desktop-portal xdg-desktop-portal-gtk xorg-server"
DE_PKGS[deepin]="deepin deepin-extra lightdm lightdm-gtk-greeter xdg-desktop-portal xdg-desktop-portal-gtk xorg-server"
DE_PKGS[enlightenment]="enlightenment lightdm lightdm-gtk-greeter terminology xdg-desktop-portal xdg-desktop-portal-gtk xorg-server"
DE_PKGS[gnome]="gdm gnome gnome-tweaks xdg-desktop-portal xdg-desktop-portal-gnome"
DE_PKGS[kde]="ark dolphin dolphin-plugins ffmpegthumbs filelight gwenview kcalc kcharselect kcolorchooser kcron kdeconnect kdegraphics-thumbnailers kdenetwork-filesharing kdesdk-thumbnailers kdialog kmix kolourpaint konsole kontrast okular packagekit-qt5 plasma print-manager sddm xdg-desktop-portal xdg-desktop-portal-kde"
DE_PKGS[lxqt]="breeze-icons lxqt lxqt-connman-applet sddm slock xdg-desktop-portal xdg-desktop-portal-kde"
DE_PKGS[mate]="lightdm lightdm-gtk-greeter mate mate-extra xdg-desktop-portal xdg-desktop-portal-gtk xorg-server"
DE_PKGS[qtile]="alacritty breeze-gtk dex dunst engrampa feh gnome-keyring light lightdm lightdm-gtk-greeter mate-polkit mpd papirus-icon-theme picom qtile rofi thunar wmctrl xdg-desktop-portal xdg-desktop-portal-gtk xorg-server xorg-xrandr"
DE_PKGS[xfce]="lightdm lightdm-gtk-greeter xdg-desktop-portal xdg-desktop-portal-gtk xfce4 xfce4-goodies xorg-server"

# ---------- helpers: merge + dedupe arrays ---------------------------------

# uniq_array dst_array src_arrays...
# merges src arrays into dst and removes duplicates while preserving order
uniq_array() {
  local -n _dst=$1
  shift
  local -A _seen=()
  local item
  for arrname in "$@"; do
    local -n _arr="$arrname"
    for item in "${_arr[@]}"; do
      if [[ -z "${_seen[$item]:-}" ]]; then
        _dst+=("$item")
        _seen[$item]=1
      fi
    done
  done
}

# uniq_string_list -> returns deduped array from whitespace-separated string(s)
uniq_from_strings() {
  local -a out=()
  local -A seen=()
  local token
  for str in "$@"; do
    for token in $str; do
      if [[ -z "${seen[$token]:-}" ]]; then
        out+=("$token")
        seen[$token]=1
      fi
    done
  done
  printf '%s\n' "${out[@]}"
}

# ---------- GPU detection (populates GPU_DRIVERS) --------------------------

populate_gpu_drivers() {
  GPU_DRIVERS=()
  # use lspci to detect vendor ids
  local lsp
  if ! command -v lspci >/dev/null 2>&1; then
    warn "lspci not found; skipping GPU auto-detection."
    return 0
  fi
  lsp="$(lspci -nn 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  if grep -q 'vga.*nvidia' <<<"$lsp" || grep -q '3d controller.*nvidia' <<<"$lsp"; then
    GPU_DRIVERS+=( nvidia nvidia-utils )
    # add nvidia-lts if kernel LTS is used later (optional)
  fi
  if grep -q 'vga.*amd' <<<"$lsp" || grep -q '3d controller.*amd' <<<"$lsp"; then
    GPU_DRIVERS+=( xf86-video-amdgpu mesa )
  fi
  if grep -q 'vga.*intel' <<<"$lsp" || grep -q '3d controller.*intel' <<<"$lsp"; then
    GPU_DRIVERS+=( xf86-video-intel mesa )
  fi

  # remove duplicates while preserving order
  local -a uniq_gpu=()
  uniq_array uniq_gpu GPU_DRIVERS
  GPU_DRIVERS=("${uniq_gpu[@]}")
}

# ---------- assemble final package list based on selections -----------------

# assemble_packages <de_key> <include_apps_yesno> <include_gaming_yesno>
# returns global array FINAL_PKGS
assemble_packages() {
  local de_key="${1:-}"           # expected lowercased (e.g. "bspwm")
  local include_apps="${2:-No}"   # "Yes"/"No"
  local include_gaming="${3:-No}"

  # ensure GPU drivers detected
  populate_gpu_drivers

  FINAL_PKGS=()

  # merge base groups
  uniq_array FINAL_PKGS BASE BASE_APPS

  # add GPU drivers (if any)
  if ((${#GPU_DRIVERS[@]})); then
    uniq_array FINAL_PKGS GPU_DRIVERS
  fi

  # add DE packages if available
  if [[ -n "$de_key" && -n "${DE_PKGS[$de_key]:-}" ]]; then
    # turn space-separated string into an array
    read -r -a de_arr <<< "${DE_PKGS[$de_key]}"
    uniq_array FINAL_PKGS de_arr
  fi

  # add optional general apps
  if [[ "${include_apps^^}" == "YES" ]]; then
    uniq_array FINAL_PKGS APPS
  fi

#   # gaming extras
#   if [[ "${include_gaming^^}" == "YES" ]]; then
#     uniq_array FINAL_PKGS GAMING_APPS
#   fi

  # ensure essential services (not packages) are included in SERVICES var already
  # return success and let caller use FINAL_PKGS[@]
}

# ---------- small utility: print summary of package plan --------------------

print_package_plan() {
  local -n _pkgs=$1
  _info "Package plan (${#_pkgs[@]} packages):"
  local p
  for p in "${_pkgs[@]}"; do
    printf "  - %s\n" "$p"
  done
}

# ---------- example usage ---------------------------------------------------
# NOTE: ensure DE is lowercased key (e.g. from selection: DE="${DE,,}")
# DE is expected to be set by your earlier interactive flow.

# Example:
# DE='bspwm' ; assemble_packages "$DE" "Yes" "No" ; print_package_plan FINAL_PKGS
#
# Then install with:
# pacman -Sy --needed --noconfirm "${FINAL_PKGS[@]}"
#
# Also enable systemd services:
# for s in "${SERVICES[@]}"; do systemctl enable --now "$s"; done
