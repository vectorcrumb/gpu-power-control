# gpu-power-control

Manage KWin's primary GPU and power warnings on this ASUS
hybrid-graphics laptop (AMD Cezanne iGPU + NVIDIA RTX 3060 Mobile, Fedora KDE).

## The problem

The USB-C / DisplayPort external output is **physically wired to the NVIDIA
GPU**. By default KWin renders the whole desktop on the weaker AMD iGPU and then
copies every frame across PCIe to the NVIDIA card just to scan it out
("reverse PRIME"). At 4K that copy is the lag. The dGPU also auto-suspends and
KWin loses it (`Failed to open drm node /dev/dri/card0`), causing glitches.

## Policy and safeguards

1. **NVIDIA by default** — `components/10-nvidia-docked-primary.sh`, installed
   to `~/.config/plasma-workspace/env/`, sets `KWIN_DRM_DEVICES` so KWin renders
   every normal session on NVIDIA. This avoids the slow reverse-PRIME copy when
   docking later. `restart-amd` selects AMD for the next session only; the
   following login returns to NVIDIA automatically. KWin only reads the GPU
   order at startup, so switching performs a confirmed logout.

2. **Live power rule** — `components/nvidia-external-display-power.sh` +
   `components/61-nvidia-external-display-power.rules`, installed to
   `/usr/local/bin` and `/etc/udev/rules.d`. A udev hotplug rule pins the dGPU
   awake (`power/control=on`) whenever the external screen is plugged in, and
   lets it suspend (`auto`) when unplugged. This is live — no logout needed.

3. **Dock warning** — a user timer checks for a newly connected display every
   10 seconds. If the current session is AMD-primary, it warns once for that
   connection and offers a **Restart using NVIDIA…** action.

4. **Battery reminder** — a lightweight check tracks continuous time with AC
   disconnected while KWin is NVIDIA-primary, and warns after each 30-minute
   interval. Its **Restart using AMD…** action uses the same confirmation flow
   as the command line.

5. **Login notification** — `components/gpu-power-notify.sh`, run at login via
   `~/.config/autostart/gpu-power-notify.desktop`. Pops a desktop notification
   saying which GPU KWin actually ended up rendering on.

Both components auto-detect the NVIDIA PCI address, so they survive PCI
renumbering / kernel updates.

## Usage

```sh
~/gpu-power-control/gpu-power-control status      # inspect everything
~/gpu-power-control/gpu-power-control install      # install both parts (uses sudo)
~/gpu-power-control/gpu-power-control uninstall    # remove and restore defaults
~/gpu-power-control/gpu-power-control on           # force dGPU on now
~/gpu-power-control/gpu-power-control auto          # allow dGPU to suspend now
~/gpu-power-control/gpu-power-control notify        # preview the login popup now
```

After `install`, run `gpu-power-control restart-nvidia` (or log out normally) to
start the first NVIDIA-primary session. Verify with `gpu-power-control status` —
the "KWin render GPU" section should report *rendering on NVIDIA*.

## Switching sessions

```sh
~/gpu-power-control/gpu-power-control restart-amd
~/gpu-power-control/gpu-power-control restart-nvidia
```

Both commands show a confirmation prompt because switching logs out the current
Wayland session and closes its applications. `restart-amd` writes a one-shot
state marker; the login profile consumes it when the AMD session starts.

## Notes / caveats

- Affects the **desktop session**, not the SDDM login screen.
- NVIDIA-primary is deliberately the default even on battery. The recurring
  battery notification is the guardrail for switching to a temporary AMD session.
- `install` adds `~/.local/bin/gpu-power-control` as a symlink to this checkout.
- `switcherooctl` (launching individual apps on the dGPU) is unrelated and still
  works alongside this.
