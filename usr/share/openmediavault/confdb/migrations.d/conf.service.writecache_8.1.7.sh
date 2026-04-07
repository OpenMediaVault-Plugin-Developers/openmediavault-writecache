#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

xpath="/config/services/writecache"

if ! omv_config_exists "${xpath}/services"; then
  omv_config_add_key "${xpath}" "services" ""
fi

omv-salt deploy run --no-color writecache || :

exit 0
