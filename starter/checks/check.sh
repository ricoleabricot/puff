#!/bin/bash
# Milestone checks. Usage: ./checks/check.sh M0   (or M1 to M5)
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
M2)
  VPC=$(q ec2 describe-vpcs --filters Name=tag:Name,Values=$G-vpc --query 'Vpcs[0].VpcId' --output text)
  ok "M2 VPC $G-vpc exists" $([ -n "$VPC" ] && [ "$VPC" != None ] && echo 1)
  PUB=$(q ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC --query "RouteTables[?Routes[?starts_with(GatewayId||'','igw-')]].Associations[].SubnetId" --output text)
  PRIV=$(q ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC --query "RouteTables[?Routes[?NatGatewayId]].Associations[].SubnetId" --output text)
  ok "M2 2 public subnets (route to IGW)" $([ $(echo $PUB | wc -w) -ge 2 ] && echo 1)
  ok "M2 2 private subnets (route to NAT)" $([ $(echo $PRIV | wc -w) -ge 2 ] && echo 1)
  ALB=$(q elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='$VPC']|[0].[DNSName,LoadBalancerArn]" --output text); DNS=${ALB%%[[:space:]]*}
  AZS=$(q elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='$VPC']|[0].AvailabilityZones[].SubnetId" --output text)
  ok "M2 ALB in the public subnets" $(for s in $AZS; do echo "$PUB" | grep -qw $s || exit; done; [ -n "$AZS" ] && echo 1)
  ok "M2 ALB answers 200" $([ "$(curl -s -m5 -o /dev/null -w '%{http_code}' http://$DNS/)" = 200 ] && echo 1)
  SVC=$(q ecs list-services --cluster $G --output text --query 'serviceArns[]' | tr '\t' '\n' | sed 's#.*/##' | while read s; do n=$(q ecs describe-services --cluster $G --services $s --query 'services[0].networkConfiguration.awsvpcConfiguration.subnets[0]' --output text); echo "$PRIV" | grep -qw "$n" && echo $s; done | head -1)
  ok "M2 app service in the private subnets" $([ -n "$SVC" ] && echo 1)
  ok "M2 app tasks without public IP" $([ "$(q ecs describe-services --cluster $G --services $SVC --query 'services[0].networkConfiguration.awsvpcConfiguration.assignPublicIp' --output text)" = DISABLED ] && echo 1)
  APPSG=$(q ecs describe-services --cluster $G --services $SVC --query 'services[0].networkConfiguration.awsvpcConfiguration.securityGroups[0]' --output text)
  ok "M2 app security group not open to 0.0.0.0/0" $([ -n "$APPSG" ] && [ "$(q ec2 describe-security-groups --group-ids $APPSG --query "length(SecurityGroups[0].IpPermissions[?IpRanges[?CidrIp=='0.0.0.0/0']])")" = 0 ] && echo 1)
  DB=$(q rds describe-db-instances --query "DBInstances[?DBSubnetGroup.VpcId=='$VPC']|[0].[DBInstanceIdentifier,PubliclyAccessible]" --output text)
  ok "M2 database in the VPC, not public" $(echo "$DB" | grep -q False && echo 1)
  DBSG=$(q rds describe-db-instances --db-instance-identifier ${DB%%[[:space:]]*} --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text)
  ok "M2 database only reachable from the app's group" $([ "$(q ec2 describe-security-groups --group-ids $DBSG --query 'SecurityGroups[0].IpPermissions[0].UserIdGroupPairs[0].GroupId' --output text)" = "$APPSG" ] && [ "$(q ec2 describe-security-groups --group-ids $DBSG --query 'length(SecurityGroups[0].IpPermissions[].IpRanges[])')" = 0 ] && echo 1)
  I=$(./checks/intruder.sh 2>/dev/null | grep app); ok "M2 intruder blocked from the app" $(echo "$I" | grep -q BLOCKED && echo 1)
  ok "M2 naive deploy deleted (no public DB, no service outside the VPC)" $([ "$(q rds describe-db-instances --query 'length(DBInstances[?PubliclyAccessible])')" = 0 ] && [ "$(q ecs list-services --cluster $G --query 'length(serviceArns)')" = 1 ] && echo 1)
  ;;
