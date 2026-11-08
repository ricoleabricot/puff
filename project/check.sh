#!/usr/bin/env bash
# Puff project check. Read-only: it only describes resources, it never changes anything.
# Run it in the base member's sandbox browser terminal:
#   bash check.sh <login>
# 9 items, PASS/FAIL each, score /6 = passed / 9 x 6, rounded to the nearest 0.5.

LOGIN="${1:-$LOGIN}"
if [ -z "$LOGIN" ]; then
  echo "Usage: bash check.sh <login>   (the login in your puff-frontend-<login> bucket name)"
  exit 1
fi
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""

PASSED=0
pass() { echo "PASS  $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL  $1  ($2)"; }
q() { aws "$@" 2>/dev/null; }

echo "Puff check for $LOGIN, account $(q sts get-caller-identity --query Account --output text), $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo

# Shared lookups
ALB_ARN=$(q elbv2 describe-load-balancers --names puff-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)
VPC_ID=$(q elbv2 describe-load-balancers --names puff-alb --query 'LoadBalancers[0].VpcId' --output text)
ASG_SUBNETS=$(q autoscaling describe-auto-scaling-groups --auto-scaling-group-names puff-asg \
  --query 'AutoScalingGroups[0].VPCZoneIdentifier' --output text | tr ',' ' ')
ASG_IDS=$(q autoscaling describe-auto-scaling-groups --auto-scaling-group-names puff-asg \
  --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text)
API_SG=$(q ec2 describe-security-groups --filters Name=group-name,Values=puff-api-sg Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)
TOPIC=$(q sns list-topics --query "Topics[?ends_with(TopicArn, ':puff-alerts')].TopicArn | [0]" --output text)
BUCKET="puff-frontend-$LOGIN"

# A subnet is private when its route table (or the VPC main one) has no 0.0.0.0/0 route to an internet gateway
is_private() {
  local rt
  rt=$(q ec2 describe-route-tables --filters Name=association.subnet-id,Values="$1" \
    --query 'RouteTables[0].RouteTableId' --output text)
  if [ -z "$rt" ] || [ "$rt" = "None" ]; then
    rt=$(q ec2 describe-route-tables --filters Name=vpc-id,Values="$VPC_ID" Name=association.main,Values=true \
      --query 'RouteTables[0].RouteTableId' --output text)
  fi
  [ -z "$(q ec2 describe-route-tables --route-table-ids "$rt" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0' && starts_with(GatewayId || '', 'igw-')].GatewayId" --output text)" ]
}

# 1. VPC with public and private subnets in 2 AZs
if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
  fail "1 network: VPC with public and private subnets in 2 AZs" "no load balancer named puff-alb, so no VPC to check"
else
  PUB_AZ=$(q elbv2 describe-load-balancers --names puff-alb --query 'LoadBalancers[0].AvailabilityZones[].ZoneName' --output text | wc -w | tr -d " ")
  PRIV_AZ=0; PRIV_OK=1
  if [ -n "$ASG_SUBNETS" ]; then
    PRIV_AZ=$(q ec2 describe-subnets --subnet-ids $ASG_SUBNETS --query 'Subnets[].AvailabilityZone' --output text | tr '\t' '\n' | sort -u | wc -l | tr -d " ")
    for s in $ASG_SUBNETS; do is_private "$s" || PRIV_OK=0; done
  else
    PRIV_OK=0
  fi
  if [ "$PUB_AZ" -ge 2 ] && [ "$PRIV_AZ" -ge 2 ] && [ "$PRIV_OK" = 1 ]; then
    pass "1 network: VPC with public and private subnets in 2 AZs"
  else
    fail "1 network: VPC with public and private subnets in 2 AZs" "ALB in $PUB_AZ AZ(s), ASG in $PRIV_AZ AZ(s), ASG subnets private: $([ $PRIV_OK = 1 ] && echo yes || echo no)"
  fi
fi

# 2. The ALB is the only public door
OPEN=$(q ec2 describe-security-groups --group-ids "$API_SG" \
  --query "SecurityGroups[0].IpPermissions[?IpRanges[?CidrIp=='0.0.0.0/0']] | length(@)" --output text)
