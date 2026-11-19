#!/bin/bash
# Your group's deploy script. Put every command you run here, in order,
# so any member can rebuild your infra from zero on their machine.
set -e
cd "$(dirname "$0")/.." && . ./env.sh
: "${GROUP:?export GROUP=gXX first}"
