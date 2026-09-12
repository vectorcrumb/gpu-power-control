#!/usr/bin/env bash
# Notification checks used by the dock watcher and battery reminder timers.

set -u

APP="GPU Power Control"
LIBEXEC_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/gpu-power-control"
SWITCH="$LIBEXEC_DIR/gpu-session-switch.sh"

detect_nvidia_pci() {
    local d
    for d in /sys/bus/pci/drivers/nvidia/0000:*; do
        [ -e "$d" ] && { basename "$d"; return 0; }
    done
    lspci -D 2>/dev/null | awk 'tolower($0) ~ /nvidia/ && /VGA|3D|Display/ {print $1; exit}'
}

session_env() {
    local name=$1 p line
    for p in $(pgrep -x plasmashell 2>/dev/null) $(pgrep -x kwin_wayland 2>/dev/null); do
        [ -r "/proc/$p/environ" ] || continue
        line=$(tr '\0' '\n' < "/proc/$p/environ" | grep -m1 "^${name}=" || true)
        [ -n "$line" ] && { printf '%s\n' "${line#*=}"; return 0; }
    done
    return 1
}

is_nvidia_primary() {
    local nv_pci devices first_real nv_card
    nv_pci=$(detect_nvidia_pci) || return 1
    devices=$(session_env KWIN_DRM_DEVICES) || return 1
    first_real=$(readlink -f "${devices%%:*}" 2>/dev/null)
    nv_card=$(readlink -f "/dev/dri/by-path/pci-${nv_pci}-card" 2>/dev/null)
    [ -n "$first_real" ] && [ "$first_real" = "$nv_card" ]
}

nvidia_external_connected() {
    local nv_pci status dev
    nv_pci=$(detect_nvidia_pci) || return 1
    for status in /sys/class/drm/*/status; do
        [ -e "$status" ] || continue
        dev=$(readlink -f "$(dirname "$status")/device" 2>/dev/null)
        case "$dev" in
            *"$nv_pci"*) [ "$(cat "$status" 2>/dev/null)" = connected ] && return 0 ;;
        esac
    done
    return 1
}

on_external_power() {
    local supply type
    for supply in /sys/class/power_supply/*; do
        [ -e "$supply/type" ] || continue
        type=$(cat "$supply/type" 2>/dev/null)
        case "$type" in
            Mains|USB|USB_C|USB_PD|Wireless)
                [ "$(cat "$supply/online" 2>/dev/null)" = 1 ] && return 0
                ;;
        esac
    done
    return 1
}

notify_with_switch() {
    local summary=$1 body=$2 action_label=$3 mode=$4 urgency=$5 action
    action=$(notify-send --app-name="$APP" --icon=dialog-warning --urgency="$urgency" \
        --expire-time=30000 --action="switch=$action_label" -- "$summary" "$body" || true)
    if [ "$action" = switch ]; then
        "$SWITCH" "$mode" || true
    fi
    return 0
}

case "${1:-}" in
    dock)
        runtime_dir=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
        warned="$runtime_dir/gpu-power-control-amd-docked-warned"
        if ! nvidia_external_connected; then
            rm -f "$warned"
        elif is_nvidia_primary; then
            rm -f "$warned"
        elif [ ! -e "$warned" ]; then
            : > "$warned"
            notify_with_switch \
                "External display is using the slow GPU path" \
                "KWin is still rendering on AMD and copying the 4K desktop to NVIDIA. Restart the desktop session to make NVIDIA primary." \
                "Restart using NVIDIA…" nvidia normal
        fi
        ;;
    battery)
        runtime_dir=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
        battery_since="$runtime_dir/gpu-power-control-nvidia-battery-since"
        if on_external_power || ! is_nvidia_primary; then
            rm -f "$battery_since"
            exit 0
        fi
        now=$(date +%s)
        then=$(cat "$battery_since" 2>/dev/null || true)
        case "$then" in
            ''|*[!0-9]*) printf '%s\n' "$now" > "$battery_since"; exit 0 ;;
        esac
        [ $((now - then)) -ge 1800 ] || exit 0
        # Start the next interval before displaying the actionable notification.
        printf '%s\n' "$now" > "$battery_since"
        notify_with_switch \
            "NVIDIA high-power mode on battery" \
            "KWin is using the NVIDIA dGPU while the computer is on battery power. This reminder repeats every 30 minutes." \
            "Restart using AMD…" amd normal
        ;;
    *)
        echo "usage: $(basename "$0") {dock|battery}" >&2
        exit 2
        ;;
esac
