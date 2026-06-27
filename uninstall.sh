#!/bin/bash
# ipu6-camera-adl — Uninstall
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[OK]${NC} $1"; }
step() { echo -e "\n${CYAN}==> $1${NC}"; }

[ "$EUID" -eq 0 ] || { echo -e "${RED}[ERROR]${NC} Run as root: sudo $0"; exit 1; }

echo "This will remove the IPU6 camera stack installed by setup.sh."
read -p "Continue? [y/N] " -n 1 -r; echo
[[ $REPLY =~ ^[Yy]$ ]] || exit 0

step "Stopping services..."
# on-demand relay (current)
systemctl disable --now v4l2-relayd 2>/dev/null || true
# always-on loopback (legacy, removed in newer installs)
systemctl stop ipu6-camera-loopback 2>/dev/null || true
systemctl disable ipu6-camera-loopback 2>/dev/null || true
rm -f /etc/systemd/system/ipu6-camera-loopback.service
systemctl daemon-reload
info "Services stopped"

step "Removing DKMS module..."
dkms remove ipu6-drivers/0.0.0 --all 2>/dev/null || true
rm -rf /usr/src/ipu6-drivers-0.0.0
info "DKMS removed"

step "Removing config files..."
rm -f /etc/modprobe.d/ipu6-camera.conf
rm -f /etc/modules-load.d/ipu6-camera.conf
info "Config removed"

step "Removing libraries..."
rm -f /usr/lib/libcamhal.so* /usr/lib/libgsticamerainterface-1.0.so*
rm -rf /usr/lib/libcamhal/
rm -f /usr/lib/gstreamer-1.0/libgsticamerasrc.*
rm -f /usr/lib/pkgconfig/libcamhal.pc /usr/lib/pkgconfig/libgsticamerasrc.pc
rm -f /usr/lib/pkgconfig/ia_imaging.pc /usr/lib/pkgconfig/libgcss.pc /usr/lib/pkgconfig/libipu.pc
rm -rf /usr/include/libcamhal/ /usr/include/gstreamer-1.0/gst/icamera/ /etc/camera/
ldconfig
info "Libraries removed"

step "Cleaning build files..."
rm -rf /tmp/ipu6-camera-adl-build
info "Build directory removed"

echo -e "\n${GREEN}Uninstall complete.${NC} Reboot to finish."
echo "Note: firmware in /lib/firmware/intel/ipu/ was left in place (harmless)."