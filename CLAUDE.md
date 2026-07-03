# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A set of Bash scripts that build and install the Intel IPU6 MIPI camera stack
**from source** on Ubuntu 24.04 (kernels 6.10+) for Alder Lake / Raptor Lake
laptops. There is no application code, no build system, and no test framework -
the "program" is `setup.sh`, and it must run as root because it compiles kernel
modules, installs system libraries, and configures systemd.

## Commands

```bash
sudo ./setup.sh --check   # hardware detection only (PCI ID, sensor, kernel) - safe, no changes
sudo ./setup.sh           # full install (~500 MB, builds from upstream, prompts y/N, then reboot)
./test.sh                 # diagnostic; no root needed; checks modules, device, plugin, HAL, service
sudo ./uninstall.sh       # remove DKMS module, libs, configs, services
```

`test.sh` is the verification harness - after any change to the install flow,
run it and read its pass/fail lines rather than re-running the full `setup.sh`.
For a runtime change, prefer applying the delta live and capturing
`journalctl -u v4l2-relayd` over a 500 MB rebuild.

## Runtime data flow

```
browser ← /dev/video99 (v4l2loopback) ← v4l2-relayd ← GStreamer(icamerasrc→videoconvert→identity)
        ← Camera HAL (libcamhal, userspace ISP) ← IPU6 PSYS (out-of-tree) + ISYS (mainline) ← sensor + IVSC
```

`v4l2-relayd` is the on-demand supervisor: it runs the GStreamer pipeline (and
thus powers the sensor + privacy LED) **only while an app holds `/dev/video99`
open**. The earlier design was an always-on `ipu6-camera-loopback.service`
running `gst-launch` 24/7; `setup.sh` now removes that unit if present.

## setup.sh structure

`detect_hardware()` reads the IPU6 PCI ID and maps it to `IPU6_VARIANT`
(`ipu6ep` / `ipu6` / `ipu6epmtl`). **This variant string threads through the
whole build** - it picks the HAL `-DIPU_VER`, and which versioned `.so` /
`.pc` files get symlinked. Then 7 sequential steps: deps → purge conflicting
`intel-ipu6-dkms` → build PSYS (DKMS, with direct-`make` fallback) → install
firmware + ISP libs → build HAL → build `icamerasrc` → configure
v4l2loopback + `v4l2-relayd`.

## Non-obvious gotchas (these caused real failures; keep them intact)

- **icamerasrc lives in `/usr/lib/gstreamer-1.0`, not the default multiarch
  plugin dir.** Anything invoking GStreamer with `icamerasrc` (the relayd
  service, manual `gst-launch` debugging) needs
  `GST_PLUGIN_PATH=/usr/lib/gstreamer-1.0:/usr/lib/x86_64-linux-gnu/gstreamer-1.0`.

- **v4l2loopback `card_label` is set in TWO files.** The `v4l2-relayd` package
  ships its own `/etc/modprobe.d/v4l2-relayd.conf`; modprobe.d loads in lexical
  order and the last `card_label` wins. `setup.sh` writes identical options to
  both `ipu6-camera.conf` and `v4l2-relayd.conf`. The relayd systemd unit
  resolves the loopback device by exact name match against `CARD_LABEL`, so a
  mismatch leaves the device path empty and relayd crash-loops.

- **`VIDEOSRC` in `/etc/default/v4l2-relayd` must END IN A REAL ELEMENT, not a
  trailing capsfilter.** relayd parses it as a bin with unlinked pads
  disallowed; a description ending in `... ! video/x-raw,format=YUY2,...` fails
  with "link has no sink". Terminate with `identity` (or any element).
  `gst-launch` tolerates the dangling caps, which makes this easy to misdiagnose.

- **HAL build needs two sets of symlinks** created in step 4: linker `.so`
  symlinks (libs ship as `libia_aiq-${VARIANT}.so.0` but the linker wants the
  unversioned `.so`) and generic pkgconfig names (`ia_imaging.pc` →
  `ia_imaging-${VARIANT}.pc`, etc.). Without them the CMake/HAL build fails.

- **IVSC must load before IPU6** (`mei_vsc`, `ivsc_ace`, `ivsc_csi` are ordered
  first in `/etc/modules-load.d/ipu6-camera.conf`); otherwise the sensor appears
  in the media topology but stays powered off.

- **`v4l-utils` is a required runtime dep**, not just for diagnostics - missing
  it manifests as "no video" even when everything else is correct.

- **The sensor can lose a boot-time power race against the LJCA USB bridge.**
  `INT3472` (sensor power/GPIO) depends on GPIO chip `INTC1096`, provided by
  `gpio_ljca` over the Intel LJCA USB bridge - a USB device that can enumerate
  after the camera modules load. When that happens the `ov2740` probe runs
  before its power GPIOs exist and fails with `-EIO: failed to find sensor`,
  so it never joins the media graph and `icamerasrc` gets "not-negotiated".
  (`dummy regulator` dmesg lines are NORMAL - they appear on good boots too;
  power is via int3472 GPIOs, not regulators.) Mitigation installed by
  `setup.sh` on LJCA platforms: LJCA modules in initramfs + the
  `ipu6-sensor-recover.service` oneshot, which rebinds the sensor if missing
  (`sensor-recover.sh` in this repo). **Never reload
  `intel_skl_int3472_discrete` or `intel_ipu6` to fix this**: a successful
  int3472 probe permanently consumes the sensor's ACPI `_DEP` entry
  (`acpi_dev_clear_dependencies`), so a reloaded int3472 finds "no
  dependents", never re-registers the power GPIOs, and the camera is dead
  until reboot. Driver rebind of `ov2740` alone is the only safe recovery.

## Hardware support is gated by PCI ID

New laptop support means adding the `8086:XXXX` PCI ID to the `case` in
`detect_hardware()` with the correct variant. `465d` (Alder Lake-P) is commonly
omitted from other guides - keep it. Meteor Lake (`7d19`/`ipu6epmtl`) is mapped
but the README points users to a different project for it.
