# ZQC-P board M1050 on Ubuntu 26.04 (kernel 7.0.0-38)

This is a field report and recovery note for one HONOR MagicBook Pro 14 2026
identified as:

- product: `ZQC-P`
- board revision: `M1050`
- SKU: `C233`
- distribution: Ubuntu 26.04
- affected kernel package: `7.0.0-38-generic` (Ubuntu rebased on Linux 7.0.14)
- known-good fallback during recovery: `7.0.0-30-generic`
- Secure Boot: enabled

No serial number, filesystem UUID, MAC address, fingerprint template, MOK
private key, initramfs, VBT/ACPI dump, or locally built kernel module is included
in this repository.

## What happened

After the repository was installed and its Machine Owner Key was enrolled, the
newest kernel booted with a garbled internal display. The older kernel remained
usable through **GRUB -> Advanced options**.

The failed boots on `7.0.0-38-generic` consistently logged:

```text
xe 0000:00:02.0: [drm] *ERROR* CPU pipe A FIFO underrun
```

The same error was absent on `7.0.0-30-generic`. The `7.0.0-38` module tree
was still selecting Ubuntu's stock `xe.ko`, so MOK enrolment itself was not the
cause. The MOK is required only so Secure Boot accepts locally rebuilt modules.

## Recovery and targeted CDCLK rebuild

Keep a known-good kernel installed until the repaired kernel has completed a
successful graphical boot.

Boot the older kernel and confirm both module trees exist:

```sh
uname -r
ls -1 /lib/modules
mokutil --sb-state
```

A previous failed DSC build may leave a partially modified source tree in
`/var/tmp/honor-xe`. Preserve it outside the next build rather than reusing it:

```sh
sudo mv /var/tmp/honor-xe /var/tmp/honor-xe.failed-edp-dsc
```

Build only the CDCLK fix for the affected installed kernel:

```sh
sudo env KVER=7.0.0-38-generic FORCE=1 XE_ONLY=cdclk-ptl \
  bash /usr/local/lib/honor/repo/patch/cdclk-ptl/install.sh
```

The successful build ended with:

```text
vermagic matches: 7.0.0-38-generic SMP preempt mod_unload modversions
installed /usr/lib/modules/7.0.0-38-generic/updates/xe.ko.zst carrying: cdclk-ptl
filename: /lib/modules/7.0.0-38-generic/updates/xe.ko.zst
```

A warning about missing `llvm-objcopy` only skipped optional BTF metadata. It
did not prevent signing, vermagic validation, compression, installation, or the
initramfs rebuild.

Before rebooting, verify the target kernel will select the overlay:

```sh
modinfo -k 7.0.0-38-generic -F filename xe
modinfo -k 7.0.0-38-generic -F signer xe
modinfo -k 7.0.0-38-generic -F vermagic xe
cat /var/lib/honor/xe-module.stamp
```

Expected highlights:

```text
/lib/modules/7.0.0-38-generic/updates/xe.ko.zst
siat-ZQC-P Secure Boot Module Signature key
wanted=cdclk-ptl
patches=cdclk-ptl
```

After reboot, `7.0.0-38-generic` loaded the signed overlay and the FIFO
underruns disappeared. The older kernel continued to select its stock module
and remained an independent fallback.

## Fingerprint reader

The Goodix MOC reader `27c6:6f94` is working with the repository's patched
libfprint packages:

```text
libfprint-2-2    1:1.95.1+tod1-0ubuntu2+honor1
libfprint-2-tod1 1:1.95.1+tod1-0ubuntu2+honor1
```

The packages were held to prevent an archive update from replacing the device
ID patch. Device discovery, enrolment and verification succeeded:

```sh
fprintd-list "$USER"
fprintd-enroll -f right-index-finger
fprintd-verify
```

A successful verification returns `verify-match`. Never copy
`/var/lib/fprint/` into a backup repository.

## Verified compatibility state

| Area | Result | Evidence |
|---|---|---|
| ACPI override | working | `ACPI: Table Upgrade: override [SSDT- HONOR-I2C_DEVT]` |
| Touchscreen and touchpad | working | `FTSC1000:00` and `TOPS0102:00` enumerated |
| Boot-display corruption | fixed | signed CDCLK-only `xe.ko`; no FIFO underrun after reboot |
| PSR band workaround | enabled | `xe.enable_psr=1` |
| Fingerprint | working | Goodix MOC discovered, enrolled and verified |
| SOF audio | working at kernel level | DSP firmware booted and `sof-hda-dsp` card registered |
| Headset microphone | enabled | ALC256 selected `alc255-dell2` fixup |
| Wi-Fi | working | `iwlwifi` bound and interface up |
| Bluetooth | enumerated | `btintel_pcie`, `hci0` present |
| Webcam | enumerated | FHD Camera video nodes present |
| Fan tachometers | working | both `honor_ec` fan inputs readable |
| Battery thresholds | working | EC pair `70 90` active |
| HONOR hotkey actions | working | performance and camera keys monitored |
| Automatic kernel rebuild hook | installed | `/etc/kernel/postinst.d/95-honor-kernel-modules` |

## Known gaps on this installation

### Patched OLED VBT is not loaded

The file and initramfs-tools hook exist, but the early driver request still
fails:

```text
Requesting VBT firmware "honor/zqc-p-vbt.bin" failed (-2)
```

The panel remains usable with its firmware default brightness floor. Do not
mark this fix successful based only on the presence of the file or hook.

### eDP DSC preference is not installed

The installed `xe-module.stamp` contains only `cdclk-ptl`. The versioned
Ubuntu 7.0 DSC patch previously left a build that referenced
`intel_dp_dsc_reset_config()` where that helper was unavailable:

```text
error: implicit declaration of function 'intel_dp_dsc_reset_config'
```

The CDCLK recovery intentionally used `XE_ONLY=cdclk-ptl`. The screen is
stable, but the DSC/colour-depth improvement must not be reported as installed.

### HID-BPF startup timing

Both HID-BPF udev rules initially ran before `/usr/bin/udev-hid-bpf` was
available and logged `No such file or directory`. The mic-mute reapply service
later reported the phantom key device absent. The touchpad left-edge brightness
gesture still needs an explicit post-root reapply or a physical test.

### Status-tool false positives

On this installation, `tools/status.sh` treated the presence of any
`updates/xe.ko` as proof that the DSC fix was included. The authoritative
source is `/var/lib/honor/xe-module.stamp`.

When systemd access is blocked by a diagnostic sandbox, service checks may also
be reported as failures even though the host journal shows the units started
successfully.

## Removing only the per-kernel xe overlay

If the repaired kernel regresses, boot the known-good kernel and move the
overlay out of the module tree:

```sh
sudo mkdir -p /var/lib/honor/disabled-modules
sudo mv /lib/modules/7.0.0-38-generic/updates/xe.ko.zst \
  /var/lib/honor/disabled-modules/xe.ko.7.0.0-38-generic.zst
sudo depmod 7.0.0-38-generic
sudo update-initramfs -u -k 7.0.0-38-generic
```

The repository's `uninstall_patch.sh` remains the supported way to remove all
of its changes.

## Auditing another installation

Run the accompanying read-only script:

```sh
bash tools/audit-m1050-ubuntu.sh
```

It deliberately omits serial numbers, root/filesystem identifiers, MAC
addresses, enrolled finger names, fingerprint data and key material.
