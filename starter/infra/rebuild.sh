#!/bin/bash
# Rebuilds your whole platform from zero, in one command: ./infra/rebuild.sh
# Network and app come from CloudFormation, the rest (pager, autoscaler, CDN)
# from the same CLI commands you typed in M3 and M4.
set -e
cd "$(dirname "$0")/.." && . ./env.sh
: "${GROUP:?export GROUP=gXX first}"
APP_REPO=${APP_REPO:-https://github.com/traefik/whoami.git}
START=$(date +%s)
out(){ aws cloudformation describe-stacks --stack-name $1 --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text; }

echo "1/6 image"
aws ecr create-repository --repository-name $GROUP-app >/dev/null 2>&1 || true
[ -d app-src ] || git clone -q --depth 1 $APP_REPO app-src
docker build -q -t $REGISTRY/$GROUP-app:v1 app-src >/dev/null
docker push -q $REGISTRY/$GROUP-app:v1 >/dev/null

echo "2/6 network stack"
aws cloudformation deploy --stack-name $GROUP-network --template-file infra/network.yaml \
  --parameter-overrides NamePrefix=$GROUP --tags Project=$GROUP

echo "3/6 app stack"
aws cloudformation deploy --stack-name $GROUP-app --template-file infra/app.yaml --capabilities CAPABILITY_NAMED_IAM \
  --tags Project=$GROUP --parameter-overrides NamePrefix=$GROUP Image=$REGISTRY/$GROUP-app:v1 \
  VpcId=$(out $GROUP-network VpcId) \
  PublicSubnetIds=$(out $GROUP-network PublicSubnetIds) PrivateSubnetIds=$(out $GROUP-network PrivateSubnetIds) \
  AlbSecurityGroupId=$(out $GROUP-network AlbSecurityGroupId) AppSecurityGroupId=$(out $GROUP-network ApiSecurityGroupId) \
  DbSecurityGroupId=$(out $GROUP-network DbSecurityGroupId)

echo "4/6 pager (M3)"
TOPIC=$(aws sns create-topic --name $GROUP-alerts --query TopicArn --output text)
PAGER=$(aws sqs create-queue --queue-name $GROUP-pager --query QueueUrl --output text)
aws sns subscribe --topic-arn $TOPIC --protocol sqs --notification-endpoint \
  $(aws sqs get-queue-attributes --queue-url $PAGER --attribute-names QueueArn --query Attributes.QueueArn --output text) >/dev/null
aws cloudwatch put-metric-alarm --alarm-name $GROUP-errors --namespace $GROUP --metric-name Errors --statistic Sum \
  --period 60 --evaluation-periods 1 --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold --alarm-actions $TOPIC

echo "5/6 autoscaler (M4)"
python3 -m zipfile -c /tmp/$GROUP-scaler.zip infra/scaler.py
aws iam create-role --role-name $GROUP-scaler-role --assume-role-policy-document '{"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Principal": {"Service": ["lambda.amazonaws.com", "scheduler.amazonaws.com"]}, "Action": "sts:AssumeRole"}]}' >/dev/null
aws iam put-role-policy --role-name $GROUP-scaler-role --policy-name scale-one-service --policy-document "{\"Version\": \"2012-10-17\", \"Statement\": [{\"Effect\": \"Allow\", \"Action\": [\"ecs:DescribeServices\", \"ecs:UpdateService\"], \"Resource\": \"arn:aws:ecs:us-east-1:000000000000:service/$GROUP/$GROUP-app2\"}, {\"Effect\": \"Allow\", \"Action\": [\"logs:CreateLogGroup\", \"logs:CreateLogStream\", \"logs:PutLogEvents\", \"lambda:InvokeFunction\"], \"Resource\": \"*\"}]}"
SCALER=$(aws lambda create-function --function-name $GROUP-scaler --runtime python3.12 --handler scaler.handler \
  --zip-file fileb:///tmp/$GROUP-scaler.zip --role arn:aws:iam::000000000000:role/$GROUP-scaler-role \
  --environment "Variables={CLUSTER=$GROUP,SERVICE=$GROUP-app2,MIN=2,MAX=4}" --query FunctionArn --output text)
SCALE_TOPIC=$(aws sns create-topic --name $GROUP-scale --query TopicArn --output text)
aws sns subscribe --topic-arn $SCALE_TOPIC --protocol lambda --notification-endpoint $SCALER >/dev/null
aws lambda add-permission --function-name $GROUP-scaler --statement-id from-sns --action lambda:InvokeFunction \
  --principal sns.amazonaws.com --source-arn $SCALE_TOPIC >/dev/null
aws cloudwatch put-metric-alarm --alarm-name $GROUP-load-high --namespace $GROUP --metric-name Load --statistic Average \
  --period 60 --evaluation-periods 1 --threshold 70 --comparison-operator GreaterThanThreshold \
  --alarm-actions $SCALE_TOPIC --ok-actions $SCALE_TOPIC

echo "6/6 status page + CDN"
aws s3api create-bucket --bucket $GROUP-site >/dev/null
echo "<h1>$GROUP is up</h1>" | aws s3 cp - s3://$GROUP-site/index.html --content-type text/html >/dev/null
aws s3 website s3://$GROUP-site/ --index-document index.html
aws s3api delete-public-access-block --bucket $GROUP-site
aws s3api put-bucket-policy --bucket $GROUP-site --policy "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::$GROUP-site/*\"}]}"
aws cloudfront create-distribution --origin-domain-name $GROUP-site.s3.amazonaws.com --default-root-object index.html >/dev/null

echo "Rebuilt in $(( $(date +%s) - START )) s. App: http://$(out $GROUP-app AlbDns)/"
