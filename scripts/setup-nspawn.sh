#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

# --- エラー時の表示 ---
trap 'log_error "Failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

# --- ANSIエスケープシーケンス ---
readonly GREEN=$'\033[1;32m'
readonly YELLOW=$'\033[1;33m'
readonly RED=$'\033[1;31m'
readonly RESET=$'\033[0m'

log_info()  { printf '%b\n' "${GREEN}[INFO]${RESET} $*"; }
log_warn()  { printf '%b\n' "${YELLOW}[WARN]${RESET} $*"; }
log_error() { printf '%b\n' "${RED}[ERROR]${RESET} $*" >&2; }
die()       { log_error "$*"; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command '$1' is not installed."
}

in_nspawn() {
    systemd-nspawn \
        --quiet \
        --directory="$DEBIAN_ROOT" \
        --as-pid2 \
        -E DEBIAN_FRONTEND=noninteractive \
        "$@"
}

hash_is_valid() {
    local hash="${1:-}"
    [[ -n "$hash" && "$hash" != "!" && "$hash" != "*" && "$hash" != "!!" ]]
}

ensure_container_group() {
    local group_name="$1"
    local host_gid="$2"

    if in_nspawn getent group "$group_name" >/dev/null 2>&1; then
        local container_gid
        container_gid="$(in_nspawn getent group "$group_name" | cut -d: -f3)"

        if [[ "$container_gid" != "$host_gid" ]]; then
            if in_nspawn getent group "$host_gid" >/dev/null 2>&1; then
                log_warn "Container already has another group using GID ${host_gid}; skipping sync for ${group_name}."
            else
                in_nspawn groupmod -g "$host_gid" "$group_name"
            fi
        fi
    else
        if in_nspawn getent group "$host_gid" >/dev/null 2>&1; then
            log_warn "Container already has another group using GID ${host_gid}; creating ${group_name} was skipped."
        else
            in_nspawn groupadd -g "$host_gid" "$group_name"
        fi
    fi

    in_nspawn usermod -aG "$group_name" "$TARGET_USER" || true
}

# --- 事前チェック ---
if (( EUID != 0 )); then
    die "This script must be run as root via sudo."
fi

if [[ -z "${SUDO_USER:-}" || "${SUDO_USER:-}" == "root" ]]; then
    die "This script must be run via sudo from a normal user."
fi

for cmd in debootstrap systemd-nspawn machinectl dpkg getent; do
    require_cmd "$cmd"
done

# --- 変数定義 ---
readonly CONTAINER_NAME="debian"
readonly TARGET_USER="$SUDO_USER"
readonly TARGET_UID="$(id -u "$TARGET_USER")"
readonly TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
readonly HOST_ARCH="$(dpkg --print-architecture)"
readonly DEBIAN_ROOT="/var/lib/machines/${CONTAINER_NAME}"
readonly DEBIAN_RELEASE="trixie"
readonly DEBIAN_MIRROR="https://deb.debian.org/debian/"

[[ -n "$TARGET_HOME" ]] || die "Could not resolve home directory for user '${TARGET_USER}'."

log_info "Target user: ${TARGET_USER} [UID: ${TARGET_UID}]"
log_info "Target home: ${TARGET_HOME}"
log_info "Host architecture: ${HOST_ARCH}"
log_info "Container root: ${DEBIAN_ROOT}"

# --- コンテナ作成 ---
mkdir -p "$DEBIAN_ROOT"

if [[ ! -f "$DEBIAN_ROOT/etc/debian_version" ]]; then
    log_info "Running debootstrap (${DEBIAN_RELEASE}, this may take a while)..."
    debootstrap \
        --variant=minbase \
        --arch="$HOST_ARCH" \
        --no-check-gpg \
        "$DEBIAN_RELEASE" \
        "$DEBIAN_ROOT" \
        "$DEBIAN_MIRROR"
else
    log_info "Debian base system already exists, skipping debootstrap."
fi

# --- nspawn 設定 ---
log_info "Generating nspawn config..."
install -d -m 0755 /etc/systemd/nspawn

cat > "/etc/systemd/nspawn/${CONTAINER_NAME}.nspawn" <<EOF
[Exec]
Boot=yes
PrivateUsers=no
ResolvConf=bind-host
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK

[Network]
VirtualEthernet=no

[Files]
EOF

append_bind() {
    local src="$1"
    local readonly_flag="${2:-0}"
    if [[ -e "$src" ]]; then
        if (( readonly_flag == 1 )); then
            echo "BindReadOnly=${src}" >> "/etc/systemd/nspawn/${CONTAINER_NAME}.nspawn"
        else
            echo "Bind=${src}" >> "/etc/systemd/nspawn/${CONTAINER_NAME}.nspawn"
        fi
    fi
}

append_bind "/run/user/${TARGET_UID}" 0
append_bind "/tmp/.X11-unix" 0
append_bind "/dev/dri" 0
append_bind "/dev/shm" 0
append_bind "/dev/snd" 0
append_bind "/dev/input" 0
append_bind "/run/dbus/system_bus_socket" 1
append_bind "/etc/machine-id" 1
append_bind "/etc/localtime" 1

# aptと競合しないように、ホストのシステムリソースは /usr/local/share/... にマウントする
for dir in fonts icons themes; do
    if [[ -d "/usr/share/${dir}" ]]; then
        echo "BindReadOnly=/usr/share/${dir}:/usr/local/share/${dir}" >> "/etc/systemd/nspawn/${CONTAINER_NAME}.nspawn"
    fi
done

