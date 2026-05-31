# openmediavault-writecache

OverlayFS-based write reduction plugin for openmediavault 7

## Highlights
- Uses tmpfs + overlayfs for selected write-heavy system paths (e.g., `/var/log`, APT cache).
- Optional **zram** (compressed RAM) backing — a log2ram-style workspace that holds more data per MB of RAM. Like tmpfs it is volatile; use a shared folder for power-loss durability.
- Safe defaults: caches dropped at reboot; optional flush on shutdown & daily timer.
- Journald `Storage=volatile` option to keep logs in RAM.
- Salt-managed config at `/etc/omv-writecache/config.yaml`.
- Systemd oneshot units for mount/flush.
- Minimal web UI (Workbench YAML) under **Services → Write Cache**.

### Manual CLI
```bash
sudo /usr/sbin/omv-writecache mount
sudo /usr/sbin/omv-writecache flush
sudo /usr/sbin/omv-writecache unmount
sudo /usr/sbin/omv-writecache status
```
