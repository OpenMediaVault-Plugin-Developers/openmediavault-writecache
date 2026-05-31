#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

xpath="/config/services/writecache"

if ! omv_config_exists "${xpath}/ram_backing"; then
  omv_config_add_key "${xpath}" "ram_backing" "tmpfs"
fi

if ! omv_config_exists "${xpath}/zram_size"; then
  omv_config_add_key "${xpath}" "zram_size" "512M"
fi

if ! omv_config_exists "${xpath}/zram_algo"; then
  omv_config_add_key "${xpath}" "zram_algo" "zstd"
fi

omv-salt deploy run --no-color writecache || :

exit 0
