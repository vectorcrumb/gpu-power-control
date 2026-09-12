#!/usr/bin/env bash
# Confirm and restart the graphical session with the requested primary GPU.

set -u

mode=${1:-}
nv_pci=""
for device in /sys/bus/pci/drivers/nvidia/0000:*; do
    [ -e "$device" ] && { nv_pci=$(basename "$device"); break; }
done
case "$mode" in
    amd)
        label="AMD integrated graphics"
        detail="This will close the current desktop session and log you out. The next session will use the AMD iGPU once; later logins return to NVIDIA."
        for status in /sys/class/drm/*/status; do
            [ -e "$status" ] || continue
            dev=$(readlink -f "$(dirname "$status")/device" 2>/dev/null)
            case "$dev" in
                *"$nv_pci")
                    [ -n "$nv_pci" ] || continue
                    if [ "$(cat "$status" 2>/dev/null)" = connected ]; then
                        detail="$detail\n\nAn external display is still wired to NVIDIA. Disconnect it first, or AMD mode will use the slower cross-GPU copy path."
                        break
                    fi
                    ;;
            esac
        done
        ;;
    nvidia)
        label="NVIDIA graphics"
        detail="This will close the current desktop session and log you out. The next session will use the NVIDIA dGPU."
        ;;
    *)
        echo "usage: $(basename "$0") {amd|nvidia}" >&2
        exit 2
        ;;
esac

confirm_text="Restart the desktop session using $label?\n\n$detail\n\nSave your work before continuing."

if [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ] && command -v kdialog >/dev/null 2>&1; then
    kdialog --title "GPU Power Control" --warningyesno "$confirm_text" || exit 1
elif [ -t 0 ]; then
    printf '%b\nContinue? [y/N] ' "$confirm_text" >&2
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) echo "Cancelled." >&2; exit 1 ;; esac
else
    echo "A graphical session or interactive terminal is required for confirmation." >&2
    exit 1
fi

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/gpu-power-control"
mkdir -p "$state_dir"
printf '%s\n' "$mode" > "$state_dir/next-session-mode"

if command -v gdbus >/dev/null 2>&1; then
    gdbus call --session --dest org.kde.Shutdown --object-path /Shutdown \
        --method org.kde.Shutdown.logout >/dev/null
elif command -v qdbus6 >/dev/null 2>&1; then
    qdbus6 org.kde.Shutdown /Shutdown logout
else
    rm -f "$state_dir/next-session-mode"
    echo "Could not find gdbus or qdbus6; the session was not restarted." >&2
    exit 1
fi
