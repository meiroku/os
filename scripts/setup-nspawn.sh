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

get_debian_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armhf" ;;
        i686)    echo "i386" ;;
        *)       uname -m ;;
    esac
}

# --- 事前チェック ---
if (( EUID != 0 )); then
    die "This script must be run as root via sudo."
fi

if [[ -z "${SUDO_USER:-}" || "${SUDO_USER:-}" == "root" ]]; then
    die "This script must be run via sudo from a normal user."
fi

for cmd in debootstrap systemd-nspawn machinectl getent; do
    require_cmd "$cmd"
done

# --- 変数定義 ---
readonly CONTAINER_NAME="debian"
readonly TARGET_USER="$SUDO_USER"
readonly TARGET_UID="$(id -u "$TARGET_USER")"
readonly TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
readonly HOST_ARCH="$(get_debian_arch)"
readonly DEBIAN_ROOT="/var/lib/machines/${CONTAINER_NAME}"
readonly DEBIAN_RELEASE="trixie"
readonly DEBIAN_MIRROR="https://deb.debian.org/debian/"

[[ -n "$TARGET_HOME" ]] || die "Could not resolve home directory for user '${TARGET_USER}'."

log_info "Target user: ${TARGET_USER} [UID: ${TARGET_UID}]"
log_info "Target home: ${TARGET_HOME}"
log_info "Host architecture: ${HOST_ARCH}"
log_info "Container root: ${DEBIAN_ROOT}"

# --- 古い設定ファイルのクリーンアップ ---
rm -f "/etc/systemd/nspawn/${CONTAINER_NAME}.nspawn"

# --- コンテナ作成 ---
mkdir -p "$DEBIAN_ROOT"

if [[ ! -f "$DEBIAN_ROOT/etc/debian_version" ]]; then
    log_info "Running debootstrap (${DEBIAN_RELEASE}, this may take a while)..."
    debootstrap \
        --variant=minbase \
        --arch="$HOST_ARCH" \
        "$DEBIAN_RELEASE" \
        "$DEBIAN_ROOT" \
        "$DEBIAN_MIRROR"
else
    log_info "Debian base system already exists, skipping debootstrap."
fi

# --- ネットワーク・ホスト名の初期設定 ---
log_info "Configuring hostname and /etc/hosts..."
echo "$CONTAINER_NAME" > "${DEBIAN_ROOT}/etc/hostname"
cat > "${DEBIAN_ROOT}/etc/hosts" <<EOF
127.0.0.1   localhost
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
127.0.1.1   ${CONTAINER_NAME}
EOF

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
    libcanberra-gtk3-module \
    wayland-utils x11-apps iproute2 iputils-ping \
    fonts-noto-cjk xdg-user-dirs

# ブロック解除
rm -f "${DEBIAN_ROOT}/usr/sbin/policy-rc.d"

