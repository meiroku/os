#!/usr/bin/env nu

# ==========================================
# Environment & Constants
# ==========================================

def machine_name [] {
    $env.MACHINE_NAME? | default "debian"
}

def container_root [] {
    $env.CONTAINER_ROOT? | default $"/var/lib/machines/(machine_name)"
}

def desktop_dir_candidates [] {
    [ "usr/share/applications", "usr/local/share/applications" ]
}

# ==========================================
# Utilities
# ==========================================

def usage [] {
    let m_name = (machine_name)
    let script_name = ($env.CURRENT_FILE? | default "nspawn-apt" | path basename)
    print $"Usage:
  ($script_name) <command> [args...]    : Run apt inside the '($m_name)' container
  ($script_name) link <app_name>        : Link a GUI app's .desktop file to the host
  ($script_name) unlink <app_name>      : Remove a linked app's .desktop and wrapper from the host

Environment:
  TARGET_UID=1000            : UID used inside the container for GUI apps
  TARGET_USER=username       : Host user who receives linked .desktop files
  MACHINE_NAME=debian        : systemd-nspawn machine name
  CONTAINER_ROOT=/var/...    : Root path of the machine

Note for GUI apps:
  To run GUI apps, ensure your container allows access to X11/Wayland sockets.
  E.g., add to your ($m_name).nspawn file:
    BindReadOnly=/tmp/.X11-unix
    Bind=/run/user/1000"
}

def resolve_target_user [] {
    if ($env.TARGET_USER? | default "") != "" {
        return ($env.TARGET_USER | str trim)
    }
    if ($env.SUDO_USER? | default "") != "" and $env.SUDO_USER != "root" {
        return ($env.SUDO_USER | str trim)
    }
    ^whoami | str trim
}

def resolve_target_home [user: string] {
    let passwd_entry = (^getent passwd $user | str trim)
    if ($passwd_entry | is-empty) {
        print -e $"Error: User '($user)' not found."
        exit 1
    }
    let home = ($passwd_entry | split row ":" | get 5)
    if ($home | is-empty) {
        print -e $"Error: Could not resolve home directory for '($user)'."
        exit 1
    }
    $home
}

def resolve_target_uid [user: string] {
    if ($env.TARGET_UID? | default "") != "" {
        return ($env.TARGET_UID | into int)
    }
    ^id -u $user | into int
}

def resolve_target_gid [user: string] {
    ^id -g $user | into int
}

def sanitize_slug [text: string] {
    let s = ($text | str lowercase
                   | str replace --all ' ' '-'
                   | str replace --all '/' '-'
                   | str replace --regex --all '[^a-z0-9._-]+' '-'
                   | str replace --regex --all '-+' '-'
                   | str trim -c '-')
    if ($s | is-empty) { "app" } else { $s }
}

def first_desktop_value [text: string, key: string] {
    let prefix = $"($key)="
    for line in ($text | lines) {
        if ($line | str starts-with $prefix) {
            return ($line | str substring ($prefix | str length)..)
        }
    }
    ""
}

def ensure_dir_chown [path: string, uid: int, gid: int] {
    if not ($path | path exists) {
        mut paths_to_create = []
        mut current = ($path | path expand)
        
        while not ($current | path exists) {
            $paths_to_create = ($paths_to_create | append $current)
            $current = ($current | path dirname)
        }
        
        for p in ($paths_to_create | reverse) {
            mkdir $p
            ^chown $"($uid):($gid)" $p
        }
    }
}

def insert_after_desktop_entry [target_lines: list<string>, new_line: string] {
    mut inserted = false
    mut result = []
    for line in $target_lines {
        $result = ($result | append $line)
        if not $inserted and ($line | str trim) == "[Desktop Entry]" {
            $result = ($result | append $new_line)
            $inserted = true
        }
    }
    if not $inserted {
        $result = ($result | prepend $new_line)
    }
    $result
}

# ==========================================
# Core Logic
# ==========================================

def iter_desktop_files [] {
    mut found = []
    for base in (desktop_dir_candidates) {
        let dir = ((container_root) | path join $base)
        if ($dir | path exists) {
            let files = (glob ($dir | path join "**" "*.desktop"))
            $found = ($found | append ...$files)
        }
    }
    $found
}