M3)
  ok "M3 secret $G/db-password exists" $(q secretsmanager describe-secret --secret-id $G/db-password >/dev/null && echo 1)
  VPC=$(q ec2 describe-vpcs --filters Name=tag:Name,Values=$G-vpc --query 'Vpcs[0].VpcId' --output text)
  SVC=$(q ecs list-services --cluster $G --query 'serviceArns[-1]' --output text); SVC=${SVC##*/}
  TD=$(q ecs describe-services --cluster $G --services $SVC --query 'services[0].taskDefinition' --output text)
  C="q ecs describe-task-definition --task-definition $TD --query taskDefinition"
  ok "M3 the running task gets the password from Secrets Manager" $($C.containerDefinitions[0].secrets[0].valueFrom --output text | grep -q ':secretsmanager:' && echo 1)
  ok "M3 no password in clear in the task definition" $([ -z "$($C.containerDefinitions[0].environment --output text | grep -i -E 'pass|secret')" ] && echo 1)
  ok "M3 an execution role, not admin" $(R=$($C.executionRoleArn --output text); [ -n "$R" ] && [ "$R" != None ] && ! q iam list-attached-role-policies --role-name ${R##*/} --output text | grep -q AdministratorAccess && echo 1)
  LG=$($C.containerDefinitions[0].logConfiguration.options.\"awslogs-group\" --output text)
  ok "M3 app logs land in CloudWatch ($LG)" $([ "$(q logs describe-log-streams --log-group-name "$LG" --query 'length(logStreams)')" -ge 1 ] 2>/dev/null && echo 1)
  T=$(q sns list-topics --query "Topics[?ends_with(TopicArn,':$G-alerts')].TopicArn" --output text)
  ok "M3 an alarm pages the $G-alerts topic" $([ -n "$T" ] && [ "$(q cloudwatch describe-alarms --query "length(MetricAlarms[?contains(AlarmActions,'$T')])")" -ge 1 ] && echo 1)
  ok "M3 the topic delivers to an SQS pager" $([ -n "$T" ] && q sns list-subscriptions-by-topic --topic-arn $T --query 'Subscriptions[].Protocol' --output text | grep -q sqs && echo 1)
  ok "M3 a paged alarm saved in NOTES.md" $(grep -q 'ALARM' NOTES.md 2>/dev/null && echo 1)
  P=$(q iam get-role-policy --role-name $G-deployer --policy-name deploy-only --query PolicyDocument --output json)
  ok "M3 deployer role without wildcard actions" $([ -n "$P" ] && ! echo "$P" | grep -q -E '"Action": *"\*"|"\*:\*"' && echo 1)
  ok "M3 deployer AccessDenied proof saved in NOTES.md" $(grep -A2 -i deployer NOTES.md 2>/dev/null | grep -q -E 'AccessDenied|not authorized' && echo 1)
  ok "M3 no password left in your current scripts" $(! git grep -q -E "ChangeMe|master-user-password '" HEAD -- infra 2>/dev/null && echo 1)
  ;;
M4)
  SVC=$(q ecs list-services --cluster $G --query 'serviceArns[-1]' --output text); SVC=${SVC##*/}
  read D R < <(q ecs describe-services --cluster $G --services $SVC --query 'services[0].[desiredCount,runningCount]' --output text)
  ok "M4 at least 2 containers running ($R)" $([ "${R:-0}" -ge 2 ] && echo 1)
  NETS=$(q ecs describe-services --cluster $G --services $SVC --query 'services[0].networkConfiguration.awsvpcConfiguration.subnets' --output text)
  ok "M4 the service spans 2 Availability Zones" $([ "$(q ec2 describe-subnets --subnet-ids $NETS --query 'Subnets[].AvailabilityZone' --output text | tr '\t' '\n' | sort -u | wc -l)" -ge 2 ] && echo 1)
  VPC=$(q ec2 describe-vpcs --filters Name=tag:Name,Values=$G-vpc --query 'Vpcs[0].VpcId' --output text)
  DNS=$(q elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='$VPC']|[0].DNSName" --output text)
  ok "M4 the load balancer answers 200" $([ "$(curl -s -m5 -o /dev/null -w '%{http_code}' http://$DNS/)" = 200 ] && echo 1)
  FN=$(q lambda get-function --function-name $G-scaler --query 'Configuration.[FunctionArn,Role]' --output text)
  ok "M4 your autoscaler function exists" $([ -n "$FN" ] && echo 1)
  RN=$(echo "$FN" | awk '{print $2}'); RN=${RN##*/}
  ok "M4 its role can scale your service only" $([ -n "$RN" ] && ! q iam list-attached-role-policies --role-name $RN --output text | grep -q AdministratorAccess && q iam list-role-policies --role-name $RN --query 'PolicyNames[0]' --output text | xargs -I{} aws iam get-role-policy --role-name $RN --policy-name {} --query PolicyDocument --output json 2>/dev/null | grep -q "service/$G/" && echo 1)
  FA=$(echo "$FN" | awk '{print $1}')
  WIRED=$(q cloudwatch describe-alarms --query 'MetricAlarms[].AlarmActions[]' --output text | tr '\t' '\n' | sort -u | while read t; do q sns list-subscriptions-by-topic --topic-arn $t --query 'Subscriptions[].Endpoint' --output text | grep -q "$FA" && echo $t; done)
  ok "M4 an alarm calls your autoscaler" $([ -n "$WIRED" ] && echo 1)
  LOG=$(q logs filter-log-events --log-group-name /aws/lambda/$G-scaler --query 'events[].message' --output text | grep -o -E '[0-9]+ -> [0-9]+')
  ok "M4 your autoscaler scaled out" $(echo "$LOG" | awk '$1<$3{f=1} END{exit !f}' && echo 1)
  ok "M4 your autoscaler scaled back in" $(echo "$LOG" | awk '$1>$3{f=1} END{exit !f}' && echo 1)
  CF=$(q cloudfront list-distributions --query "DistributionList.Items[?contains(Origins.Items[0].DomainName,'$G-site')]|[0].Id" --output text)
  ok "M4 CloudFront serves your status page" $([ -n "$CF" ] && [ "$CF" != None ] && [ "$(curl -s -m5 -o /dev/null -w '%{http_code}' http://$CF.cloudfront.localhost.floci.io:4566/)" = 200 ] && echo 1)
  ok "M4 your twist is designed in NOTES.md" $([ "$(sed -n '/^## Twist/,/^## /p' NOTES.md 2>/dev/null | grep -c .)" -ge 4 ] && echo 1)
  ;;
M5)
  for s in network app; do ST=$(q cloudformation describe-stacks --stack-name $G-$s --query 'Stacks[0].StackStatus' --output text)
    ok "M5 stack $G-$s is deployed ($ST)" $(echo "$ST" | grep -q -E '^(CREATE|UPDATE)_COMPLETE$' && echo 1); done
  RES=$(q cloudformation list-stack-resources --stack-name $G-network --query 'StackResourceSummaries[].ResourceType' --output text; q cloudformation list-stack-resources --stack-name $G-app --query 'StackResourceSummaries[].ResourceType' --output text)
  for r in AWS::EC2::VPC AWS::ElasticLoadBalancingV2::LoadBalancer AWS::ECS::Service AWS::RDS::DBInstance AWS::SecretsManager::Secret; do
    ok "M5 $r comes from your templates" $(echo "$RES" | grep -q "$r" && echo 1); done
  ok "M5 your stacks are tagged Project=$G" $(q cloudformation describe-stacks --stack-name $G-app --query "Stacks[0].Tags[?Key=='Project'].Value" --output text | grep -qx "$G" && echo 1)
  DNS=$(q cloudformation describe-stacks --stack-name $G-app --query "Stacks[0].Outputs[?OutputKey=='AlbDns'].OutputValue" --output text)
  ok "M5 the rebuilt app answers 200" $([ "$(curl -s -m5 -o /dev/null -w '%{http_code}' http://$DNS/)" = 200 ] && echo 1)
  ok "M5 infra/rebuild.sh and templates committed" $(git ls-files --error-unmatch infra/rebuild.sh infra/network.yaml infra/app.yaml >/dev/null 2>&1 && echo 1)
  ok "M5 a rebuild from zero is recorded in NOTES.md" $(grep -q -E 'Rebuilt in [0-9]+ s' NOTES.md 2>/dev/null && echo 1)
  ok "M5 your twist is built (a 'Built:' line under ## Twist)" $(sed -n '/^## Twist/,/^## /p' NOTES.md 2>/dev/null | grep -q -i '^- *built:' && echo 1)
  ;;
*) echo "usage: $0 M0|M1|M2|M3|M4|M5"; exit 1 ;;
esac
