#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# xwc_p_fix.sh - Linux fixes for the HONOR MagicBook Pro 16 (2026), DMI product XWC-P.
# Tested on Omarchy (Arch, mkinitcpio, Limine). GRUB is supported as a fallback.
#
# Fixes (choose interactively):
#   1) keyboard   - kernel parameter i8042.dumbkbd=1 (internal keyboard on the i8042 port)
#   2) touchpad   - ACPI SSDT override, loaded by the mkinitcpio acpi_override hook
#   3) brightness - HID-BPF filter: touchpad left-edge slide -> brightness up/down
#
# Usage:
#   sudo ./xwc_p_fix.sh              interactive menu
#   sudo ./xwc_p_fix.sh 1 3          apply fixes 1 and 3 (asks before changing anything)
#   ./xwc_p_fix.sh --status          show what is applied (no root needed)
#   ./xwc_p_fix.sh --dry-run [1 2 3] show what would change, change nothing
#   ./xwc_p_fix.sh --help
#
# Sources are cloned at pinned commits and checked by SHA-256 before use:
#   SSDT override  https://github.com/phreer/xwc-p-touchpad-ssdt-fix
#   HID-BPF filter https://github.com/umr-xiaomai/Honor-MagicBookPro16-2026-Driver-Linux
#   HID-BPF headers https://gitlab.freedesktop.org/libevdev/udev-hid-bpf
set -euo pipefail

# --- pinned upstream sources (repo commit file sha256) ---------------------------
SSDT_REPO="https://github.com/phreer/xwc-p-touchpad-ssdt-fix.git"
SSDT_COMMIT="ce1fee19e0f14de39353b39075578bbaf19a459b"
SSDT_FILE="ssdt-touchpad.aml"
SSDT_SHA256="31ba474a01d0a5c8eb61db1fb0a509b5dbf4123f7f99755ae5f5ae45bbb83163"

BPF_REPO="https://github.com/umr-xiaomai/Honor-MagicBookPro16-2026-Driver-Linux.git"
BPF_COMMIT="2c88772a751ddecef92327cd8fa5cccd268030d4"
BPF_FILE="touchBar/honor-tops0102-edge.bpf.c"
BPF_SHA256="22ef0af5262e6b188a4201469de8b5c69026cc1be51d68fc6db8cf9d37181c16"

UHB_REPO="https://gitlab.freedesktop.org/libevdev/udev-hid-bpf.git"
UHB_COMMIT="bbaad639d4b2efe2a909e8b7c594b91e87704ab8"
UHB_INC="src/bpf"

# --- fix 1: keyboard -------------------------------------------------------------
KBD_PARAM="i8042.dumbkbd=1"

# --- fix 2: touchpad SSDT --------------------------------------------------------
SSDT_DST="/etc/initcpio/acpi_override/SSDT-I2CDEVC.aml"
SSDT_HOOK_CONF="/etc/mkinitcpio.conf.d/zzz-honor-touchpad.conf"

# --- fix 3: left-edge brightness -------------------------------------------------
BPF_NAME="honor-tops0102-edge.bpf.o"
BPF_DST="/etc/udev-hid-bpf/$BPF_NAME"
BPF_RULE="/etc/udev/rules.d/99-hid-bpf-honor-tops0102-edge.rules"
TOUCHPAD_GLOB="/sys/bus/hid/devices/0018:27C6:0F9A.*"

DRY_RUN=0
NEED_INITRAMFS=0
NEED_BOOTCFG=0
NEED_REBOOT=0
TMPDIR_BUILD=""

ensure_workdir() {
    [[ -n "$TMPDIR_BUILD" ]] || TMPDIR_BUILD="$(mktemp -d)"
}

# fetch NAME REPO COMMIT - shallow-clone REPO at exactly COMMIT into the work dir
fetch() {
    local name="$1" repo="$2" commit="$3" dir
    ensure_workdir
    dir="$TMPDIR_BUILD/$name"
    [[ -d "$dir/.git" ]] && return 0
    command -v git >/dev/null 2>&1 || die "git not found (sudo pacman -S git)"
    info "clone $repo @ ${commit:0:12}"
    git init -q "$dir"
    git -C "$dir" fetch -q --depth 1 "$repo" "$commit" || die "could not fetch $repo at $commit"
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
}

# verify FILE SHA256
verify() {
    local got
    got="$(sha256sum "$1" | cut -d' ' -f1)"
    [[ "$got" == "$2" ]] || die "checksum mismatch for $1 (got $got, expected $2)"
}

c_bold=$'\e[1m'; c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_off=$'\e[0m'
[[ -t 1 ]] || { c_bold=""; c_red=""; c_grn=""; c_yel=""; c_off=""; }

