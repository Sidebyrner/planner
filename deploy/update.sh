#!/usr/bin/env bash
# Pull, rebuild and restart Planner. Run as root inside the container:
#   /opt/planner/deploy/update.sh
set -euo pipefail

cd /opt/planner
as_planner() { runuser -u planner -- env HOME=/opt/planner "$@"; }

before=$(as_planner git rev-parse --short HEAD)
as_planner git pull --ff-only
after=$(as_planner git rev-parse --short HEAD)
echo "planner: ${before} -> ${after}"

as_planner npm ci
as_planner npm run build

if ! cmp -s deploy/planner.service /etc/systemd/system/planner.service; then
  install -m 644 deploy/planner.service /etc/systemd/system/planner.service
  systemctl daemon-reload
  echo "planner: systemd unit updated"
fi

systemctl restart planner
sleep 2
systemctl --no-pager --lines=5 status planner
