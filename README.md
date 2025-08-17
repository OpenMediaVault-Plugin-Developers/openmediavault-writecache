# openmediavault-writecache

OverlayFS-based write reduction plugin for OpenMediaVault 7 (Debian 12).

## Highlights
- Uses tmpfs + overlayfs for selected write-heavy system paths (e.g., `/var/log`, APT cache).
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
```

### Packaging
Standard debhelper packaging. Build with:
```bash
dpkg-buildpackage -us -uc -b
```
Then install the resulting `openmediavault-writecache_*.deb`.
