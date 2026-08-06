#!/usr/bin/env nu

def log-info [msg: string] {
    print -e $"(ansi green_bold)[INFO](ansi reset) ($msg)"
}

def log-warn [msg: string] {
    print -e $"(ansi yellow_bold)[WARN](ansi reset) ($msg)"
}

def log-error [msg: string] {
    print -e $"(ansi red_bold)[ERROR](ansi reset) ($msg)"
}

def main [] {
    if (^id -u | str trim) != "0" {
        log-error "This script must be run as root."
        exit 1
    }

    if ("SUDO_USER" not-in $env) {
        log-error "This script must be run via sudo to determine the target user."
        exit 1
    }

    let target_user = $env.SUDO_USER
    if $target_user == "root" {
        log-error "SUDO_USER is root. Please run via sudo from a normal user."
        exit 1
    }

    let target_uid = (^id -u $target_user | str trim)
    let debian_root = "/var/lib/machines/debian"

    log-info $"Target user: ($target_user), (UID: ($target_uid))"
    log-info $"Container root: ($debian_root)"

    if not ($debian_root | path exists) {
        log-info "Creating container root directory..."
        mkdir $debian_root
    }

    if not ([$debian_root, "etc", "debian_version"] | path join | path exists) {
        log-info "Running debootstrap (this may take a while)..."
        ^debootstrap --variant=minbase --arch=amd64 trixie $debian_root "https://deb.debian.org/debian/"
    } else {
        log-info "Debian base system already exists, skipping debootstrap."
    }

    log-info "Generating nspawn config..."
    if not ("/etc/systemd/nspawn" | path exists) {
        mkdir /etc/systemd/nspawn
    }

    let nspawn_config = $"[Exec]
Boot=yes
PrivateUsers=no

[Network]
VirtualEthernet=no
ResolvConf=bind-host

[Files]
Bind=/run/user/($target_uid)
Bind=/tmp/.X11-unix
Bind=/dev/dri
Bind=/dev/shm
Bind=/dev/snd
Bind=/dev/input
BindReadOnly=/run/dbus/system_bus_socket
BindReadOnly=/usr/share/fonts:/usr/local/share/fonts
BindReadOnly=/usr/share/icons:/usr/local/share/icons
BindReadOnly=/usr/share/themes:/usr/local/share/themes
"
    $nspawn_config | save --force /etc/systemd/nspawn/debian.nspawn

    def --wrapped in-nspawn [...args: string] {
        ^systemd-nspawn -q -D $debian_root -E DEBIAN_FRONTEND=noninteractive --as-pid2 ...$args
    }

    log-info "Updating package lists..."
    in-nspawn apt-get update

    log-info "Installing essential and GUI packages..."
    in-nspawn apt-get install -y systemd systemd-sysv wget curl gnupg ca-certificates sudo libgl1-mesa-dri libwayland-client0 libwayland-egl1 mesa-utils mesa-vulkan-drivers libvulkan1 xwayland libpulse0 pipewire-alsa dbus-user-session

    log-info "Configuring container user..."
    let user_exists = (in-nspawn getent passwd $target_user | complete | get exit_code) == 0
    if not $user_exists {
        in-nspawn /usr/sbin/useradd -m -s /bin/bash -u $target_uid $target_user
    } else {
        log-info $"User ($target_user) already exists in container."
    }

    log-info "Syncing group IDs from host..."
    def get-host-gid [group_name: string] {
        open /etc/group 
        | lines 
        | parse "{name}:{pwd}:{gid}:{users}"
        | where name == $group_name 
        | get 0?.gid?
    }

    let groups = ["video", "audio", "render", "input"]
    
    for grp in $groups {
        let gid = (get-host-gid $grp)
        if ($gid != null) {
            log-info $"Syncing group ($grp) to GID ($gid)..."
            let group_exists = (in-nspawn getent group $grp | complete | get exit_code) == 0
            if $group_exists {
                try { in-nspawn /usr/sbin/groupmod -g $gid $grp }
            } else {
                try { in-nspawn /usr/sbin/groupadd -g $gid $grp }
            }
            try { in-nspawn /usr/sbin/usermod -aG $grp $target_user }
        } else {
            log-warn $"Group ($grp) not found on host, skipping."
        }
    }

    in-nspawn /usr/sbin/usermod -aG sudo $target_user

    log-info "Syncing user password from host..."
    let arch_shadow_hash = (
        open /etc/shadow
        | lines 
        | parse "{name}:{hash}:{rest}"
        | where name == $target_user 
        | get 0?.hash?
    )

    if ($arch_shadow_hash != null) and ($arch_shadow_hash != "!") and ($arch_shadow_hash != "*") {
        in-nspawn /usr/sbin/usermod -p $arch_shadow_hash $target_user
    } else {
        log-warn "Could not retrieve valid hash from host. Setting default password 'debian'."
        $"($target_user):debian\n" | in-nspawn /usr/sbin/chpasswd
    }

    log-info "Enabling systemd services on host..."
    ^systemctl enable machines.target
    ^systemctl enable systemd-nspawn@debian.service
    ^systemctl start machines.target

    log-info "Setup complete! You can start the container with:"
    log-info "  machinectl start debian"
    log-info "And log in with:"
    log-info $"  machinectl shell ($target_user)@debian"
}