say()  { printf '%s==>%s %s\n' "$c_bold" "$c_off" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%sWARNING:%s %s\n' "$c_yel" "$c_off" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

# run CMD...  - execute, or only print it in dry-run mode
run() {
    if (( DRY_RUN )); then
        printf '    [dry-run] %s\n' "$*"
    else
        printf '    + %s\n' "$*"
        "$@"
    fi
}

confirm() {
    local ans
    read -r -p "$1 [y/N] " ans || return 1
    [[ "$ans" == [yY] || "$ans" == [yY][eE][sS] ]]
}

backup() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    run cp -a -- "$f" "$f.bak-$(date +%Y%m%d-%H%M%S)"
}

cleanup() { [[ -n "$TMPDIR_BUILD" && -d "$TMPDIR_BUILD" ]] && rm -rf -- "$TMPDIR_BUILD"; return 0; }
trap cleanup EXIT

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

# --- environment detection -------------------------------------------------------

boot_tool() {
    if [[ -f /etc/default/limine ]] && command -v limine-update >/dev/null 2>&1; then
        echo limine
    elif [[ -f /etc/default/grub ]] && command -v grub-mkconfig >/dev/null 2>&1; then
        echo grub
    else
        echo unknown
    fi
}

check_machine() {
    local vendor product bios
    vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
    product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
    bios="$(cat /sys/class/dmi/id/bios_version 2>/dev/null || true)"
    info "machine: vendor=${vendor:-?} product=${product:-?} bios=${bios:-?} kernel=$(uname -r) boot=$(boot_tool)"
    if [[ "$vendor" != "HONOR" || "$product" != XWC-P* ]]; then
        warn "This is not an HONOR XWC-P. These fixes are for that model only."
        (( DRY_RUN )) || confirm "Continue anyway?" || exit 1
    fi
}

touchpad_dev() {
    local d
    for d in $TOUCHPAD_GLOB; do
        [[ -e "$d" ]] && { echo "$d"; return 0; }
    done
    return 1
}

# --- status checks ---------------------------------------------------------------

kbd_in_config() {
    case "$(boot_tool)" in
        limine) grep -Eq '^[[:space:]]*KERNEL_CMDLINE\[[^]]*\]\+?=.*i8042\.dumbkbd=1' /etc/default/limine ;;
        grub)   grep -Eq '^[[:space:]]*GRUB_CMDLINE_LINUX(_DEFAULT)?=.*i8042\.dumbkbd=1' /etc/default/grub ;;
        *)      return 1 ;;
    esac
}
kbd_active()   { grep -qw -- "$KBD_PARAM" /proc/cmdline; }

