#!/bin/bash
# Milestone checks. Usage: ./checks/check.sh M0   (or M1)
# Paste the output in your group's NOTES.md at the end of each session.
cd "$(dirname "$0")/.." && . ./env.sh >/dev/null
G=${GROUP:?set GROUP first, e.g. export GROUP=g07}
ok(){ if [ "$2" = 1 ]; then echo "PASS $1"; else echo "FAIL $1"; fi; }
q(){ aws "$@" 2>/dev/null; }
case "$1" in
M0)
  ok "M0 Floci reachable" $(q sts get-caller-identity >/dev/null && echo 1)
  N=$(q iam list-users --query "length(Users[?starts_with(UserName,'$G-')])"); ok "M0 one IAM user per member (found ${N:-0})" $([ "${N:-0}" -ge 3 ] && echo 1)
  ok "M0 read-only auditor user exists" $(q iam get-user --user-name $G-auditor >/dev/null && echo 1)
  ok "M0 auditor denied proof saved in NOTES.md" $(grep -q -E "AccessDenied|UnauthorizedOperation" NOTES.md 2>/dev/null && echo 1)
  ok "M0 group bucket exists" $(q s3api list-buckets --query "Buckets[?Name=='$G-site'].Name" --output text | grep -q . && echo 1)
  ;;
M1)
  ok "M1 app image in ECR" $([ "$(q ecr list-images --repository-name $G-app --query 'length(imageIds)')" -ge 1 ] 2>/dev/null && echo 1)
  R=$(q ecs describe-services --cluster $G --services $G-app --query 'services[0].runningCount'); ok "M1 ECS service running (${R:-0} task)" $([ "${R:-0}" -ge 1 ] && echo 1)
  DNS=$(q elbv2 describe-load-balancers --names $G-alb --query 'LoadBalancers[0].DNSName' --output text)
  ok "M1 ALB answers 200" $([ "$(curl -s -m5 -o /dev/null -w '%{http_code}' http://$DNS/)" = 200 ] && echo 1)
  ok "M1 RDS Postgres available" $([ "$(q rds describe-db-instances --db-instance-identifier $G-db --query 'DBInstances[0].DBInstanceStatus' --output text)" = available ] && echo 1)
  ok "M1 S3 status page online" $(curl -s -m5 -o /dev/null -w '%{http_code}' http://$G-site.s3-website-us-east-1.localhost:4566/ | grep -q 200 && echo 1)
  ok "M1 infra/deploy.sh committed" $(git ls-files --error-unmatch infra/deploy.sh >/dev/null 2>&1 && echo 1)
  ;;
*) echo "usage: $0 M0|M1"; exit 1 ;;
esac
