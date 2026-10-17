# Honor MagicBook Pro 16 (2026) on Linux

`xwc_p_fix.sh` is one interactive script. It applies three fixes on the **HONOR MagicBook Pro 16 (2026)**: DMI product `XWC-P`, Goodix touchpad `27C6:0F9A` (ACPI `TOPS0102`).

Tested on Omarchy (Arch, mkinitcpio, Limine), BIOS 1.10, kernel 7.2.8. GRUB support is included but untested.

## Fixes

| # | Fix | What the script does | Takes effect |
|---|---|---|---|
| 1 | Keyboard | Adds `i8042.dumbkbd=1` to the kernel command line. The `XWC-P` is not in mainline's `atkbd` quirk table. The Caps Lock LED stays off. | after reboot |
| 2 | Touchpad (SSDT) | The factory `I2C_DEVT` table fails to load (`AE_AML_INTERNAL`), so the touchpad never appears. The script installs phreer's fixed SSDT as `/etc/initcpio/acpi_override/SSDT-I2CDEVC.aml` and enables mkinitcpio's `acpi_override` hook. | after reboot |
| 3 | Left-edge brightness | Builds the HID-BPF filter `honor-tops0102-edge.bpf.c` and installs it with `udev-hid-bpf`. Sliding up or down on the left edge then changes the screen brightness. | immediately |

This repository contains only the script. The script clones its sources at pinned commits and checks each file's SHA-256 before using it:

- SSDT override: [phreer/xwc-p-touchpad-ssdt-fix](https://github.com/phreer/xwc-p-touchpad-ssdt-fix)
- HID-BPF filter: [umr-xiaomai/Honor-MagicBookPro16-2026-Driver-Linux](https://github.com/umr-xiaomai/Honor-MagicBookPro16-2026-Driver-Linux)
- HID-BPF headers: [libevdev/udev-hid-bpf](https://gitlab.freedesktop.org/libevdev/udev-hid-bpf)

## Requirements

```bash
sudo pacman -S --needed git clang libbpf udev-hid-bpf
```

Fix 3 uses your kernel headers (for example `linux-omarchy-headers`) if they are installed. If not, it uses the `vmlinux.h` that ships with udev-hid-bpf.

## Usage

```bash
git clone https://github.com/shilai-li/honor-magicbook-pro-16-2026-linux.git
cd honor-magicbook-pro-16-2026-linux

./xwc_p_fix.sh --status          # what is applied (no root)
./xwc_p_fix.sh --dry-run 1 2 3   # show what would change, change nothing (no root)
sudo ./xwc_p_fix.sh              # interactive menu: 1, 2, 3, or a (all)
sudo ./xwc_p_fix.sh 2 3          # apply the chosen fixes (still asks to confirm)
```

The script:

- checks that the machine is an HONOR `XWC-P`, and asks before continuing if it is not
- skips fixes that are already applied, so you can run it again safely
- backs up `/etc/default/limine` (or `/etc/default/grub`) before editing it
- runs `limine-update` (or `mkinitcpio -P` and `grub-mkconfig`) only when fix 1 or 2 changed something

Reboot after fix 1 or 2.

## Verify

```bash
./xwc_p_fix.sh --status
grep -o i8042.dumbkbd=1 /proc/cmdline                  # fix 1
ls /sys/bus/hid/devices/ | grep 27C6:0F9A              # fix 2
cat /sys/class/backlight/intel_backlight/brightness    # fix 3: slide the left edge, then read again
```

Run `udev-hid-bpf list-loaded` as root. Without root it prints an empty list even when the filter is loaded.

## Undo

```bash
# fix 1: delete the "i8042.dumbkbd=1" lines the script added to /etc/default/limine, then
sudo limine-update

# fix 2
sudo rm /etc/initcpio/acpi_override/SSDT-I2CDEVC.aml /etc/mkinitcpio.conf.d/zzz-honor-touchpad.conf
sudo limine-update

# fix 3
sudo udev-hid-bpf remove /sys/bus/hid/devices/0018:27C6:0F9A.*
sudo rm /etc/udev-hid-bpf/honor-tops0102-edge.bpf.o /etc/udev/rules.d/99-hid-bpf-honor-tops0102-edge.rules
sudo udevadm control --reload
```

## Not covered

- Top-left and top-right corner taps, and knuckle taps.
- Honor hotkeys through `huawei-wmi` (camera toggle, touchpad lock, performance mode, keyboard backlight).
- Right-edge volume slide. It goes through the embedded controller, not HID, and is not tested here.

## License

The script is MIT. The sources it downloads keep their own licenses: the SSDT override is MIT (phreer), and the HID-BPF filter and headers are GPL-2.0-only.