def find_desktop_file [app_name: string] {
    let needle = ($app_name | str lowercase)
    mut exact_matches = []
    mut partial_matches = []

    for path in (iter_desktop_files) {
        let stem = ($path | path parse | get stem | str lowercase)
        let name = ($path | path basename | str lowercase)
        let rel = ($path | str replace (container_root) "" | str lowercase)

        if $stem == $needle or $name == $"($needle).desktop" {
            $exact_matches = ($exact_matches | append $path)
            continue
        }

        if ($needle in $stem) or ($needle in $name) or ($needle in $rel) {
            $partial_matches = ($partial_matches | append $path)
            continue
        }
    }

    if ($exact_matches | is-not-empty) {
        return ($exact_matches | sort | first)
    }
    if ($partial_matches | is-not-empty) {
        return ($partial_matches | sort | first)
    }
    null
}

def build_launcher_script [
    m_name: string
    target_uid: int
    desktop_file: string
    display_name: string
    orig_icon: string
    orig_exec: string
] {
    let m_repr = ($m_name | to json | str trim)
    let uid_repr = ($target_uid | into string)
    let df_repr = ($desktop_file | to json | str trim)
    let dn_repr = ($display_name | to json | str trim)
    let oi_repr = ($orig_icon | to json | str trim)
    let oe_repr = ($orig_exec | to json | str trim)

    let head = $"#!/usr/bin/env nu

const MACHINE = ($m_repr)
const TARGET_UID = ($uid_repr)
const DESKTOP_FILE = ($df_repr)
const DISPLAY_NAME = ($dn_repr)
const ORIG_ICON = ($oi_repr)
const ORIG_EXEC = ($oe_repr)
"

    let body = r#'
def parse_exec [exec_str: string] {
    mut tokens = []
    mut current_token = ""
    mut in_double = false
    mut in_single = false

    for c in ($exec_str | split chars) {
        if $c == '"' and not $in_single {
            $in_double = (not $in_double)
        } else if $c == "'" and not $in_double {
            $in_single = (not $in_single)
        } else if $c in [" ", "\t"] and not $in_double and not $in_single {
            if ($current_token | is-not-empty) {
                $tokens = ($tokens | append $current_token)
                $current_token = ""
            }
        } else {
            $current_token = $"($current_token)($c)"
        }
    }
    if ($current_token | is-not-empty) {
        $tokens = ($tokens | append $current_token)
    }
    $tokens
}

def expand_exec [tokens: list<string>, args: list<string>] {
    mut out = []
    for token in $tokens {
        if $token == "%%" {
            $out = ($out | append "%")
        } else if $token == "%c" {
            $out = ($out | append $DISPLAY_NAME)
        } else if $token == "%k" {
            $out = ($out | append $DESKTOP_FILE)
        } else if $token == "%i" {
            if ($ORIG_ICON | is-not-empty) {
                $out = ($out | append ...["--icon", $ORIG_ICON])
            }
        } else if $token in ["%f", "%u"] {
            if ($args | is-not-empty) {
                $out = ($out | append ($args | first))
            }
        } else if $token in ["%F", "%U"] {
            if ($args | is-not-empty) {
                $out = ($out | append ...$args)
            }
        } else if ("%" in $token) {
            mut repl = ($token | str replace --all "%%" "%"
                               | str replace --all "%c" $DISPLAY_NAME
                               | str replace --all "%k" $DESKTOP_FILE)

            let has_single = ("%f" in $repl) or ("%u" in $repl)
            let has_multi = ("%F" in $repl) or ("%U" in $repl)

            if $has_single {
                let val = if ($args | is-empty) { "" } else { $args | first }
                $repl = ($repl | str replace --all "%f" $val | str replace --all "%u" $val)
            }
            if $has_multi {
                let val = if ($args | is-empty) { "" } else { $args | first }
                $repl = ($repl | str replace --all "%F" $val | str replace --all "%U" $val)
            }

            $out = ($out | append $repl)

            if $has_multi and ($args | length) > 1 {
                $out = ($out | append ...($args | skip 1))
            }
        } else {
            $out = ($out | append $token)
        }
    }
    $out
}

def main [...args: string] {
    let tokens = (parse_exec $ORIG_EXEC)
    let final_cmd = (expand_exec $tokens $args)

    if ($final_cmd | is-empty) {
        print -e "Error: command expansion resulted in an empty command."
        exit 1
    }

    let wayland = $env.WAYLAND_DISPLAY? | default ""
    let display = $env.DISPLAY? | default ""
    let xauthority = $env.XAUTHORITY? | default ""

    mut cmd = []

    let current_uid = (^id -u | into int)
    if $current_uid != 0 {
        $cmd = ($cmd | append "sudo")
    }

    $cmd = ($cmd | append ...[
        "systemd-run",
        "-M", $MACHINE,
        "--quiet",
        "--pipe",
        "--wait",
        $"--uid=($TARGET_UID)",
        $"--setenv=XDG_RUNTIME_DIR=/run/user/($TARGET_UID)"
    ])
    
    if ($wayland | is-not-empty) {
        $cmd = ($cmd | append $"--setenv=WAYLAND_DISPLAY=($wayland)")
    }
    if ($display | is-not-empty) {
        $cmd = ($cmd | append $"--setenv=DISPLAY=($display)")
    }
    if ($xauthority | is-not-empty) {
        $cmd = ($cmd | append $"--setenv=XAUTHORITY=($xauthority)")
    }

    $cmd = ($cmd | append ...["--", "/usr/bin/env"] | append ...$final_cmd)

    let exe = ($cmd | first)
    let exec_args = ($cmd | skip 1)
    
    exec $exe ...$exec_args
}
'#
    $head + $body
}

