#!/bin/bash
# Checks that your machine can run the course. Everything should say OK.
ok(){ echo "OK   $1"; }; ko(){ echo "FAIL $1  ->  $2"; FAILED=1; }
docker info >/dev/null 2>&1 && ok "Docker is running" || ko "Docker is running" "start Docker Desktop (or wait 1 min in a Codespace)"
docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless && ko "Docker is not rootless" "rootless Docker is not supported, use a Codespace" || ok "Docker is not rootless"
command -v aws >/dev/null && ok "AWS CLI $(aws --version 2>&1 | cut -d' ' -f1)" || ko "AWS CLI installed" "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
command -v git >/dev/null && ok "git" || ko "git" "install git"
curl -s -o /dev/null -m3 localhost:4566 && ok "Floci answers on :4566" || ko "Floci answers on :4566" "docker compose up -d, then wait 20 s"
docker ps --format '{{.Image}}' | grep -q 'floci/floci:2.5.0' && ok "Floci 2.5.0" || ko "Floci 2.5.0" "docker compose up -d in this folder"
docker exec floci env 2>/dev/null | grep -q 'SECURITY_GROUP_ENFORCEMENT_ENABLED=true' && ok "Security groups enforced" || ko "Security groups enforced" "start Floci with this folder's docker-compose.yml"
. ./env.sh >/dev/null; aws sts get-caller-identity --query Account --output text 2>/dev/null | grep -q 000000000000 && ok "AWS CLI talks to Floci" || ko "AWS CLI talks to Floci" "run: source env.sh"
[ -z "$FAILED" ] && echo "All good, you're ready." || exit 1
