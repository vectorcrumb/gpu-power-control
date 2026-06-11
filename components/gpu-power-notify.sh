#!/bin/sh
# gpu-power-notify.sh -- pop a desktop notification summarising which GPU KWin
# is rendering on. Run at login via ~/.config/autostart (installed by
# gpu-power-control), or on demand via `gpu-power-control notify`.

APP="GPU Power Control"

# --- find the NVIDIA dGPU (driver binding is stable across power states) ---
detect_nvidia_pci() {
    for d in /sys/bus/pci/drivers/nvidia/0000:*; do
        [ -e "$d" ] && { basename "$d"; return 0; }
    done
    lspci -D 2>/dev/null | awk 'tolower($0) ~ /nvidia/ && /VGA|3D|Display/ {print $1; exit}'
}

# --- read KWIN_DRM_DEVICES from our own env (inherited at login) or plasmashell ---
get_kwin_devices() {
    if [ -n "${KWIN_DRM_DEVICES:-}" ]; then printf '%s\n' "$KWIN_DRM_DEVICES"; return 0; fi
    for p in $(pgrep -x plasmashell 2>/dev/null); do
        [ -r "/proc/$p/environ" ] || continue
        line=$(tr '\0' '\n' < "/proc/$p/environ" | grep -m1 '^KWIN_DRM_DEVICES=')
        [ -n "$line" ] && { printf '%s\n' "${line#*=}"; return 0; }
    done
    return 1
}

nv_pci=$(detect_nvidia_pci)

# Is an external display on the NVIDIA card connected?
ext_connected=no
if [ -n "$nv_pci" ]; then
    for status in /sys/class/drm/*/status; do
        [ -e "$status" ] || continue
        dev=$(readlink -f "$(dirname "$status")/device" 2>/dev/null)
        case "$dev" in
            *"$nv_pci"*) [ "$(cat "$status" 2>/dev/null)" = connected ] && ext_connected=yes ;;
        esac
    done
fi

nv_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
[ -n "$nv_name" ] || nv_name="NVIDIA dGPU"

devices=$(get_kwin_devices 2>/dev/null || true)

# Is the NVIDIA card first in KWIN_DRM_DEVICES (i.e. KWin's primary render GPU)?
# Resolve the first listed node and the NVIDIA by-path node to their real
# /dev/dri/cardN and compare, so this works whether KWIN_DRM_DEVICES is written as
# cardN (current) or by-path names (older format).
first_dev=${devices%%:*}
nv_card=$(readlink -f "/dev/dri/by-path/pci-${nv_pci}-card" 2>/dev/null)
first_real=$(readlink -f "$first_dev" 2>/dev/null)

if [ -n "$nv_card" ] && [ -n "$first_real" ] && [ "$first_real" = "$nv_card" ]; then
    summary="Graphics: $nv_name"
    body="KWin is rendering this session on the NVIDIA GPU."
    [ "$ext_connected" = yes ] && body="$body
External display: connected."
    icon="video-display"; urgency=normal; expire="--expire-time=8000"
elif [ "$ext_connected" = yes ]; then
    summary="Graphics: AMD iGPU (external screen on NVIDIA)"
    body="KWin is rendering on the AMD integrated GPU, but your external screen is wired to the $nv_name.
Log out and back in to render on the NVIDIA GPU."
    icon="dialog-warning"; urgency=critical; expire=""
else
    summary="Graphics: AMD integrated GPU"
    body="KWin is rendering on the AMD iGPU (power-saving mode)."
    icon="video-display"; urgency=normal; expire="--expire-time=8000"
fi

# Wait (up to ~15s) for the notification service to come up after login.
i=0
while [ "$i" -lt 30 ]; do
    owner=$(gdbus call --session --dest org.freedesktop.DBus \
        --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.NameHasOwner org.freedesktop.Notifications 2>/dev/null)
    case "$owner" in *true*) break ;; esac
    sleep 0.5
    i=$((i + 1))
done

exec notify-send --app-name="$APP" --icon="$icon" --urgency="$urgency" $expire -- "$summary" "$body"