log_info "Cleaning up apt cache..."
in_nspawn apt-get clean
in_nspawn rm -rf /var/lib/apt/lists/*

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
    in_nspawn cp -rnT /etc/skel "/home/${TARGET_USER}"
    in_nspawn mkdir -p "/home/${TARGET_USER}/.local/share" "/home/${TARGET_USER}/.icons"
    in_nspawn bash -c "chown -R '${TARGET_USER}:${TARGET_USER}' '/home/${TARGET_USER}' 2>/dev/null || true"
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

export XDG_RUNTIME_DIR="/mnt/host_run_user"
export PULSE_SERVER="unix:${XDG_RUNTIME_DIR}/pulse/native"

if [ -S "${XDG_RUNTIME_DIR}/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
fi

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

        # X11認証ファイルの自動検出
        if [ -z "${XAUTHORITY:-}" ]; then
            if [ -f "$HOME/.Xauthority" ]; then
                export XAUTHORITY="$HOME/.Xauthority"
            fi
            # /mnt/host_run_user に配置される動的認証ファイルを探す
            for auth in "$XDG_RUNTIME_DIR"/.mutter-Xwaylandauth.* "$XDG_RUNTIME_DIR"/xauth_* "$XDG_RUNTIME_DIR"/Xauthority; do
                if [ -f "$auth" ] && [ -r "$auth" ]; then
                    export XAUTHORITY="$auth"
                    break
                fi
            done
        fi
        break
    done
fi
# terminfoデータベースに存在しない端末(xterm-ghosttyなど)のエラー回避
if ! infocmp >/dev/null 2>&1; then
    export TERM=xterm-256color
fi
EOF
chmod 0644 "${DEBIAN_ROOT}/etc/profile.d/99-gui-env.sh"

log_info "Configuring bashrc for automatic GUI environment setup..."
if ! in_nspawn grep -q "99-gui-env.sh" "/home/${TARGET_USER}/.bashrc"; then
    cat >> "${DEBIAN_ROOT}/home/${TARGET_USER}/.bashrc" << 'EOF'

if [ -f /etc/profile.d/99-gui-env.sh ]; then
    source /etc/profile.d/99-gui-env.sh
fi
EOF
fi

# --- バインド元ディレクトリ・ファイルの保証 ---
log_info "Ensuring host paths exist for bind mounts..."
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix || true

# ユーザー権限でホームディレクトリ以下の必要なパスを作成
sudo -u "$TARGET_USER" mkdir -p \
    "${TARGET_HOME}/.local/share/fonts" \
    "${TARGET_HOME}/.icons" \
    "${TARGET_HOME}/.themes"

if [[ ! -f "${TARGET_HOME}/.Xauthority" ]]; then
    sudo -u "$TARGET_USER" touch "${TARGET_HOME}/.Xauthority"
fi

# --- nspawn 設定（必ずコンテナ内初期設定の後に実行） ---
log_info "Generating nspawn config..."
install -d -m 0755 /etc/systemd/nspawn

cat > "/etc/systemd/nspawn/${CONTAINER_NAME}.nspawn" <<EOF
[Exec]
Boot=yes
PrivateUsers=no
ResolvConf=bind-host
SystemCallFilter=@system-service @sandbox
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK AF_BLUETOOTH

[Network]
VirtualEthernet=no

[Files]
Bind=/run/user/${TARGET_UID}:/mnt/host_run_user
Bind=/tmp/.X11-unix
BindReadOnly=/etc/localtime
BindReadOnly=${TARGET_HOME}/.Xauthority:/home/${TARGET_USER}/.Xauthority
BindReadOnly=${TARGET_HOME}/.local/share/fonts:/home/${TARGET_USER}/.local/share/fonts
BindReadOnly=${TARGET_HOME}/.icons:/home/${TARGET_USER}/.icons
EOF

# ハードウェア依存ノードが存在する場合のみ追記
for src in "/dev/dri" "/dev/snd" "/dev/input"; do
    [[ -e "$src" ]] && echo "Bind=$src" >> "/etc/systemd/nspawn/${CONTAINER_NAME}.nspawn"
done

# システムの共有リソースが存在する場合のみ追記
for dir in "fonts" "icons" "themes"; do
    if [[ -d "/usr/share/${dir}" ]]; then
        echo "BindReadOnly=/usr/share/${dir}:/usr/local/share/${dir}" >> "/etc/systemd/nspawn/${CONTAINER_NAME}.nspawn"
    fi
done

# --- ホスト側 systemd サービス設定 ---
log_info "Configuring systemd override for race condition prevention..."
OVERRIDE_DIR="/etc/systemd/system/systemd-nspawn@${CONTAINER_NAME}.service.d"
mkdir -p "$OVERRIDE_DIR"
cat > "${OVERRIDE_DIR}/override.conf" <<EOF
[Unit]
# Ensure host's user runtime directory (/run/user/${TARGET_UID}) exists before starting container
After=user@${TARGET_UID}.service
Requires=user@${TARGET_UID}.service
EOF

log_info "Reloading host systemd and enabling container service..."
systemctl daemon-reload
systemctl enable --now "systemd-nspawn@${CONTAINER_NAME}.service"

log_info "======================================================"
log_info "Setup complete. The container '${CONTAINER_NAME}' is now running."
log_info "Enter the container with:"
printf '\n%b\n' "${GREEN}  machinectl shell ${TARGET_USER}@${CONTAINER_NAME}${RESET}"
printf '\n'
log_info "GUI app tests:"
log_info "  Wayland: wayland-info"
log_info "  X11: xeyes"
log_info "  GPU 3D: glxgears"
log_info "======================================================"
