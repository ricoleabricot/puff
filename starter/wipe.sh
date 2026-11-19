#!/bin/bash
# Wipes your local AWS completely (all resources, all state). Keeps your code.
read -p "Delete everything in Floci? [y/N] " a; [ "$a" = y ] || exit 0
docker compose down
docker ps -aq --filter name=floci-aws | xargs -r docker rm -f >/dev/null
mv data "data-old-$(date +%s)" 2>/dev/null
docker compose up -d && echo "Clean Floci starting, wait 20 s."