def rewrite_desktop_file [
    desktop_path: string
    wrapper_path: string
    m_name: string
    c_root: string
    display_name: string
] {
    let text = (open --raw $desktop_path)
    let lines = ($text | lines)

    mut out = []
    mut seen_name = false
    mut seen_exec = false
    mut seen_tryexec = false

    let quoted_wrapper = $"\"($wrapper_path)\""

    for line in $lines {
        if ($line | str starts-with "Name=") or ($line | str starts-with "Name[") {
            if not $seen_name {
                let cap_machine = ($m_name | str capitalize)
                $out = ($out | append $"Name=[($cap_machine)] ($display_name)\n")
                $seen_name = true
            }
            continue
        }

        if ($line | str starts-with "Exec=") {
            $out = ($out | append $"Exec=($quoted_wrapper) %U\n")
            $seen_exec = true
            continue
        }

        if ($line | str starts-with "TryExec=") {
            $out = ($out | append $"TryExec=($quoted_wrapper)\n")
            $seen_tryexec = true
            continue
        }

        if ($line | str starts-with "Icon=") {
            let icon_value = ($line | str substring 5..)
            if ($icon_value | str starts-with "/") {
                $out = ($out | append $"Icon=($c_root)($icon_value)\n")
            } else {
                $out = ($out | append $"($line)\n")
            }
            continue
        }

        $out = ($out | append $"($line)\n")
    }

    if not $seen_name {
        let cap_machine = ($m_name | str capitalize)
        $out = (insert_after_desktop_entry $out $"Name=[($cap_machine)] ($display_name)\n")
    }
    if not $seen_exec {
        $out = (insert_after_desktop_entry $out $"Exec=($quoted_wrapper) %U\n")
    }
    if not $seen_tryexec {
        $out = (insert_after_desktop_entry $out $"TryExec=($quoted_wrapper)\n")
    }

    $out | str join "" | save -f $desktop_path
}

def link_app [app_name: string] {
    let target_user = (resolve_target_user)
    let target_home = (resolve_target_home $target_user)
    let target_uid = (resolve_target_uid $target_user)
    let target_gid = (resolve_target_gid $target_user)

    if not ($target_home | path exists) {
        print -e $"Error: Home directory does not exist: ($target_home)"
        exit 1
    }

    let desktop_dir = ($target_home | path join ".local" "share" "applications")
    let wrapper_dir = ($target_home | path join ".local" "bin")
    
    ensure_dir_chown $desktop_dir $target_uid $target_gid
    ensure_dir_chown $wrapper_dir $target_uid $target_gid

    let desktop_file = (find_desktop_file $app_name)
    if ($desktop_file | is-empty) {
        print -e $"Error: No .desktop file found for '($app_name)' in the container."
        exit 1
    }

    let file_name = ($desktop_file | path basename)
    let base_name = ($desktop_file | path parse | get stem)
    let slug = (sanitize_slug $base_name)

    let output_desktop = ($desktop_dir | path join $"(machine_name)-($file_name)")
    let wrapper_file = ($wrapper_dir | path join $"(machine_name)-($slug)-launch.nu")

    let src_text = (open --raw $desktop_file)
    mut orig_name = (first_desktop_value $src_text "Name")
    if ($orig_name | is-empty) {
        $orig_name = $app_name
    }
    
    let orig_icon = (first_desktop_value $src_text "Icon")
    let orig_exec = (first_desktop_value $src_text "Exec")

    if ($orig_exec | is-empty) {
        print -e $"Error: Found desktop file, but no Exec= line was present: ($desktop_file)"
        exit 1
    }

    cp -f $desktop_file $output_desktop

    let launcher = (build_launcher_script (machine_name) $target_uid $output_desktop $orig_name $orig_icon $orig_exec)
    $launcher | save -f $wrapper_file
    ^chmod 0755 $wrapper_file

    rewrite_desktop_file $output_desktop $wrapper_file (machine_name) (container_root) $orig_name

    ^chown $"($target_uid):($target_gid)" $output_desktop
    ^chown $"($target_uid):($target_gid)" $wrapper_file

    print "Link successful:"
    print $"  Desktop : ($output_desktop)"
    print $"  Wrapper : ($wrapper_file)"

    if (which update-desktop-database | is-not-empty) {
        with-env { HOME: $target_home, USER: $target_user } {
            try { ^sudo -u $target_user -E update-desktop-database $desktop_dir out+err> /dev/null }
        }
    }
}

