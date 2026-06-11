# gpu-power-control

Manage the NVIDIA dGPU **"docked profile"** for KWin on Wayland, on this ASUS
hybrid-graphics laptop (AMD Cezanne iGPU + NVIDIA RTX 3060 Mobile, Fedora KDE).

## The problem

The USB-C / DisplayPort external output is **physically wired to the NVIDIA
GPU**. By default KWin renders the whole desktop on the weaker AMD iGPU and then
copies every frame across PCIe to the NVIDIA card just to scan it out
("reverse PRIME"). At 4K that copy is the lag. The dGPU also auto-suspends and
KWin loses it (`Failed to open drm node /dev/dri/card0`), causing glitches.

## The fix (two parts)

1. **Login profile** — `components/10-nvidia-docked-primary.sh`, installed to
   `~/.config/plasma-workspace/env/`. At login it checks whether an external
   screen on the NVIDIA card is connected; if so it sets `KWIN_DRM_DEVICES` so
   KWin renders the session **on the NVIDIA GPU** (no cross-GPU copy). If not,
   it does nothing and the iGPU stays primary so the dGPU can sleep on battery.
   *KWin only reads this at startup, so docked⇄mobile switches need a
   logout+login.*

2. **Live power rule** — `components/nvidia-external-display-power.sh` +
   `components/61-nvidia-external-display-power.rules`, installed to
   `/usr/local/bin` and `/etc/udev/rules.d`. A udev hotplug rule pins the dGPU
   awake (`power/control=on`) whenever the external screen is plugged in, and
   lets it suspend (`auto`) when unplugged. This is live — no logout needed.

3. **Login notification** — `components/gpu-power-notify.sh`, run at login via
   `~/.config/autostart/gpu-power-notify.desktop`. Pops a desktop notification
   saying which GPU KWin actually ended up rendering on. If you're docked but
   still on the iGPU, it raises a sticky warning reminding you to log out/in to
   switch to the NVIDIA GPU.

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

After `install`, **log out and back in while docked** to move rendering onto
the NVIDIA GPU. Verify with `gpu-power-control status` — the "KWin render GPU"
section should report *rendering on NVIDIA*.

## Notes / caveats

- Affects the **desktop session**, not the SDDM login screen.
- To put it on your `PATH`: `ln -s ~/gpu-power-control/gpu-power-control ~/.local/bin/`.
- `switcherooctl` (launching individual apps on the dGPU) is unrelated and still
  works alongside this.
