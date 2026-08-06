#!/usr/bin/env nu

def main [] {
    let target_user = if ("SUDO_USER" in $env) { $env.SUDO_USER } else { $env.USER }
    let target_uid = (^id -u $target_user | str trim)
    let debian_root = "/var/lib/machines/debian"

    print $"(ansi green)Setting up Debian debootstrap...(ansi reset)"
    if not ($debian_root | path exists) {
        mkdir $debian_root
    }
    
    ^debootstrap --variant=minbase --arch=amd64 trixie $debian_root "https://deb.debian.org/debian/"

    print $"(ansi green)Creating nspawn config...(ansi reset)"
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

    print $"(ansi green)Configuring Debian container...(ansi reset)"
    
    def --wrapped in-chroot [...args: string] {
        let input = $in
        if ($input | is-empty) {
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

    print $"(ansi green)Syncing hardware access groups to Debian container...(ansi reset)"
    
    def get-gid [group_name: string] {
        open --raw /etc/group 
        | lines 
        | split column ":" name pwd gid users 
        | where name == $group_name 
        | get -i 0.gid
    }

    let sync_groups = [
        { host: "video",  guest: "arch_video" },
        { host: "audio",  guest: "arch_audio" },
        { host: "render", guest: "arch_render" },
    ]

    for grp in $sync_groups {
        let gid = (get-gid $grp.host)
        if not ($gid | is-empty) {
            try { in-chroot /usr/sbin/groupadd -g $gid -o $grp.guest }
            try { in-chroot /usr/sbin/usermod -aG $grp.guest $target_user }
        }
    }

    in-chroot /usr/sbin/usermod -aG sudo -s /bin/bash -u $target_uid $target_user

    let arch_shadow_hash = (
        open --raw /etc/shadow
        | lines 
        | split column ":" name hash rest 
        | where name == $target_user 
        | get -i 0.hash
    )

    if not ($arch_shadow_hash | is-empty) and ($arch_shadow_hash != "!") and ($arch_shadow_hash != "*") {
        print $"(ansi green)Syncing password hash to Debian container...(ansi reset)"
        in-chroot /usr/sbin/usermod -p $arch_shadow_hash $target_user
    } else {
        $"($target_user):debian\n" | in-chroot /usr/sbin/chpasswd
        print $"(ansi yellow)Warning: Password sync failed. Default password set to 'debian'.(ansi reset)"
    }

    print $"(ansi green)Enabling systemd services...(ansi reset)"
    ^systemctl enable machines.target
    ^systemctl enable systemd-nspawn@debian.service

    print $"(ansi green)Debian container setup completed successfully!(ansi reset)"
}
