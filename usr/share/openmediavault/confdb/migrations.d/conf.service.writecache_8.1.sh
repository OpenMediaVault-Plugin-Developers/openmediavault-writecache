#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

xpath="/config/services/writecache"

if ! omv_config_exists "${xpath}/use_tmpfs"; then
  omv_config_add_key "${xpath}" "use_tmpfs" "1"
fi

if ! omv_config_exists "${xpath}/sharedfolderref"; then
  omv_config_add_key "${xpath}" "sharedfolderref" ""
fi

if ! omv_config_exists "${xpath}/flush_on_boot"; then
  omv_config_add_key "${xpath}" "flush_on_boot" "0"
fi

omv-salt deploy run --no-color writecache || :

exit 0
