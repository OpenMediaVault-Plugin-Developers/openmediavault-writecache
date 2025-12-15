# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2025 openmediavault plugin developers
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

{% set config = salt['omv_conf.get']('conf.service.writecache') %}

php-fpm-tmpfiles-conf:
  file.managed:
    - name: /etc/tmpfiles.d/php-fpm.conf
    - contents: |
        d /run/php 0755 root root -
    - mode: '0644'
    - user: root
    - group: root

configure_writecache_config_dir:
  file.directory:
    - name: "/etc/omv-writecache"
    - user: root
    - group: root
    - mode: 0755

configure_writecache_config:
  file.managed:
    - name: "/etc/omv-writecache/config.yaml"
    - contents: |
        {{ pillar['headers']['auto_generated'] }}
        {{ pillar['headers']['warning'] }}
        enable: {{ config.enable | to_bool }}
        tmpfs_size: "{{ config.tmpfs_size }}"
        journald_storage: "{{ config.journald_storage }}"
        flush_on_shutdown: {{ config.flush_on_shutdown | to_bool }}
        flush_daily: {{ config.flush_daily | to_bool }}
        paths: |
{%- for p in config.get('paths', '').splitlines() if p.strip() %}
          {{ p.strip() }}
{%- endfor %}
    - user: root
    - group: root
    - mode: 644

configure_writecache_journald_dir:
  file.directory:
    - name: "/etc/systemd/journald.conf.d"
    - user: root
    - group: root
    - dir_mode: 0755

configure_writecache_journald:
  file.managed:
    - name: "/etc/systemd/journald.conf.d/10-writecache.conf"
    - contents: |
        {{ pillar['headers']['auto_generated'] }}
        {{ pillar['headers']['warning'] }}
        [Journal]
        Storage={{ config.journald_storage }}
    - user: root
    - group: root
    - mode: 0644

reload_journald_on_change:
  module.run:
    - name: service.systemctl_reload
    - onchanges:
      - file: configure_writecache_journald

restart_journald_on_change:
  service.running:
    - name: systemd-journald
    - reload: True
    - onchanges:
      - file: configure_writecache_journald

{% set shutdown_action = None %}
{% if config.flush_on_shutdown | to_bool %}
{% set shutdown_action = 'rotateflush' if (config.rotate_on_shutdown | to_bool) else 'flush' %}
{% endif %}

omv-writecache-setup_service:
  file.managed:
    - name: /etc/systemd/system/omv-writecache-setup.service
    - contents: |
        [Unit]
        Description=OMV WriteCache: mount overlays (tmpfs upper) for selected paths
        DefaultDependencies=no
        After=systemd-remount-fs.service local-fs-pre.target tmp.mount
        Before=systemd-tmpfiles-setup.service systemd-journald.service local-fs.target postfix@-.service shutdown.target
        RequiresMountsFor=/var
        Requires=tmp.mount
        Conflicts=shutdown.target

        [Service]
        Type=oneshot
        ExecStart=/usr/sbin/omv-writecache mount
{%- if shutdown_action %}
        ExecStop=/usr/sbin/omv-writecache {{ shutdown_action }}
{%- endif %}
        ExecStop=/usr/sbin/omv-writecache unmount
        RemainAfterExit=yes
        TimeoutStopSec=300

        [Install]
        WantedBy=sysinit.target
    - user: root
    - group: root
    - mode: '0644'

writecache_systemctl_daemon_reload:
  module.run:
    - name: service.systemctl_reload
    - onchanges:
      - file: omv-writecache-setup_service

{% if config.enable | to_bool %}

writecache_setup_service_enable:
  service.running:
    - name: omv-writecache-setup.service
    - enable: True
    - require:
      - file: omv-writecache-setup_service

{% else %}

writecache_setup_service_disable:
  service.dead:
    - name: omv-writecache-setup.service
    - enable: False

{% endif %}

{% if config.enable | to_bool and config.flush_daily | to_bool %}

omv_writecache_cron:
  file.managed:
    - name: /etc/cron.d/omv-writecache
    - user: root
    - group: root
    - mode: 0644
    - contents: |
        {{ pillar['headers']['auto_generated'] }}
        {{ pillar['headers']['warning'] }}
{%- if config.rotate_on_daily_flush | to_bool %}
        {{ config.minute }} {{ config.hour }} * * * root /usr/sbin/omv-writecache rotateflush >/dev/null 2>&1
{%- else %}
        {{ config.minute }} {{ config.hour }} * * * root /usr/sbin/omv-writecache flush >/dev/null 2>&1
{%- endif %}

{% else %}

remove_writecache_cron:
  file.absent:
    - name: /etc/cron.d/omv-writecache

{% endif %}