if [[ -f "${TARGET_HOME}/.Xauthority" ]]; then
    echo "BindReadOnly=${TARGET_HOME}/.Xauthority:/home/${TARGET_USER}/.Xauthority" >> "/etc/systemd/nspawn/${CONTAINER_NAME}.nspawn"
    mkdir -p "${DEBIAN_ROOT}/home/${TARGET_USER}"
    touch "${DEBIAN_ROOT}/home/${TARGET_USER}/.Xauthority"
fi

if [[ -d "${TARGET_HOME}/.local/share/fonts" ]]; then
    echo "BindReadOnly=${TARGET_HOME}/.local/share/fonts:/home/${TARGET_USER}/.local/share/fonts" >> "/etc/systemd/nspawn/${CONTAINER_NAME}.nspawn"
    mkdir -p "${DEBIAN_ROOT}/home/${TARGET_USER}/.local/share/fonts"
fi

if [[ -d "${TARGET_HOME}/.icons" ]]; then
    echo "BindReadOnly=${TARGET_HOME}/.icons:/home/${TARGET_USER}/.icons" >> "/etc/systemd/nspawn/${CONTAINER_NAME}.nspawn"
    mkdir -p "${DEBIAN_ROOT}/home/${TARGET_USER}/.icons"
fi

# --- コンテナ内の初期設定 ---
log_info "Updating package lists..."
in_nspawn apt-get update -q

# パッケージインストール中のデーモン自動起動をブロックする
cat > "${DEBIAN_ROOT}/usr/sbin/policy-rc.d" << 'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "${DEBIAN_ROOT}/usr/sbin/policy-rc.d"

log_info "Installing essential packages..."
in_nspawn apt-get install -yq --no-install-recommends \
    systemd systemd-sysv passwd sudo locales dbus dbus-user-session \
    wget curl gnupg ca-certificates \
    libgl1-mesa-dri libwayland-client0 libwayland-egl1 \
    mesa-utils mesa-vulkan-drivers libvulkan1 xwayland \
    libpulse0 pipewire-alsa \
    wayland-utils x11-apps iproute2 iputils-ping \
    fonts-noto-cjk xdg-user-dirs

# ブロック解除
rm -f "${DEBIAN_ROOT}/usr/sbin/policy-rc.d"

log_info "Configuring locales..."
in_nspawn sed -i \
    -e 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' \
    -e 's/^# *ja_JP.UTF-8 UTF-8/ja_JP.UTF-8 UTF-8/' \
    /etc/locale.gen
in_nspawn locale-gen
in_nspawn update-locale LANG=ja_JP.UTF-8 LANGUAGE=ja_JP:ja

log_info "Configuring container user..."
if ! in_nspawn getent passwd "$TARGET_USER" >/dev/null 2>&1; then
    in_nspawn useradd -m -U -s /bin/bash -u "$TARGET_UID" "$TARGET_USER"
else
    log_info "User '${TARGET_USER}' already exists in container."
fi

log_info "Syncing group IDs from host..."
for grp in video audio render input; do
    host_gid="$(getent group "$grp" | cut -d: -f3 || true)"
    if [[ -n "$host_gid" ]]; then
        ensure_container_group "$grp" "$host_gid"
    else
        log_warn "Group '${grp}' not found on host, skipping."
    fi
done

if ! in_nspawn getent group sudo >/dev/null 2>&1; then
    in_nspawn groupadd sudo
fi
in_nspawn usermod -aG sudo "$TARGET_USER" || true

log_info "Syncing user password from host..."
host_hash="$(getent shadow "$TARGET_USER" | cut -d: -f2 || true)"

if hash_is_valid "$host_hash"; then
    in_nspawn usermod -p "$host_hash" "$TARGET_USER"
else
    log_warn "Valid password hash could not be retrieved from host. Setting fallback password 'debian'."
    printf '%s:%s\n' "$TARGET_USER" "debian" | in_nspawn chpasswd
fi

log_info "Configuring GUI environment variables..."
install -d -m 0755 "${DEBIAN_ROOT}/etc/profile.d"

cat > "${DEBIAN_ROOT}/etc/profile.d/99-gui-env.sh" <<'EOF'
# Auto-configured for GUI applications in systemd-nspawn

export XDG_RUNTIME_DIR="/run/user/$(id -u)"

if [ -d "$XDG_RUNTIME_DIR" ]; then
    for w_sock in "$XDG_RUNTIME_DIR"/wayland-*; do
        case "$w_sock" in
            *.lock) continue ;;
        esac
        [ -S "$w_sock" ] || continue
        export WAYLAND_DISPLAY="${w_sock##*/}"
        export QT_QPA_PLATFORM="wayland"
        break
    done
fi

if [ -d /tmp/.X11-unix ]; then
    for x_sock in /tmp/.X11-unix/X*; do
        [ -S "$x_sock" ] || continue
        export DISPLAY=":${x_sock##*/X}"
        break
    done
fi
EOF
chmod 0644 "${DEBIAN_ROOT}/etc/profile.d/99-gui-env.sh"

# --- ホスト側 service 設定 ---
log_info "Reloading host systemd and enabling container service..."
systemctl daemon-reload
systemctl enable --now "systemd-nspawn@${CONTAINER_NAME}.service"

log_info "==================================================="
log_info "Setup complete. The container '${CONTAINER_NAME}' is now running."
log_info "Enter the container with:"
printf '\n%b\n' "${GREEN}  machinectl shell ${TARGET_USER}@${CONTAINER_NAME}${RESET}"
printf '\n'
log_info "GUI app tests:"
log_info "  Wayland: wayland-info"
log_info "  X11: xeyes"
log_info "  GPU 3D: glxgears"
log_info "==================================================="