PUB_IPS=""
[ -n "$ASG_IDS" ] && PUB_IPS=$(q ec2 describe-instances --instance-ids $ASG_IDS \
  --query 'Reservations[].Instances[].PublicIpAddress' --output text)
if [ -z "$API_SG" ] || [ "$API_SG" = "None" ]; then
  fail "2 one public door: only the ALB is reachable from the internet" "no puff-api-sg in the ALB's VPC"
elif [ "$OPEN" != "0" ] || [ -n "$PUB_IPS" ]; then
  fail "2 one public door: only the ALB is reachable from the internet" "puff-api-sg open to 0.0.0.0/0: $OPEN rule(s), API public IPs: ${PUB_IPS:-none}"
else
  pass "2 one public door: only the ALB is reachable from the internet"
fi

# 3. ASG across 2 AZs with healthy targets
ASG_AZ=$(q autoscaling describe-auto-scaling-groups --auto-scaling-group-names puff-asg \
  --query 'AutoScalingGroups[0].AvailabilityZones' --output text | wc -w | tr -d " ")
TG_ARN=$(q autoscaling describe-auto-scaling-groups --auto-scaling-group-names puff-asg \
  --query 'AutoScalingGroups[0].TargetGroupARNs[0]' --output text)
HEALTHY=0
[ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ] && HEALTHY=$(q elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query "TargetHealthDescriptions[?TargetHealth.State=='healthy'] | length(@)" --output text)
HEALTH=$(q elbv2 describe-load-balancers --names puff-alb --query 'LoadBalancers[0].DNSName' --output text \
  | xargs -I{} curl -s -m 5 http://{}/health)
if [ "$ASG_AZ" -ge 2 ] && [ "${HEALTHY:-0}" -ge 2 ] && echo "$HEALTH" | grep -q '"ok"'; then
  pass "3 servers: puff-asg in 2 AZs, healthy behind the ALB, /health answers"
else
  fail "3 servers: puff-asg in 2 AZs, healthy behind the ALB, /health answers" "$ASG_AZ AZ(s), ${HEALTHY:-0} healthy target(s), /health said: ${HEALTH:-nothing}"
fi

# 4. Database private, reachable only from the API security group
PUBLIC_DB=$(q rds describe-db-instances --db-instance-identifier puff-db --query 'DBInstances[0].PubliclyAccessible' --output text)
DB_SG=$(q rds describe-db-instances --db-instance-identifier puff-db --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text)
DB_CIDR=$(q ec2 describe-security-groups --group-ids "$DB_SG" --query 'SecurityGroups[0].IpPermissions[].IpRanges[].CidrIp' --output text)
DB_SRC=$(q ec2 describe-security-groups --group-ids "$DB_SG" --query 'SecurityGroups[0].IpPermissions[].UserIdGroupPairs[].GroupId' --output text | tr '\t' '\n' | sort -u | tr '\n' ' ' | xargs)
if [ "$PUBLIC_DB" = "False" ] && [ -z "$DB_CIDR" ] && [ -n "$API_SG" ] && [ "$DB_SRC" = "$API_SG" ]; then
  pass "4 data: puff-db not public, its security group only allows puff-api-sg"
else
  fail "4 data: puff-db not public, its security group only allows puff-api-sg" "public: ${PUBLIC_DB:-no db}, CIDR rules: ${DB_CIDR:-none}, allowed groups: ${DB_SRC:-none}"
fi

# 5. No password in plain text: SecureString, and not inside the launch template user data
PTYPE=$(q ssm get-parameter --name /puff/db/password --query 'Parameter.Type' --output text)
LEAK=0
PW=$(q ssm get-parameter --name /puff/db/password --with-decryption --query 'Parameter.Value' --output text)
UD=$(q ec2 describe-launch-template-versions --launch-template-name puff-api-lt --versions '$Latest' \
  --query 'LaunchTemplateVersions[0].LaunchTemplateData.UserData' --output text | base64 -d 2>/dev/null)
[ -n "$PW" ] && printf '%s' "$UD" | grep -qF -- "$PW" && LEAK=1
unset PW
if [ "$PTYPE" = "SecureString" ] && [ "$LEAK" = 0 ]; then
  pass "5 secrets: /puff/db/password is a SecureString, not in the user data"
else
  fail "5 secrets: /puff/db/password is a SecureString, not in the user data" "type: ${PTYPE:-missing}, password found in puff-api-lt user data: $([ $LEAK = 1 ] && echo yes || echo no)"
fi

# 6. An alarm wired to puff-alerts
ALARMS=""
[ -n "$TOPIC" ] && [ "$TOPIC" != "None" ] && ALARMS=$(q cloudwatch describe-alarms \
  --query "MetricAlarms[?contains(AlarmActions, '$TOPIC')].AlarmName" --output text)
if [ -n "$ALARMS" ]; then
  pass "6 watching: alarm(s) sending to puff-alerts: $ALARMS"
else
  fail "6 watching: an alarm sends to puff-alerts" "topic: ${TOPIC:-missing}, no alarm has it as an action"
fi

# 7. Website on S3 behind CloudFront
CF_DOMAIN=$(q cloudfront list-distributions \
  --query "DistributionList.Items[?Origins.Items[?starts_with(DomainName, '$BUCKET.')]].DomainName | [0]" --output text)
if [ -n "$CF_DOMAIN" ] && [ "$CF_DOMAIN" != "None" ] && curl -s -o /dev/null -m 5 -w '%{http_code}' "http://$CF_DOMAIN/" | grep -q '^200$'; then
  pass "7 edge: CloudFront in front of $BUCKET answers ($CF_DOMAIN)"
else
  fail "7 edge: CloudFront in front of $BUCKET answers" "distribution: ${CF_DOMAIN:-none found with that bucket as origin}"
fi

# 8. A healthy CloudFormation stack that contains a VPC
STACK=""
for s in $(q cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query 'StackSummaries[].StackName' --output text); do
  if [ -n "$(q cloudformation list-stack-resources --stack-name "$s" \
    --query "StackResourceSummaries[?ResourceType=='AWS::EC2::VPC'].PhysicalResourceId" --output text)" ]; then
    STACK="$s"; break
  fi
done
if [ -n "$STACK" ]; then
  pass "8 as code: stack $STACK is healthy and contains a VPC"
else
  fail "8 as code: a stack in CREATE_COMPLETE or UPDATE_COMPLETE contains a VPC" "none found"
fi

# 9. Project=puff tag on ALB, ASG, RDS and bucket
MISSING=""
[ "$(q elbv2 describe-tags --resource-arns "$ALB_ARN" --query "TagDescriptions[0].Tags[?Key=='Project'].Value | [0]" --output text)" = "puff" ] || MISSING="$MISSING ALB"
[ "$(q autoscaling describe-tags --filters Name=auto-scaling-group,Values=puff-asg Name=key,Values=Project --query 'Tags[0].Value' --output text)" = "puff" ] || MISSING="$MISSING ASG"
DB_ARN=$(q rds describe-db-instances --db-instance-identifier puff-db --query 'DBInstances[0].DBInstanceArn' --output text)
[ "$(q rds list-tags-for-resource --resource-name "$DB_ARN" --query "TagList[?Key=='Project'].Value | [0]" --output text)" = "puff" ] || MISSING="$MISSING RDS"
[ "$(q s3api get-bucket-tagging --bucket "$BUCKET" --query "TagSet[?Key=='Project'].Value | [0]" --output text)" = "puff" ] || MISSING="$MISSING bucket"
if [ -z "$MISSING" ]; then
  pass "9 tags: Project=puff on ALB, ASG, RDS and bucket"
else
  fail "9 tags: Project=puff on ALB, ASG, RDS and bucket" "missing on:$MISSING"
fi

echo
SCORE=$(awk -v p="$PASSED" 'BEGIN { printf "%.1f", int(p * 6 / 9 * 2 + 0.5) / 2 }')
echo "$PASSED/9 passed, standard package score: $SCORE/6"
