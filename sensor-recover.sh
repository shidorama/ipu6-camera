#!/bin/bash
# ipu6-camera-adl - Sensor boot-race recovery
#
# The OV2740's power path (INT3472) depends on GPIO chip INTC1096, provided by
# gpio_ljca over the Intel LJCA USB bridge. If the bridge enumerates late, the
# ov2740 probe runs before its power GPIOs exist and fails with -EIO ("failed
# to find sensor"), so the sensor never joins the media graph. int3472 itself
# recovers on its own via deferred probe once the bridge appears.
#
# Recovery is therefore a driver REBIND of the sensor only. Do NOT reload
# intel_skl_int3472_discrete or the intel_ipu6 modules: a successful int3472
# probe permanently consumes the sensor's ACPI _DEP entry
# (acpi_dev_clear_dependencies), so a reloaded int3472 finds "no dependents",
# never re-registers the power GPIOs, and the camera is dead until reboot.
#
# Usage: sensor-recover.sh [--force]
#   default  rebind only if the sensor is missing from the media graph
#   --force  unbind + rebind even if healthy (for testing)
set -uo pipefail

SENSOR_HID="INT3474"   # ACPI HID of the OV2740 on Alder Lake ThinkPads
SENSOR_DRV="ov2740"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GREEN}[OK]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

[ "$EUID" -eq 0 ] || { err "Run as root: sudo $0"; exit 1; }

sensor_present() {
    local m
    for m in /dev/media*; do
        [ -e "$m" ] || continue
        media-ctl -d "$m" -p 2>/dev/null | grep -q "entity.*${SENSOR_DRV}" && return 0
    done
    return 1
}

if sensor_present && [ "${1:-}" != "--force" ]; then
    info "Sensor present in media graph - nothing to do."
    exit 0
fi

if [ ! -e /sys/bus/acpi/devices/INTC1096:00 ]; then
    info "No INTC1096 (LJCA) on this platform - boot race does not apply here."
    exit 0
fi

echo "Waiting for LJCA GPIO chip (INTC1096)..."
for _ in $(seq 1 60); do
    grep -q "INTC1096" /sys/class/gpio/gpiochip*/label 2>/dev/null && break
    sleep 1
done
if ! grep -q "INTC1096" /sys/class/gpio/gpiochip*/label 2>/dev/null; then
    err "INTC1096 GPIO chip never appeared - LJCA USB bridge missing; cannot recover."
    exit 1
fi
info "INTC1096 GPIO chip present"

echo "Waiting for INT3472 (sensor power) to bind..."
bound=0
for _ in $(seq 1 30); do
    bound=1
    for d in /sys/bus/platform/devices/INT3472:*; do
        [ -e "$d/driver" ] || bound=0
    done
    [ "$bound" -eq 1 ] && break
    sleep 1
done
[ "$bound" -eq 1 ] && info "INT3472 bound" || err "INT3472 not fully bound - attempting rebind anyway"

modprobe "$SENSOR_DRV" 2>/dev/null || true

found=0
for dev in /sys/bus/i2c/devices/i2c-${SENSOR_HID}:*; do
    [ -e "$dev" ] || continue
    found=1
    name=$(basename "$dev")
    if [ -e "$dev/driver" ]; then
        echo "Unbinding $name..."
        echo "$name" > "/sys/bus/i2c/drivers/${SENSOR_DRV}/unbind" 2>/dev/null || true
        sleep 1
    fi
    echo "Binding $name to ${SENSOR_DRV}..."
    echo "$name" > "/sys/bus/i2c/drivers/${SENSOR_DRV}/bind" 2>/dev/null \
        || err "bind write failed for $name"
done
[ "$found" -eq 1 ] || { err "No i2c device matching ${SENSOR_HID} found."; exit 1; }

echo "Waiting for sensor to join the media graph..."
for _ in $(seq 1 15); do
    sensor_present && break
    sleep 1
done

systemctl try-restart v4l2-relayd 2>/dev/null || true

if sensor_present; then
    info "Sensor present in media graph - camera recovered."
    exit 0
else
    err "Sensor still missing after rebind. Check: dmesg | grep -iE 'int3472|${SENSOR_DRV}'"
    exit 1
fi