def unlink_app [app_name: string] {
    let target_user = (resolve_target_user)
    let target_home = (resolve_target_home $target_user)
    let desktop_dir = ($target_home | path join ".local" "share" "applications")
    let wrapper_dir = ($target_home | path join ".local" "bin")

    let m_name = (machine_name)
    let needle = ($app_name | str lowercase)

    if not ($desktop_dir | path exists) {
        print -e $"Error: Desktop directory does not exist: ($desktop_dir)"
        exit 1
    }

    # Search for linked desktop files on the host directly (ignoring container state)
    let desktop_files = (glob ($desktop_dir | path join $"($m_name)-*.desktop"))
    mut matched_desktops = []

    for f in $desktop_files {
        let name = ($f | path basename | str lowercase)
        if ($needle in $name) {
            $matched_desktops = ($matched_desktops | append $f)
        }
    }

    if ($matched_desktops | is-empty) {
        print -e $"Error: No linked app matching '($app_name)' found for machine '($m_name)'."
        exit 1
    }

    for df in $matched_desktops {
        let base_name = ($df | path parse | get stem | str replace $"^($m_name)-" "")
        let slug = (sanitize_slug $base_name)
        
        # Look for both the new .nu wrapper and the old .py wrapper for safe cleanup
        let py_wrapper = ($wrapper_dir | path join $"($m_name)-($slug)-launch.py")
        let nu_wrapper = ($wrapper_dir | path join $"($m_name)-($slug)-launch.nu")

        print $"Removing Desktop file: ($df)"
        rm -f $df

        if ($py_wrapper | path exists) {
            print $"Removing Wrapper file: ($py_wrapper)"
            rm -f $py_wrapper
        }
        if ($nu_wrapper | path exists) {
            print $"Removing Wrapper file: ($nu_wrapper)"
            rm -f $nu_wrapper
        }
    }

    print "Unlink successful."

    if (which update-desktop-database | is-not-empty) {
        with-env { HOME: $target_home, USER: $target_user } {
            try { ^sudo -u $target_user -E update-desktop-database $desktop_dir out+err> /dev/null }
        }
    }
}

def passthrough_apt [args: list<string>] {
    exec machinectl -q shell $"root@(machine_name)" /usr/bin/apt ...$args
}

# ==========================================
# Main Entrypoint
# ==========================================

def main [
    command?: string
    ...args: string
] {
    if ($command | is-empty) or $command in ["-h", "--help", "help"] {
        usage
        exit (if ($command | is-empty) { 1 } else { 0 })
    }

    if $command == "link" {
        if ($args | is-empty) {
            let script_name = ($env.CURRENT_FILE? | default "nspawn-apt" | path basename)
            print -e $"Error: Please specify an application name. Example: ($script_name) link firefox"
            exit 1
        }
        link_app ($args | first)
        return
    }

    if $command == "unlink" {
        if ($args | is-empty) {
            let script_name = ($env.CURRENT_FILE? | default "nspawn-apt" | path basename)
            print -e $"Error: Please specify an application name. Example: ($script_name) unlink firefox"
            exit 1
        }
        unlink_app ($args | first)
        return
    }

    let all_args = ([$command] | append ...$args)
    passthrough_apt $all_args
}
