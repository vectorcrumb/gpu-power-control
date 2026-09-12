#!/bin/sh
# Default NVIDIA GPU profile for KWin (Wayland) -- installed by gpu-power-control.
#
# KWin normally renders on NVIDIA, whether docked or mobile.  The
# `gpu-power-control restart-amd` command creates a one-shot marker that makes the
# next graphical session use KDE's default AMD iGPU instead.  The marker is
# consumed here, so subsequent sessions return to NVIDIA automatically.
#
# KWin reads KWIN_DRM_DEVICES once at startup, so changing renderer requires a
# logout+login. This file is sourced by startplasma.

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/gpu-power-control"
next_mode_file="$state_dir/next-session-mode"

if [ -e "$next_mode_file" ]; then
    next_mode=$(cat "$next_mode_file" 2>/dev/null)
    rm -f "$next_mode_file"
    if [ "$next_mode" = "amd" ]; then
        unset KWIN_DRM_DEVICES
        export GPU_POWER_CONTROL_MODE=amd
        return 0 2>/dev/null || exit 0
    fi
fi

# Find the NVIDIA dGPU's PCI address (driver binding is stable across power states).
nv_pci=""
for d in /sys/bus/pci/drivers/nvidia/0000:*; do
    [ -e "$d" ] && { nv_pci=$(basename "$d"); break; }
done

if [ -n "$nv_pci" ]; then
    nv_dev="/dev/dri/by-path/pci-${nv_pci}-card"

    if [ -e "$nv_dev" ]; then
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
        export GPU_POWER_CONTROL_MODE=nvidia
    fi
fi
