#!/bin/sh
# Auto docked GPU profile for KWin (Wayland) -- installed by gpu-power-control.
#
# If an external display wired to the NVIDIA dGPU is connected *at login*, make
# KWin render the whole session on the NVIDIA card (avoids the slow reverse-PRIME
# frame copy from the AMD iGPU). Otherwise leave the iGPU primary so the dGPU can
# power down and save battery.
#
# KWin reads KWIN_DRM_DEVICES once at startup, so switching docked<->mobile only
# takes effect after a logout+login. This file is sourced by startplasma.

# Find the NVIDIA dGPU's PCI address (driver binding is stable across power states).
nv_pci=""
for d in /sys/bus/pci/drivers/nvidia/0000:*; do
    [ -e "$d" ] && { nv_pci=$(basename "$d"); break; }
done

if [ -n "$nv_pci" ]; then
    nv_dev="/dev/dri/by-path/pci-${nv_pci}-card"

    # Is any output on the NVIDIA card connected right now?
    external_connected=0
    for status in /sys/class/drm/*/status; do
        [ -e "$status" ] || continue
        dev=$(readlink -f "$(dirname "$status")/device" 2>/dev/null)
        case "$dev" in
            *"$nv_pci"*)
                [ "$(cat "$status" 2>/dev/null)" = "connected" ] && external_connected=1
                ;;
        esac
    done

    if [ "$external_connected" = "1" ] && [ -e "$nv_dev" ]; then
        # KWIN_DRM_DEVICES is ':'-separated, but the /dev/dri/by-path names embed
        # ':' in the PCI address (pci-0000:01:00.0-card), so KWin would split each
        # path into garbage fragments and find no GPU ("No suitable DRM devices").
        # Resolve every by-path symlink to its colon-free /dev/dri/cardN target and
        # list those instead. First device = primary render GPU (NVIDIA); the rest
        # keep other outputs (e.g. the internal panel) alive.
        nv_card=$(readlink -f "$nv_dev")
        devs="$nv_card"
        for card in /dev/dri/by-path/pci-*-card; do
            [ -e "$card" ] || continue
            real=$(readlink -f "$card")
            [ "$real" = "$nv_card" ] || devs="$devs:$real"
        done
        export KWIN_DRM_DEVICES="$devs"
    fi
fi
