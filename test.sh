#!/bin/bash
# =============================================================================
# IPU6 Camera Diagnostic Test
# =============================================================================
# Run this to check if everything is working correctly.
# Does NOT require root for most checks.
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
warn() { echo -e "  ${YELLOW}?${NC} $1"; }

echo ""
echo "=== IPU6 Camera Diagnostic ==="
echo ""

# Hardware
echo "Hardware:"
IPU6_PCI=$(lspci -nn -d ::0480 2>/dev/null | head -1)
if [ -n "$IPU6_PCI" ]; then
    pass "IPU6 detected: $IPU6_PCI"
else
    fail "No IPU6 device found"
fi

# Kernel
echo ""
echo "Kernel: $(uname -r)"

# Modules
echo ""
echo "Kernel modules:"
for mod in intel_ipu6 intel_ipu6_isys ov2740 ivsc_ace ivsc_csi mei_vsc_hw v4l2loopback; do
    if lsmod | grep -qw "$mod" 2>/dev/null; then
        pass "$mod loaded"
    else
        fail "$mod NOT loaded"
    fi
done

# Check for PSYS
if lsmod | grep -q "intel_ipu6_psys" 2>/dev/null; then
    pass "intel_ipu6_psys loaded"
elif [ -e /dev/ipu-psys0 ]; then
    pass "PSYS device exists (/dev/ipu-psys0)"
else
    warn "intel_ipu6_psys not loaded (may still work if HAL handles it)"
fi

# v4l2loopback
echo ""
echo "Virtual camera:"
if [ -e /dev/video99 ]; then
    pass "/dev/video99 exists"
else
    fail "/dev/video99 does NOT exist — v4l2loopback may not be configured"
fi

# Sensor in media topology
echo ""
echo "Media topology:"
if command -v media-ctl &>/dev/null; then
    SENSOR_ENTITY=$(media-ctl -d /dev/media0 -p 2>/dev/null | grep -i "ov2740\|ov01a\|ov02c\|ov08\|ov13b\|hm2170\|hi556" | head -1)
    if [ -n "$SENSOR_ENTITY" ]; then
        pass "Sensor found: $SENSOR_ENTITY"
    else
        fail "No sensor in media topology"
    fi
else
    warn "media-ctl not installed (apt install v4l-utils)"
fi

# GStreamer plugin
echo ""
echo "GStreamer:"
if GST_PLUGIN_PATH=/usr/lib/gstreamer-1.0 gst-inspect-1.0 icamerasrc &>/dev/null; then
    pass "icamerasrc plugin found"
else
    fail "icamerasrc plugin NOT found"
fi

# Camera HAL
echo ""
echo "Camera HAL:"
if [ -f /usr/lib/libcamhal.so ]; then
    pass "libcamhal.so installed"
else
    fail "libcamhal.so NOT found"
fi

if [ -d /etc/camera ]; then
    SENSOR_CONFIGS=$(find /etc/camera -name "*.xml" -path "*/sensors/*" | wc -l)
    pass "Camera config: $SENSOR_CONFIGS sensor configs in /etc/camera/"
else
    fail "/etc/camera/ does not exist"
fi

# Systemd service (on-demand relay)
echo ""
echo "Service (on-demand relay):"
if systemctl is-enabled v4l2-relayd &>/dev/null; then
    pass "v4l2-relayd enabled"
else
    fail "v4l2-relayd NOT enabled"
fi

if systemctl is-active v4l2-relayd &>/dev/null; then
    pass "v4l2-relayd active (idle — sensor/LED only power on when an app opens the camera)"
else
    fail "v4l2-relayd NOT active"
    echo ""
    echo "  Recent logs:"
    journalctl -u v4l2-relayd -n 5 --no-pager 2>/dev/null | sed 's/^/    /'
fi

# Warn if the old always-on service is still present
if systemctl is-enabled ipu6-camera-loopback &>/dev/null 2>&1; then
    warn "old always-on ipu6-camera-loopback still enabled — disable it: sudo systemctl disable --now ipu6-camera-loopback"
fi