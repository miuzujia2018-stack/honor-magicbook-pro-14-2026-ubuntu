#!/usr/bin/env bash
# Read-only compatibility audit for HONOR ZQC-P board M1050 on Ubuntu.
# Deliberately omits serial numbers, UUIDs, MAC addresses, enrolled finger
# names, biometric data, private keys and unfiltered logs.

set -u

section() { printf '\n== %s ==\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
kernel_log() { journalctl -k -b 0 --no-pager -o cat 2>/dev/null; }

section "Machine"
printf 'product: '; cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown
printf 'board: '; cat /sys/class/dmi/id/board_name 2>/dev/null || echo unknown
printf 'board version: '; cat /sys/class/dmi/id/board_version 2>/dev/null || echo unknown
printf 'SKU: '; cat /sys/class/dmi/id/product_sku 2>/dev/null || echo unknown
printf 'kernel: %s\n' "$(uname -r)"
have mokutil && mokutil --sb-state 2>/dev/null || true

section "Relevant kernel parameters"
for arg in xe.enable_psr xe.vbt_firmware i8042.dumbkbd; do
    value=$(tr ' ' '\n' </proc/cmdline | grep -m1 "^${arg}=" || true)
    printf '%-20s %s\n' "$arg" "${value:-absent}"
done

section "ACPI and input"
kernel_log | grep -iE 'Table Upgrade: override.*I2C_DEVT|AE_AML_INTERNAL' | tail -20
for id in FTSC1000 TOPS0102; do
    if compgen -G "/sys/bus/acpi/devices/${id}:*" >/dev/null; then
        printf '%s: present\n' "$id"
    else
        printf '%s: missing\n' "$id"
    fi
done
grep -E '^(N: Name|H: Handlers)' /proc/bus/input/devices 2>/dev/null |
    grep -A1 -E 'FTSC1000|TOPS0102|AT Translated|Huawei WMI' || true

section "Display"
if have modinfo; then
    printf 'xe module: '; modinfo -F filename xe 2>/dev/null | head -1
    printf 'xe signer: '; modinfo -F signer xe 2>/dev/null | head -1
fi
if [[ -r /var/lib/honor/xe-module.stamp ]]; then
    sed -n -E '/^(kver|wanted|patches|srcversion)=/p' /var/lib/honor/xe-module.stamp
else
    echo 'xe-module.stamp: absent'
fi
kernel_log |
    grep -iE 'CPU pipe|FIFO underrun|Requesting VBT firmware|vbt_firmware.*failed' |
    tail -30 || true

section "Fingerprint"
sensor_found=0
for dev in /sys/bus/usb/devices/*; do
    [[ -r "$dev/idVendor" && -r "$dev/idProduct" ]] || continue
    vendor=$(<"$dev/idVendor")
    product=$(<"$dev/idProduct")
    if [[ "$vendor:$product" == "27c6:6f94" ]]; then
        sensor_found=1
        printf 'Goodix 27c6:6f94: present (%s)\n' "$(basename "$dev")"
    fi
done
(( sensor_found )) || echo 'Goodix 27c6:6f94: missing'
if have dpkg-query; then
    dpkg-query -W -f='${Package}\t${Version}\t${db:Status-Abbrev}\n'         fprintd libfprint-2-2 libfprint-2-tod1 2>/dev/null || true
fi
if [[ -r /var/lib/honor/fingerprint.stamp ]]; then
    sed -n -E '/^(sensor|recipe|patches|libfprint)=/p'         /var/lib/honor/fingerprint.stamp
fi
echo 'Enrollment data intentionally not queried.'

section "Audio"
if [[ -r /proc/asound/cards ]]; then cat /proc/asound/cards
else echo '/proc/asound/cards unavailable'; fi
if have modinfo; then
    printf 'snd-sof module: '; modinfo -F filename snd-sof 2>/dev/null | head -1
fi
kernel_log |
    grep -iE 'Booted firmware version|picked fixup alc255-dell2|sof-hda-dsp' |
    tail -20 || true

section "Fan and battery"
fan_seen=0
for hwmon in /sys/class/hwmon/hwmon*; do
    [[ -r "$hwmon/name" ]] || continue
    [[ "$(<"$hwmon/name")" == honor_ec ]] || continue
    fan_seen=1
    for input in "$hwmon"/fan*_input; do
        [[ -r "$input" ]] || continue
        printf '%s: %s RPM\n' "$(basename "$input")" "$(<"$input")"
    done
done
(( fan_seen )) || echo 'honor_ec fan sensors: missing'
start=/sys/class/power_supply/BAT0/charge_control_start_threshold
end=/sys/class/power_supply/BAT0/charge_control_end_threshold
if [[ -r "$start" && -r "$end" ]]; then
    printf 'charge thresholds: %s-%s%%\n' "$(<"$start")" "$(<"$end")"
else
    echo 'charge thresholds: unavailable'
fi

section "Hotkeys and HID-BPF"
if have modinfo; then
    printf 'huawei-wmi module: '; modinfo -F filename huawei-wmi 2>/dev/null | head -1
fi
for unit in honor-hid-bpf-reapply.service honor-hotkey-actions.service             honor-battery-threshold.service; do
    echo "-- $unit"
    journalctl -b 0 --no-pager -u "$unit" -o cat 2>/dev/null | tail -8
done
journalctl -b 0 --no-pager -o cat 2>/dev/null |
    grep -E 'udev-hid-bpf.*(No such file|Failed to execute)' | tail -20 || true

section "Network, Bluetooth and camera"
for netdev in /sys/class/net/*; do
    [[ -e "$netdev/device" ]] || continue
    driver=$(basename "$(readlink -f "$netdev/device/driver" 2>/dev/null)" 2>/dev/null)
    printf '%s: driver=%s state=%s\n' "$(basename "$netdev")"         "${driver:-unknown}" "$(cat "$netdev/operstate" 2>/dev/null || echo unknown)"
done
for bt in /sys/class/bluetooth/*; do
    [[ -e "$bt" ]] && printf 'Bluetooth: %s present\n' "$(basename "$bt")"
done
for video in /sys/class/video4linux/video*; do
    [[ -r "$video/name" ]] &&
        printf '%s: %s\n' "$(basename "$video")" "$(<"$video/name")"
done

section "Automatic rebuild"
for path in /etc/kernel/postinst.d/95-honor-kernel-modules             /etc/honor-autorebuild.conf; do
    [[ -e "$path" ]] && echo "present: $path" || echo "missing: $path"
done

section "Summary warnings"
warnings=0
if kernel_log | grep -qiE 'CPU pipe|FIFO underrun'; then
    echo 'WARN: display FIFO underrun is present in this boot'
    warnings=$((warnings + 1))
else
    echo 'OK: no display FIFO underrun found'
fi
if kernel_log | grep -q 'Requesting VBT firmware.*failed'; then
    echo 'WARN: patched VBT was not loaded'
    warnings=$((warnings + 1))
else
    echo 'OK: no patched-VBT load failure found'
fi
if [[ -r /var/lib/honor/xe-module.stamp ]] &&
   grep -qE '^patches=.*(^|[[:space:]])edp-dsc([[:space:]]|$)'        /var/lib/honor/xe-module.stamp; then
    echo 'OK: xe stamp records edp-dsc'
else
    echo 'WARN: xe stamp does not record edp-dsc'
    warnings=$((warnings + 1))
fi
if journalctl -b 0 --no-pager -o cat 2>/dev/null |
   grep -qE 'udev-hid-bpf.*(No such file|Failed to execute)'; then
    echo 'WARN: HID-BPF udev action failed during this boot'
    warnings=$((warnings + 1))
else
    echo 'OK: no HID-BPF udev execution failure found'
fi
printf 'warnings: %d\n' "$warnings"
