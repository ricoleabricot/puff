#!/bin/bash
# Launches a throwaway "intruder" container inside your private subnets, in a
# security group nobody trusts, and tries to open your app (port 80) and your
# database (port 5432) directly, without going through the load balancer.
# Prints REACHED or BLOCKED for each. Usage: ./checks/intruder.sh
cd "$(dirname "$0")/.." && . ./env.sh >/dev/null
G=${GROUP:?export GROUP=gXX first}
q(){ aws "$@" 2>/dev/null; }

VPC=$(q ec2 describe-vpcs --filters Name=tag:Name,Values=$G-vpc --query 'Vpcs[0].VpcId' --output text)
[ -z "$VPC" ] || [ "$VPC" = None ] && { echo "no VPC tagged Name=$G-vpc"; exit 1; }
SVC=$(q ecs list-services --cluster $G --query 'serviceArns[-1]' --output text); SVC=${SVC##*/}
TASK=$(q ecs list-tasks --cluster $G --service-name $SVC --query 'taskArns[0]' --output text); TASK=${TASK##*/}
SUBNET=$(q ecs describe-services --cluster $G --services $SVC --query 'services[0].networkConfiguration.awsvpcConfiguration.subnets[0]' --output text)

# The app container's real address on your machine (Floci runs it in Docker)
APP_IP=$(docker inspect floci-aws-sg-$TASK -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null | awk '{print $1}')
read DB_HOST DB_PORT < <(q rds describe-db-instances --query "DBInstances[?starts_with(DBInstanceIdentifier,'$G-db')]|[-1].Endpoint.[Address,Port]" --output text)

SG=$(q ec2 describe-security-groups --filters Name=group-name,Values=$G-intruder-sg Name=vpc-id,Values=$VPC --query 'SecurityGroups[0].GroupId' --output text)
[ -z "$SG" ] || [ "$SG" = None ] && SG=$(q ec2 create-security-group --group-name $G-intruder-sg --description "trusted by nobody" --vpc-id $VPC --query GroupId --output text)

q ecs register-task-definition --family $G-intruder --network-mode awsvpc --requires-compatibilities FARGATE --cpu 256 --memory 512 \
  --container-definitions "[{\"name\":\"x\",\"image\":\"alpine:3.20\",\"entryPoint\":[\"sh\",\"-c\"],\"command\":[\"sleep 3; nc -z -w3 $APP_IP 80 && echo APP_REACHED || echo APP_BLOCKED; nc -z -w3 $DB_HOST $DB_PORT && echo DB_REACHED || echo DB_BLOCKED; sleep 30\"]}]" >/dev/null
T=$(q ecs run-task --cluster $G --task-definition $G-intruder --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET],securityGroups=[$SG]}" --query 'tasks[0].taskArns' --output text)
T=$(q ecs list-tasks --cluster $G --family $G-intruder --query 'taskArns[-1]' --output text); T=${T##*/}
for i in $(seq 1 20); do OUT=$(docker logs floci-aws-ecs-$T-x 2>&1 | grep -E 'REACHED|BLOCKED'); [ $(echo "$OUT" | grep -c .) -ge 2 ] && break; sleep 2; done
echo "intruder -> app $APP_IP:80        : $(echo "$OUT" | grep -o 'APP_[A-Z]*' | sed 's/APP_//')"
echo "intruder -> db  $DB_HOST:$DB_PORT : $(echo "$OUT" | grep -o 'DB_[A-Z]*' | sed 's/DB_//')"
