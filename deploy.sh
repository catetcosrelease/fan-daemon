#!/bin/bash
# Installs fan-daemon on a node: deploy.sh <host> [ssh options...]
# The configuration is chosen from the board name: config/<board_name>.conf
# Example: ./deploy.sh node.example.lan -J root@jump.example.lan
set -eu
host=$1; shift
cd "$(dirname "$0")"
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10 "$@")

board=$(ssh -n "${ssh_opts[@]}" "root@$host" cat /sys/class/dmi/id/board_name)
conf=config/$board.conf
[ -f "$conf" ] || { echo "missing $conf" >&2; exit 1; }

scp -q "${ssh_opts[@]}" fan-daemon.sh systemd/fan-daemon.service "$conf" "root@$host:/tmp/"
ssh -n "${ssh_opts[@]}" "root@$host" "
  set -e
  install -m 755 /tmp/fan-daemon.sh /usr/local/sbin/fan-daemon.sh
  install -m 644 /tmp/fan-daemon.service /etc/systemd/system/fan-daemon.service
  install -m 644 /tmp/$board.conf /etc/default/fan-daemon
  printf 'it87\ndrivetemp\n' > /etc/modules-load.d/fan-daemon.conf
  rm -f /tmp/fan-daemon.sh /tmp/fan-daemon.service /tmp/$board.conf
  modprobe it87
  modprobe drivetemp
  systemctl daemon-reload
  systemctl enable fan-daemon.service
  systemctl restart fan-daemon.service
  sleep 3
  systemctl is-active fan-daemon.service
  journalctl -u fan-daemon.service -n 3 --no-pager -o cat
"
