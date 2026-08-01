#!/usr/bin/env bash
set -euo pipefail

echo "=== Starting Post-Install Setup ===" > /dev/tty

# --- クリーンアップ処理 ---
cleanup() {
    echo "Cleaning up temporary files and directories..." > /dev/tty
    rm -f /etc/sudoers.d/temp_aur
    rm -rf /tmp/yay-bin
    rm -rf /tmp/meiroku-os
}
trap cleanup EXIT

# --- 依存パッケージのインストール ---
echo "Installing required dependencies..." > /dev/tty
pacman -S --noconfirm --needed git base-devel sudo debootstrap debian-archive-keyring rsync curl libeatmydata

# --- ターゲットユーザーの特定 ---
TARGET_USER=$(id -un 1000 2>/dev/null || ls -1 /home | grep -vw lost+found | head -n 1 || true)

if [ -z "$TARGET_USER" ]; then
    echo "Error: Target user not found!" > /dev/tty
    exit 1
fi

TARGET_UID=$(id -u "${TARGET_USER}")
TARGET_GID=$(id -g "${TARGET_USER}")
echo "Target User identified as: ${TARGET_USER} (UID: ${TARGET_UID}, GID: ${TARGET_GID})" > /dev/tty

# --- カスタムrootfsとskelの適用 ---
echo "Fetching and applying rootfs and skel..." > /dev/tty
REPO_URL="https://github.com/meiroku/os.git"
REPO_DIR="/tmp/meiroku-os"

rm -rf "$REPO_DIR"
git clone "$REPO_URL" "$REPO_DIR"

if [ -d "${REPO_DIR}/rootfs" ]; then
    # rootfsをシステムルートに適用
    rsync -a "${REPO_DIR}/rootfs/" /
    # skelをユーザー権限でホームディレクトリにコピー
    rsync -a --chown="${TARGET_UID}:${TARGET_GID}" /etc/skel/ "/home/${TARGET_USER}/"
    echo "rootfs and skel applied successfully." > /dev/tty
else
    echo "Warning: rootfs directory not found in the repository." > /dev/tty
fi

# --- AURヘルパー (yay) の導入 ---
echo "${TARGET_USER} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/temp_aur
chmod 440 /etc/sudoers.d/temp_aur

echo "Building and installing yay..." > /dev/tty
rm -rf /tmp/yay-bin
git clone https://aur.archlinux.org/yay-bin.git /tmp/yay-bin
chown -R "${TARGET_UID}:${TARGET_GID}" /tmp/yay-bin
sudo -u "${TARGET_USER}" -H bash -c "cd /tmp/yay-bin && makepkg -si --noconfirm"

# --- 必須AURパッケージのインストール ---
echo "Installing AUR packages..." > /dev/tty
sudo -u "${TARGET_USER}" -H yay -S --noconfirm --needed noctalia noctalia-greeter
systemctl enable greetd

# --- Debian debootstrap とコンテナ設定 ---
printf '%b' \
'\033[1;33m[IMPORTANT] Starting Debian base system setup (debootstrap).\033[0m\n' \
'\033[1;33mThis may take a few minutes depending on your network and storage speed.\033[0m\n' \
'\033[1;31mEven if it appears to be stuck at '\''Unpacking...'\'' , the process is still running.\033[0m\n' \
'\033[1;31mDo NOT press Ctrl+C or interrupt the process.\033[0m\n\n' > /dev/tty

DEBIAN_ROOT="/var/lib/machines/debian"
mkdir -p "${DEBIAN_ROOT}"
eatmydata debootstrap --variant=minbase --arch=amd64 trixie "${DEBIAN_ROOT}" https://deb.debian.org/debian/ > /dev/tty 2>&1

echo "Creating nspawn config..." > /dev/tty
mkdir -p /etc/systemd/nspawn
cat << 'EOF' > /etc/systemd/nspawn/debian.nspawn
[Exec]
Boot=yes
PrivateUsers=no

[Files]
Bind=/home
Bind=/run/user
Bind=/tmp/.X11-unix
Bind=/dev/dri
Bind=/dev/shm
BindReadOnly=/usr/share/fonts
BindReadOnly=/usr/share/icons
BindReadOnly=/usr/share/themes
EOF

echo "Configuring Debian container..." > /dev/tty
CHROOT_CMD=(chroot "${DEBIAN_ROOT}")

# Debian側のパッケージをインストール
"${CHROOT_CMD[@]}" apt-get update
"${CHROOT_CMD[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y wget curl gnupg ca-certificates sudo libgl1-mesa-dri libwayland-client0 libwayland-egl1 mesa-utils

# ユーザー作成
"${CHROOT_CMD[@]}" /usr/sbin/useradd -M -s /bin/bash -u "${TARGET_UID}" "${TARGET_USER}"

# --- GIDの同期 ---
# Arch側でのグループIDを取得
ARCH_VIDEO_GID=$(getent group video | cut -d: -f3 || echo "")
ARCH_AUDIO_GID=$(getent group audio | cut -d: -f3 || echo "")
ARCH_RENDER_GID=$(getent group render | cut -d: -f3 || echo "")

echo "Syncing hardware access groups to Debian container..." > /dev/tty
if [ -n "$ARCH_VIDEO_GID" ]; then
    "${CHROOT_CMD[@]}" /usr/sbin/groupadd -g "$ARCH_VIDEO_GID" -o arch_video || true
    "${CHROOT_CMD[@]}" /usr/sbin/usermod -aG arch_video "${TARGET_USER}"
fi
if [ -n "$ARCH_AUDIO_GID" ]; then
    "${CHROOT_CMD[@]}" /usr/sbin/groupadd -g "$ARCH_AUDIO_GID" -o arch_audio || true
    "${CHROOT_CMD[@]}" /usr/sbin/usermod -aG arch_audio "${TARGET_USER}"
fi
if [ -n "$ARCH_RENDER_GID" ]; then
    "${CHROOT_CMD[@]}" /usr/sbin/groupadd -g "$ARCH_RENDER_GID" -o arch_render || true
    "${CHROOT_CMD[@]}" /usr/sbin/usermod -aG arch_render "${TARGET_USER}"
fi
# Debian本来のsudoグループ等へも追加
"${CHROOT_CMD[@]}" /usr/sbin/usermod -aG sudo "${TARGET_USER}"

# コンテナサービスの有効化
systemctl enable machines.target
systemctl enable systemd-nspawn@debian.service

# --- カスタム apt ラッパースクリプトのセットアップ ---
echo "Setting up apt wrapper script..." > /dev/tty
if [ -f /usr/local/bin/apt ]; then
    chmod +x /usr/local/bin/apt
else
    echo "Warning: apt wrapper not found in rootfs. Downloading directly..." > /dev/tty
    curl -sL https://raw.githubusercontent.com/meiroku/os/main/rootfs/usr/local/bin/apt > /usr/local/bin/apt
    chmod +x /usr/local/bin/apt
fi

echo "=== Post-Install Setup Completed Successfully ===" > /dev/tty
