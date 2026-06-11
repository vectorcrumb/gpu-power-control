#!/bin/sh
# Pin the NVIDIA dGPU powered on (no PCI runtime suspend) while an external
# display wired to it is connected; allow runtime suspend otherwise.
#
# Invoked by udev on DRM hotplug events (runs as root). Installed by
# gpu-power-control to /usr/local/bin.

# Find the NVIDIA dGPU's PCI address (driver binding is stable across power states).
nv_pci=""
for d in /sys/bus/pci/drivers/nvidia/0000:*; do
    [ -e "$d" ] && { nv_pci=$(basename "$d"); break; }
done
[ -n "$nv_pci" ] || exit 0

pm="/sys/bus/pci/devices/$nv_pci/power/control"
[ -w "$pm" ] || exit 0

connected=0
for status in /sys/class/drm/*/status; do
    [ -e "$status" ] || continue
    dev=$(readlink -f "$(dirname "$status")/device" 2>/dev/null)
    case "$dev" in
        *"$nv_pci"*)
            [ "$(cat "$status" 2>/dev/null)" = "connected" ] && connected=1
            ;;
    esac
done

if [ "$connected" = "1" ]; then
    echo on > "$pm"     # external screen present -> keep the dGPU awake. Safe to
    exit 0              # apply instantly; never delays making docking safe.
fi

# No NVIDIA output is connected right now -- but a momentary DP/dock link blip can
# report "disconnected" while a page-flip is still in flight on that head. Letting
# the dGPU runtime-suspend (D3cold) at that instant is exactly what hard-hung the
# machine (nvidia-drm "Removing device" + flip timeout). So debounce: wait, then
# re-check, and only enable suspend if the screen is *really* gone. The udev rule
# runs this via `systemd-run --no-block`, so this sleep does not stall udev.
sleep 2
for status in /sys/class/drm/*/status; do
    [ -e "$status" ] || continue
    dev=$(readlink -f "$(dirname "$status")/device" 2>/dev/null)
    case "$dev" in
        *"$nv_pci"*)
            if [ "$(cat "$status" 2>/dev/null)" = connected ]; then
                echo on > "$pm"   # screen came back -> it was a blip; stay awake
                exit 0
            fi
            ;;
    esac
done

echo auto > "$pm"   # genuinely undocked -> allow runtime suspend (save battery)
