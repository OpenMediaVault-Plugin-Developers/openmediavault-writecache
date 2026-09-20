# openmediavault-writecache

OverlayFS-based write reduction plugin for openmediavault 7

## Highlights
- Uses tmpfs + overlayfs for selected write-heavy system paths (e.g., `/var/log`, APT cache).
- Optional **zram** (compressed RAM) backing — a log2ram-style workspace that holds more data per MB of RAM. Like tmpfs it is volatile; use a shared folder for power-loss durability.
- Safe defaults: caches dropped at reboot; optional flush on shutdown & daily timer.
- Journald `Storage=volatile` option to keep logs in RAM.
- Salt-managed config at `/etc/omv-writecache/config.yaml`.
- Systemd oneshot units for mount/flush.
- Minimal web UI (Workbench YAML) under **Services → WriteCache**.

### Manual CLI
```bash
sudo /usr/sbin/omv-writecache mount
sudo /usr/sbin/omv-writecache flush
sudo /usr/sbin/omv-writecache unmount
sudo /usr/sbin/omv-writecache status
```

### `/var/log` and systemd-journald

By default `/var/log` is cached with policy `drop`: cached writes are discarded on
unmount/reboot and are never written back, so periodic `flush`/`rotateflush` runs
never touch that overlay and journald is left alone.

If you instead set `/var/log` to `flush`, `persist`, or `writeback` (to keep
journal logs across the cache cycle), each flush unmounts and remounts a fresh
overlay under journald's active journal file. journald keeps that file open, so
the unmount falls back to a lazy detach, and once the new overlay is in place
journald notices its file identity changed, logs
`Journal file has been deleted, rotating`, and rotates. `rotateflush` already
runs `journalctl --rotate && journalctl --sync` beforehand to minimize this, but
a small window (and the log message) can still occur.

To close that window, add an explicit restart to the `services` list and run
with `--restart`:
```
systemd-journald = restart
```
This makes the plugin restart journald right after the new overlay is mounted
instead of waiting on journald's own detection. systemd buffers the journal
socket across the restart, so no messages are lost from the restart itself.
Only add this if you've changed `/var/log`'s policy away from the `drop`
default — with `drop`, flushes never touch `/var/log` and the restart would
just interrupt logging for no benefit.