ssdt_file_ok() { [[ -f "$SSDT_DST" ]] && [[ "$(sha256sum "$SSDT_DST" | cut -d' ' -f1)" == "$SSDT_SHA256" ]]; }
ssdt_hook_ok() { grep -Eqs '^[^#]*HOOKS.*acpi_override' /etc/mkinitcpio.conf /etc/mkinitcpio.conf.d/*.conf; }

bpf_installed() { [[ -f "$BPF_DST" && -f "$BPF_RULE" ]]; }

yn() { if "$@" >/dev/null 2>&1; then printf '%syes%s' "$c_grn" "$c_off"; else printf '%sno%s' "$c_red" "$c_off"; fi; }

state_label() {
    case "$1" in
        1) kbd_in_config && echo "applied" || echo "not applied" ;;
        2) { ssdt_file_ok && ssdt_hook_ok; } && echo "applied" || echo "not applied" ;;
        3) bpf_installed && echo "applied" || echo "not applied" ;;
    esac
}

show_status() {
    say "Status"
    printf '  1) keyboard    in boot config: %s   active this boot: %s\n' "$(yn kbd_in_config)" "$(yn kbd_active)"
    printf '  2) touchpad    override file: %s   acpi_override hook: %s   touchpad present: %s\n' \
        "$(yn ssdt_file_ok)" "$(yn ssdt_hook_ok)" "$(yn touchpad_dev)"
    printf '  3) brightness  filter + udev rule installed: %s\n' "$(yn bpf_installed)"
    if [[ -r /sys/class/backlight/intel_backlight/brightness ]]; then
        info "backlight: $(cat /sys/class/backlight/intel_backlight/brightness)/$(cat /sys/class/backlight/intel_backlight/max_brightness)"
    fi
}

# --- fix 1: keyboard -------------------------------------------------------------

apply_keyboard() {
    say "Fix 1: keyboard ($KBD_PARAM)"
    if kbd_in_config; then
        info "already in the boot config, nothing to do"
        return 0
    fi
    case "$(boot_tool)" in
        limine)
            info "append to /etc/default/limine: KERNEL_CMDLINE[default]+=\" $KBD_PARAM\""
            backup /etc/default/limine
            if (( ! DRY_RUN )); then
                printf '\n# HONOR XWC-P internal keyboard (added by xwc_p_fix.sh)\nKERNEL_CMDLINE[default]+=" %s"\n' \
                    "$KBD_PARAM" >> /etc/default/limine
                kbd_in_config || die "edit of /etc/default/limine did not take effect"
            fi
            ;;
        grub)
            info "append $KBD_PARAM to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub"
            grep -q '^GRUB_CMDLINE_LINUX_DEFAULT="' /etc/default/grub \
                || die "GRUB_CMDLINE_LINUX_DEFAULT=\"...\" not found in /etc/default/grub; add $KBD_PARAM by hand"
            backup /etc/default/grub
            run sed -i -E "s/^(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*)\"/\\1 $KBD_PARAM\"/" /etc/default/grub
            (( DRY_RUN )) || kbd_in_config || die "edit of /etc/default/grub did not take effect"
            ;;
        *)
            die "unknown bootloader. Add '$KBD_PARAM' to your kernel command line by hand."
            ;;
    esac
    NEED_BOOTCFG=1
    NEED_REBOOT=1
}

# --- fix 2: touchpad SSDT --------------------------------------------------------

apply_ssdt() {
    say "Fix 2: touchpad ACPI SSDT override"
    command -v mkinitcpio >/dev/null 2>&1 \
        || die "mkinitcpio not found. This fix uses the mkinitcpio acpi_override hook (dracut is not supported)."
    [[ -f /usr/lib/initcpio/install/acpi_override ]] \
        || die "mkinitcpio has no acpi_override hook (/usr/lib/initcpio/install/acpi_override). Update mkinitcpio."

    local bios
    bios="$(cat /sys/class/dmi/id/bios_version 2>/dev/null || true)"
    [[ "$bios" == "1.10" ]] || warn "BIOS is '${bios:-?}'. This override was tested on BIOS 1.10 (upstream: 1.07-1.09)."

    local changed=0 src
    if ssdt_file_ok; then
        info "override file already installed: $SSDT_DST"
    else
        fetch ssdt "$SSDT_REPO" "$SSDT_COMMIT"
        src="$TMPDIR_BUILD/ssdt/$SSDT_FILE"
        verify "$src" "$SSDT_SHA256"
        run install -D -m 0644 "$src" "$SSDT_DST"
        changed=1
    fi
    if ssdt_hook_ok; then
        info "acpi_override hook already enabled"
    else
        info "write $SSDT_HOOK_CONF: HOOKS+=(acpi_override)"
        if (( ! DRY_RUN )); then
            install -d -m 0755 "$(dirname "$SSDT_HOOK_CONF")"
            printf 'HOOKS+=(acpi_override)\n' > "$SSDT_HOOK_CONF"
            chmod 0644 "$SSDT_HOOK_CONF"
        fi
        changed=1
    fi
    if (( changed )); then
        NEED_INITRAMFS=1
        NEED_REBOOT=1
    fi
}

# --- fix 3: left-edge brightness -------------------------------------------------

# build_bpf - compile the filter into $TMPDIR_BUILD/$BPF_NAME and check its device IDs
build_bpf() {
    local out kbuild src kdir
    command -v clang >/dev/null 2>&1        || die "clang not found (sudo pacman -S clang)"
    command -v udev-hid-bpf >/dev/null 2>&1 || die "udev-hid-bpf not found (sudo pacman -S udev-hid-bpf)"
    [[ -f /usr/include/bpf/bpf_helpers.h ]] || die "libbpf headers not found (sudo pacman -S libbpf)"

    fetch filter "$BPF_REPO" "$BPF_COMMIT"
    fetch udev-hid-bpf "$UHB_REPO" "$UHB_COMMIT"
    src="$TMPDIR_BUILD/filter/$BPF_FILE"
    verify "$src" "$BPF_SHA256"

    # Prefer the running kernel's vmlinux.h; fall back to the one shipped with udev-hid-bpf.
    kbuild="/usr/lib/modules/$(uname -r)/build"
    kdir="$TMPDIR_BUILD/kernel"
    mkdir -p "$kdir"
    out="$TMPDIR_BUILD/$BPF_NAME"
    if [[ -f "$kbuild/vmlinux.h" ]]; then
        cp "$kbuild/vmlinux.h" "$kdir/vmlinux.h"
        info "vmlinux.h: running kernel $(uname -r)"
    else
        info "vmlinux.h: udev-hid-bpf copy (no kernel headers installed)"
    fi

    info "compile $BPF_FILE"
    clang -O2 -g -Wall -Wno-missing-declarations -target bpf -D__TARGET_ARCH_x86 \
        -I"$kdir" -I"$TMPDIR_BUILD/udev-hid-bpf/$UHB_INC" -I/usr/include \
        -c "$src" -o "$out" 2> "$TMPDIR_BUILD/clang.log" \
        || { cat "$TMPDIR_BUILD/clang.log" >&2; die "compile failed"; }

    local ids
    ids="$(udev-hid-bpf inspect "$out")"
    grep -q '"vid": "0x27C6"' <<<"$ids" && grep -q '"pid": "0x0F9A"' <<<"$ids" \
        || die "built object does not target 27C6:0F9A"
    info "built and checked: targets 27C6:0F9A"
}

apply_brightness() {
    say "Fix 3: left-edge brightness (HID-BPF)"
    local obj dev
    build_bpf
    obj="$TMPDIR_BUILD/$BPF_NAME"

    if (( DRY_RUN )); then
        udev-hid-bpf install --dry-run --force "$obj" | sed 's/^/    /'
        return 0
    fi

    run udev-hid-bpf install --force "$obj"
    run udevadm control --reload
    if dev="$(touchpad_dev)"; then
        run udev-hid-bpf add --replace "$dev" "$BPF_DST"
        info "loaded now on $(basename "$dev"). Slide up/down on the left edge to test."
    else
        warn "touchpad 27C6:0F9A is not present. Apply fix 2 and reboot; the udev rule loads the filter at boot."
    fi
}

# --- regenerate boot files -------------------------------------------------------

finish() {
    (( NEED_INITRAMFS || NEED_BOOTCFG )) || return 0
    say "Regenerate boot files"
    case "$(boot_tool)" in
        limine)
            # limine-update rebuilds the initramfs and the Limine entries (with the cmdline).
            run limine-update
            ;;
        grub)
            (( NEED_INITRAMFS )) && run mkinitcpio -P
            (( NEED_BOOTCFG ))   && run grub-mkconfig -o /boot/grub/grub.cfg
            ;;
        *)
            (( NEED_INITRAMFS )) && run mkinitcpio -P
            (( NEED_BOOTCFG ))   && warn "update your bootloader config by hand"
            ;;
    esac
}

# --- main ------------------------------------------------------------------------

main() {
    local sel=() status_only=0 arg
    for arg in "$@"; do
        case "$arg" in
            -h|--help)  usage; exit 0 ;;
            --status)   status_only=1 ;;
            --dry-run)  DRY_RUN=1 ;;
            1|2|3)      sel+=("$arg") ;;
            *)          die "unknown argument: $arg (see --help)" ;;
        esac
    done

    if (( status_only )); then
        show_status
        exit 0
    fi
    if (( ! DRY_RUN && EUID != 0 )); then
        die "run as root: sudo $0  (or use --status / --dry-run without root)"
    fi

    check_machine
    show_status
    echo

    if (( ${#sel[@]} == 0 )); then
        echo "Which fixes do you want to apply?"
        echo "  1) Keyboard               ($(state_label 1))"
        echo "  2) Touchpad SSDT override ($(state_label 2))"
        echo "  3) Left-edge brightness   ($(state_label 3))"
        echo "  a) all     q) quit"
        local reply
        read -r -p "Choice (for example: 1 3): " reply || exit 1
        case "$reply" in
            q|Q|"") echo "Nothing changed."; exit 0 ;;
            a|A)    sel=(1 2 3) ;;
            *)      read -r -a sel <<<"${reply//,/ }" ;;
        esac
    fi

    local s ordered=()
    for s in 1 2 3; do
        [[ " ${sel[*]} " == *" $s "* ]] && ordered+=("$s")
    done
    for s in "${sel[@]}"; do
        [[ "$s" == [123] ]] || die "invalid choice: $s"
    done
    (( ${#ordered[@]} )) || { echo "Nothing selected."; exit 0; }

    echo "Selected: ${ordered[*]}"
    if (( ! DRY_RUN )); then
        confirm "Apply these fixes now?" || { echo "Nothing changed."; exit 0; }
    fi

    for s in "${ordered[@]}"; do
        case "$s" in
            1) apply_keyboard ;;
            2) apply_ssdt ;;
            3) apply_brightness ;;
        esac
    done
    finish

    echo
    if (( DRY_RUN )); then
        say "Dry run finished. Nothing was changed."
    elif (( NEED_REBOOT )); then
        say "Done. Reboot to activate the keyboard and/or touchpad fix."
    else
        say "Done."
    fi
}

main "$@"
