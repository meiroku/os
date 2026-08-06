#!/usr/bin/env nu

def main [] {
    let target_user = (if ("SUDO_USER" in $env) { $env.SUDO_USER } else { $env.USER })
    let target_uid = (^id -u $target_user | str trim)
    let debian_root = "/var/lib/machines/debian"

    def log-tty [msg: string] {
        $"($msg)\n" | save --append /dev/tty1
    }

    log-tty "Setting up Debian debootstrap..."
    if not ($debian_root | path exists) {
        mkdir $debian_root
    }
    
    ^eatmydata debootstrap --variant=minbase --arch=amd64 trixie $debian_root "https://deb.debian.org/debian/" o+e> /dev/tty1

    log-tty "Creating nspawn config..."
    if not ("/etc/systemd/nspawn" | path exists) {
        mkdir /etc/systemd/nspawn
    }
    
    let nspawn_config = "[Exec]
Boot=yes
PrivateUsers=no

[Network]
VirtualEthernet=no
ResolvConf=bind-host

[Files]
Bind=/home
Bind=/run/user
Bind=/tmp/.X11-unix
Bind=/dev/dri
Bind=/dev/shm
BindReadOnly=/usr/share/fonts:/usr/local/share/fonts
BindReadOnly=/usr/share/icons:/usr/local/share/icons
BindReadOnly=/usr/share/themes:/usr/local/share/themes
"
    $nspawn_config | save --force /etc/systemd/nspawn/debian.nspawn

    log-tty "Configuring Debian container..."
    
    def in-chroot [...args: string] {
        let input = $in
        if ($input == null) {
            ^chroot $debian_root ...$args
        } else {
            $input | ^chroot $debian_root ...$args
        }
    }

    cp --force /etc/resolv.conf $"($debian_root)/etc/resolv.conf"

    in-chroot apt-get update
    
    with-env { DEBIAN_FRONTEND: "noninteractive" } {
        in-chroot apt-get install -y wget curl gnupg ca-certificates sudo libgl1-mesa-dri libwayland-client0 libwayland-egl1 mesa-utils
    }

    in-chroot /usr/sbin/useradd -M -s /bin/bash -u $target_uid $target_user

    log-tty "Syncing hardware access groups to Debian container..."
    
    def get-gid [group_name: string] {
        try {
            ^cat /etc/group 
            | lines 
            | find --regex $"^($group_name):" 
            | first 
            | split row ":" 
            | get 2
        } catch {
            null
        }
    }

    let sync_groups = [
        { host: "video",  guest: "arch_video" },
        { host: "audio",  guest: "arch_audio" },
        { host: "render", guest: "arch_render" },
    ]

    for grp in $sync_groups {
        let gid = (get-gid $grp.host)
        if ($gid != null) and ($gid != "") {
            try { in-chroot /usr/sbin/groupadd -g $gid -o $grp.guest }
            try { in-chroot /usr/sbin/usermod -aG $grp.guest $target_user }
        }
    }

    in-chroot /usr/sbin/usermod -aG sudo -s /bin/bash -u $target_uid $target_user

    let arch_shadow_hash = (try {
        ^cat /etc/shadow
        | lines 
        | find --regex $"^($target_user):" 
        | first 
        | split row ":" 
        | get 1
    } catch {
        null
    })

    if ($arch_shadow_hash != null) and ($arch_shadow_hash != "!") and ($arch_shadow_hash != "*") and ($arch_shadow_hash != "") {
        log-tty "Syncing password hash to Debian container..."
        in-chroot /usr/sbin/usermod -p $arch_shadow_hash $target_user
    } else {
        $"($target_user):debian\n" | in-chroot /usr/sbin/chpasswd
        log-tty "Warning: Password sync failed. Default password set to 'debian'."
    }

    ^systemctl enable machines.target
    ^systemctl enable systemd-nspawn@debian.service
}
