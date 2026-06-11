# Incident & debug session — 2026-06-11

Machine: `rog-lucas` — ASUS ROG hybrid laptop, Fedora 43 KDE Plasma (Wayland).
GPUs: AMD Cezanne iGPU (`0000:04:00.0` → card1) + NVIDIA RTX 3060 Mobile
(`0000:01:00.0` → card0). External monitor's DisplayPort is wired to the **NVIDIA**
card (`card0-DP-1`). `supergfxd` = Hybrid; NVIDIA `DynamicPowerManagement=3`.

## Symptoms reported
1. System completely froze → had to hard power-off (power button).
2. After restart, could not log into the desktop session.
3. tty (Ctrl+Alt+F2) had no wifi; restarted again.
4. **Unplugging the external monitor allowed login.** Suspected `~/gpu-power-control`.

## Boot timeline (from `journalctl --list-boots`)
- boot **-2**: Jun 9 21:37 → Jun 11 **01:39** — the long session that **froze**.
  (`gpu-power-control install` ran Jun 10 ~21:39; the graphical session from Jun 9
  kept running, so the broken login profile was never applied that session.)
- boot **-1**: Jun 11 01:41 → 01:45 — **docked login failed**, ended in a reboot.
- boot **0**: Jun 11 01:45 → … — logged in **undocked** successfully.

## Root causes (both confirmed in the journal)

### A. Hard freeze — NVIDIA dGPU powered off while driving the external display
At 01:38:16 in boot -2:
```
[drm] [nvidia-drm] [GPU ID 0x00000100] Removing device
[drm] [nvidia-drm] [GPU ID 0x00000100] Unloading driver
powerdevil: DDCA_EVENT_DISPLAY_DISCONNECTED, card0-DP-1
[drm:nv_drm_atomic_commit] *ERROR* Flip event timeout on head 0
nvidia-modeset: ERROR: GPU:0: DP-0: Failed to disable DisplayPort audio stream-3
NVRM: GspRmFree failed: ... status=0x0000000f
NVRM: Assertion failed: (status == NV_OK) || (status == NV_ERR_GPU_IN_FULLCHIP_RESET)
```
The dGPU runtime-suspended / was removed while a page-flip was in flight on the
external head → flip timeout → GSP unreachable → compositor blocked → full freeze.
Tail of boot shows a notification storm + 8× "Power key pressed short" (you on the
button). This is the classic NVIDIA RTD3 (D3cold) hang on a hybrid laptop driving
an external screen. The tool's udev rule was meant to prevent it (pin
`power/control=on` when docked) but did not — see fix #2.

### B. Docked-login lockout — `KWIN_DRM_DEVICES` colon bug (100% the tool)
`10-nvidia-docked-primary.sh` built `KWIN_DRM_DEVICES` from `/dev/dri/by-path/...`
names joined with `:`. KWin also splits that var on `:`, but the by-path names
contain `:` in the PCI address (`pci-0000:01:00.0-card`). Boot -1:
```
kwin_wayland: Failed to open drm device /dev/dri/by-path/pci-0000
kwin_wayland: Failed to open drm device 01
kwin_wayland: Failed to open drm device 00.0-card
kwin_wayland: No suitable DRM devices have been found
```
→ KWin aborts → Plasma can't start → no login **when docked**. Undocked, the profile
sets nothing, so login works (matches the observed behavior). The tty "no wifi" was a
red herring — wifi/NetworkManager comes up with the graphical session, not a bare login.

The two are linked: bug B meant the dGPU-primary profile never engaged, so the machine
always ran in the fragile reverse-PRIME (idle-dGPU-scanout) state that froze in A.

## Fixes applied
1. **Colon bug (B):** resolve each by-path symlink to its colon-free `/dev/dri/cardN`
   target. Value is now `/dev/dri/card0:/dev/dri/card1` (NVIDIA first), splitting into
   two real nodes. Applied to BOTH the source and the live login profile. **Verified.**
   → Lockout can no longer happen.
