#!/bin/sh

set -e

. /usr/share/openmediavault/scripts/helper-functions

svc="writecache"
xpath="/config/services/${svc}"

if ! omv_config_exists "${xpath}"; then
  omv_config_add_node "/config/services" "${svc}"
  omv_config_add_key "${xpath}" "enable" "0"
  omv_config_add_key "${xpath}" "tmpfs_size" "25%"
  omv_config_add_key "${xpath}" "journald_storage" "auto"
  omv_config_add_key "${xpath}" "flush_on_shutdown" "1"
  omv_config_add_key "${xpath}" "rotate_on_shutdown" "1"
  omv_config_add_key "${xpath}" "flush_daily" "0"
  omv_config_add_key "${xpath}" "rotate_on_daily_flush" "1"
  omv_config_add_key "${xpath}" "paths" \
"/var/cache/apt/archives = drop
/var/cache/samba = drop
/var/lib/apt/lists = drop
/var/lib/dpkg/updates = flush
/var/lib/openmediavault/rrd = flush
/var/lib/rrdcached = flush
/var/lib/monit = flush
/var/log = flush
/var/tmp = drop"
fi

if ! omv_config_exists "${xpath}/rotate_on_shutdown"; then
  omv_config_add_key "${xpath}" "rotate_on_shutdown" "1"
fi
if ! omv_config_exists "${xpath}/rotate_on_daily_flush"; then
  omv_config_add_key "${xpath}" "rotate_on_daily_flush" "1"
fi

exit 0
