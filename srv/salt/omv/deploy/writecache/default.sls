# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2025-2026 openmediavault plugin developers
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

{% set enabled = config.enable | to_bool %}
{% set use_tmpfs = (config.use_tmpfs | to_bool) or (config.sharedfolderref == '') %}
{% set tmpfs_size = config.tmpfs_size %}
{% if use_tmpfs and (tmpfs_size in ['', '0%']) %}
{%   set tmpfs_size = '25%' %}
{% elif not use_tmpfs %}
{%   set tmpfs_size = '0%' %}
{% endif %}

{% set workspace_type = 'tmpfs' if use_tmpfs else 'path' %}
{% set workspace_root = '' if use_tmpfs else salt['omv_conf.get_sharedfolder_path'](config.sharedfolderref) %}

{% set shutdown_action = None %}
{% if config.flush_on_shutdown | to_bool %}
{%   set shutdown_action = 'rotateunmount' if (config.rotate_on_shutdown | to_bool) else 'unmount' %}
{% endif %}

{% set daily_action = None %}
{% if enabled and (config.flush_daily | to_bool) %}
{%   set daily_action = 'rotateflush' if (config.rotate_on_daily_flush | to_bool) else 'flush' %}
{% endif %}

{% set unit_after  = 'systemd-remount-fs.service local-fs-pre.target' ~ (' tmp.mount' if use_tmpfs else '') %}
{% set unit_before = 'local-fs.target systemd-journald.service postfix@-.service' ~ (' systemd-tmpfiles-setup.service' if use_tmpfs else '') %}


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
    - name: /etc/omv-writecache
    - user: root
    - group: root
    - mode: 0755

configure_writecache_config:
  file.managed:
    - name: /etc/omv-writecache/config.yaml
    - contents: |
        {{ pillar['headers']['auto_generated'] }}
        {{ pillar['headers']['warning'] }}
        enable: {{ enabled }}
        workspace_type: {{ workspace_type }}
        workspace_root: "{{ workspace_root }}"
        tmpfs_size: "{{ tmpfs_size }}"
        journald_storage: "{{ config.journald_storage }}"
        flush_on_boot: {{ config.flush_on_boot | to_bool }}
        flush_on_shutdown: {{ config.flush_on_shutdown | to_bool }}
        flush_daily: {{ config.flush_daily | to_bool }}
        paths: |
{%- for p in config.get('paths', '').splitlines() if p.strip() %}
          {{ p.strip() }}
{%- endfor %}
    - user: root
    - group: root
    - mode: 0644

configure_writecache_journald_dir:
  file.directory:
    - name: /etc/systemd/journald.conf.d
    - user: root
    - group: root
    - dir_mode: 0755

configure_writecache_journald:
  file.managed:
    - name: /etc/systemd/journald.conf.d/10-writecache.conf
    - contents: |
        {{ pillar['headers']['auto_generated'] }}
        {{ pillar['headers']['warning'] }}
        [Journal]
        Storage={{ config.journald_storage }}
    - user: root
    - group: root
    - mode: 0644

{# One state is enough: reload journald when the conf changes #}
restart_journald_on_change:
  service.running:
    - name: systemd-journald
    - reload: True
    - onchanges:
      - file: configure_writecache_journald


{% if enabled %}

omv-writecache-setup_service:
  file.managed:
    - name: /etc/systemd/system/omv-writecache-setup.service
    - contents: |
        [Unit]
        Description=OMV WriteCache: overlays lifecycle
        DefaultDependencies=no
        After={{ unit_after }}
        Before={{ unit_before }}
{%- if use_tmpfs %}
        RequiresMountsFor=/var
{%- else %}
        RequiresMountsFor={{ workspace_root }}
{%- endif %}
        Conflicts=shutdown.target umount.target
        Before=shutdown.target umount.target final.target

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/sbin/omv-writecache mount
        ExecStop=/usr/sbin/omv-writecache {{ shutdown_action }}
        TimeoutStartSec=180
        TimeoutStopSec=300
        KillMode=none
        SendSIGKILL=no

        [Install]
        WantedBy=local-fs.target
    - user: root
    - group: root
    - mode: '0644'

{% else %}

omv-writecache-setup_service:
  file.absent:
    - name: /etc/systemd/system/omv-writecache-setup.service

{% endif %}

writecache_systemctl_daemon_reload:
  module.run:
    - name: service.systemctl_reload
    - onchanges:
      - file: omv-writecache-setup_service

{% if enabled %}

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


{% if daily_action %}

omv_writecache_cron:
  file.managed:
    - name: /etc/cron.d/omv-writecache
    - contents: |
        {{ pillar['headers']['auto_generated'] }}
        {{ pillar['headers']['warning'] }}
        {{ config.minute }} {{ config.hour }} * * * root /usr/sbin/omv-writecache {{ daily_action }} >/dev/null 2>&1
    - user: root
    - group: root
    - mode: 0644

{% else %}

omv_writecache_cron:
  file.absent:
    - name: /etc/cron.d/omv-writecache

{% endif %}
