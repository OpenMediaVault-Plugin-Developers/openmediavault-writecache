#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

systemctl disable --now omv-writecache-teardown.service 2>/dev/null || true
rm -f /etc/systemd/system/omv-writecache-teardown.service
systemctl daemon-reload

exit 0
