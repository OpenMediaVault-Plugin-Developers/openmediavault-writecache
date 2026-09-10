#!/bin/bash

set -e

. /usr/share/openmediavault/scripts/helper-functions

xpath="/config/services/writecache"

if ! omv_config_exists "${xpath}/services"; then
  omv_config_add_key "${xpath}" "services" ""
fi

# Seed the service actions that stop rrdcached/monit cleanly before the flush of
# their own data directories, instead of letting the unmount SIGKILL them and
# leave a stale pidfile behind (issue #7).
#
# Existing entries are left untouched: a line is added only when that service
# name is not already listed (with any action), so a user's own action choice
# is never overwritten and nothing is duplicated.
current="$(omv_config_get "${xpath}/services")"

add_default_service() {
  name="$1"
  line="$2"
  if printf '%s\n' "${current}" | grep -Eq "^[[:space:]]*${name}[[:space:]]*(=|\$)"; then
    return 0
  fi
  if [ -n "${current}" ]; then
    current="${current}
${line}"
  else
    current="${line}"
  fi
}

add_default_service "monit" "monit = stopdailystart"
add_default_service "rrdcached" "rrdcached = stopstart"

omv_config_update "${xpath}/services" "${current}"

omv-salt deploy run --no-color writecache || :

exit 0
