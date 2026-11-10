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

stage=/tmp/fan-daemon-deploy
ssh -n "${ssh_opts[@]}" "root@$host" "rm -rf $stage && mkdir -m 700 $stage"
scp -q "${ssh_opts[@]}" fan-daemon.sh fan-boost fan-vzdump-hook systemd/fan-daemon.service \
  systemd/fan-preboost.service systemd/fan-preboost.timer "$conf" "root@$host:$stage/"
ssh -n "${ssh_opts[@]}" "root@$host" "
  set -e
  cd $stage
  install -m 755 fan-daemon.sh /usr/local/sbin/fan-daemon.sh
  install -m 755 fan-boost /usr/local/sbin/fan-boost
  install -m 755 fan-vzdump-hook /usr/local/sbin/fan-vzdump-hook
  install -m 644 fan-daemon.service fan-preboost.service fan-preboost.timer /etc/systemd/system/
  install -m 644 $board.conf /etc/default/fan-daemon
  printf 'it87\ndrivetemp\n' > /etc/modules-load.d/fan-daemon.conf
  cd / && rm -rf $stage

  # vzdump allows a single hook script: never replace someone else's.
  hook=\$(sed -n 's/^script:[[:space:]]*//p' /etc/vzdump.conf)
  if [ -z \"\$hook\" ]; then
    echo 'script: /usr/local/sbin/fan-vzdump-hook' >> /etc/vzdump.conf
  elif [ \"\$hook\" != /usr/local/sbin/fan-vzdump-hook ]; then
    echo \"WARNING: vzdump already uses \$hook, backup boost not installed\" >&2
  fi

  modprobe it87
  modprobe drivetemp
  systemctl daemon-reload
  systemctl enable --now fan-preboost.timer
  systemctl enable fan-daemon.service
  systemctl restart fan-daemon.service
  sleep 3
  systemctl is-active fan-daemon.service
  journalctl -u fan-daemon.service -n 3 --no-pager -o cat
"