2. **Freeze-safe power rule (A):** helper now only ever pins `power/control=on` for a
   present screen, and **debounces disconnects** (sleep + re-check) before re-enabling
   suspend, so a transient DP/dock blip can't D3cold the dGPU mid-flip. udev rule now
   launches it via `systemd-run --no-block --collect` so the wait doesn't stall udev.
   Source + installed `/usr/local/bin` + `/etc/udev/rules.d` all carry the fix (mtime
   02:06). **Verified.**

All three scripts pass `sh -n`.

## PENDING TOPICS / next steps
- [x] **Confirm udev reloaded.** Resolved by a full reboot (loads the on-disk rule).
- [x] **Test docked:** DONE — rebooted, logged in **docked with no lockout** (colon
      fix confirmed). `gpu-power-control status` reports "rendering on NVIDIA";
      `KWIN_DRM_DEVICES=/dev/dri/card0:/dev/dri/card1` (card0 = NVIDIA), and nvidia-smi
      shows plasmashell/kwin_wayland/Xwayland on GPU 0 — whole session on the dGPU.
- [ ] **Recovery path if anything misbehaves:** boot/log in **undocked** → always a
      working iGPU session.
- [ ] **Optional hardening (offered, not done):** make the profile refuse to set
      `KWIN_DRM_DEVICES` unless every card path resolves cleanly (defense-in-depth vs.
      future lockouts).
- [ ] **Nuclear option if docked freezes ever recur:** disable dGPU deep runtime
      suspend globally — `options nvidia NVreg_DynamicPowerManagement=0` in
      `/etc/modprobe.d/`, then rebuild initramfs. Costs idle battery even undocked;
      intentionally left OFF to keep the conditional/battery-saving behavior.

## Follow-up — 2026-06-11, after reboot (docked, working)

### Bug C: GPU notification + `status` reported "AMD" while actually on NVIDIA
After the fixes, the login popup said "rendering on AMD" but nvidia-smi showed the
session on GPU 0. Cause: the colon fix changed `KWIN_DRM_DEVICES` from the by-path
form to `/dev/dri/cardN`, but the detection in BOTH `gpu-power-notify.sh` and
`gpu-power-control status` still string-matched the old `…/by-path/pci-<nv>-card*`
prefix → never matched → fell through to the AMD branch. A false negative, not a
real regression.

Fix: both now resolve the first node in `KWIN_DRM_DEVICES` and the NVIDIA by-path
node to their real `/dev/dri/cardN` and compare — format-agnostic (works for cardN
*and* by-path). Verified: `status` now says "rendering on NVIDIA"; corrected
notification re-sent. `sh -n` / `bash -n` clean.

Files touched: `components/gpu-power-notify.sh`, `gpu-power-control` (cmd_status).

### Benchmark — confirmed the dGPU is doing the work
- dGPU ramps under load: idle `P8, 210 MHz, 13 W` → load `P0, 1282 MHz, 21 W` → back
  to P8. Confirms it's the active render GPU, not runtime-suspended.
- `glxgears`/`eglgears` are the only GL benches installed (no glmark2/vkmark); they're
  vsync/window-bound, hang here, and aren't worth using.
- Displays: external DP-1 = **3840×2160 @ 60 Hz** (the 4K screen the tool targets);
  internal eDP-1 = 2560×1440 @ 120 Hz.
- Chosen method: KWin's built-in **Show FPS** overlay, loaded live via gdbus
  (`/Effects … loadEffect showfps`) — no install, no logout. Live load, so it clears
  on next logout. Eyeball test: under continuous motion on the 4K screen it should
  hold ~60 FPS with short/even frame-time bars (= reverse-PRIME copy eliminated).

### Still open (optional)
- [ ] Rigorous A/B of the reverse-PRIME win: measure 4K compositor FPS now
      (NVIDIA-primary) vs after a logout on the iGPU profile. Needs a logout cycle.
- [ ] Install `glmark2`/`vkmark` for raw synthetic GPU scores (note: synthetic apps
      offload to the dGPU regardless, so they don't isolate the compositor-path win).
- [ ] Defense-in-depth: refuse to set `KWIN_DRM_DEVICES` unless every card path
      resolves cleanly (carried over from the first session).

## Note
Underlying NVIDIA RTD3 fragility on this hybrid config is mitigated, not eliminated.
The fixes remove the specific path that froze the machine and make lockout impossible.
