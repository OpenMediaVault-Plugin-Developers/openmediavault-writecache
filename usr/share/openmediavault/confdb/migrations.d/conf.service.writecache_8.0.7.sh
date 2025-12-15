#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

systemctl disable --now omv-writecache-flush.service 2>/dev/null || true
rm -f /etc/systemd/system/omv-writecache-flush.service
systemctl daemon-reload

omv-salt deploy run --quiet --no-color writecache

exit 0
