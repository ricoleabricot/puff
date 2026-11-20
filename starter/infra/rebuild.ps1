# Windows version of rebuild.sh. Rebuilds your whole platform from zero: .\infra\rebuild.ps1
# Network and app come from CloudFormation, the rest (pager, autoscaler, CDN)
# from the same commands you typed in M3 and M4.
$ErrorActionPreference = 'Continue'
Set-Location (Split-Path $PSScriptRoot -Parent)
. .\env.ps1 | Out-Null
$G = $env:GROUP
if (-not $G) { Write-Host 'set GROUP first, e.g. $env:GROUP = "g07"'; exit 1 }
$appRepo = if ($env:APP_REPO) { $env:APP_REPO } else { 'https://github.com/traefik/whoami.git' }
$start = Get-Date
function aws2 { & aws @args; if ($LASTEXITCODE -ne 0) { throw "aws $($args -join ' ') failed" } }
function out($stack, $key) { aws cloudformation describe-stacks --stack-name $stack --query "Stacks[0].Outputs[?OutputKey=='$key'].OutputValue" --output text }
function jsonfile($name, $text) { $p = Join-Path ([IO.Path]::GetTempPath()) "$G-$name.json"; [IO.File]::WriteAllText($p, $text); "file://$p" }

Write-Host "1/6 image"
aws ecr create-repository --repository-name "$G-app" 2>$null | Out-Null
if (-not (Test-Path app-src)) { git clone -q --depth 1 $appRepo app-src }
docker build -q -t "$env:REGISTRY/$G-app:v1" app-src | Out-Null
docker push -q "$env:REGISTRY/$G-app:v1" | Out-Null

Write-Host "2/6 network stack"
aws2 cloudformation deploy --stack-name "$G-network" --template-file infra/network.yaml --parameter-overrides "NamePrefix=$G" --tags "Project=$G"

Write-Host "3/6 app stack"
aws2 cloudformation deploy --stack-name "$G-app" --template-file infra/app.yaml --capabilities CAPABILITY_NAMED_IAM `
  --tags "Project=$G" --parameter-overrides "NamePrefix=$G" "Image=$env:REGISTRY/$G-app:v1" `
  "VpcId=$(out "$G-network" VpcId)" `
  "PublicSubnetIds=$(out "$G-network" PublicSubnetIds)" "PrivateSubnetIds=$(out "$G-network" PrivateSubnetIds)" `
  "AlbSecurityGroupId=$(out "$G-network" AlbSecurityGroupId)" "AppSecurityGroupId=$(out "$G-network" ApiSecurityGroupId)" `
  "DbSecurityGroupId=$(out "$G-network" DbSecurityGroupId)"

Write-Host "4/6 pager (M3)"
$topic = aws sns create-topic --name "$G-alerts" --query TopicArn --output text
$pager = aws sqs create-queue --queue-name "$G-pager" --query QueueUrl --output text
$pagerArn = aws sqs get-queue-attributes --queue-url $pager --attribute-names QueueArn --query Attributes.QueueArn --output text
aws sns subscribe --topic-arn $topic --protocol sqs --notification-endpoint $pagerArn | Out-Null
aws2 cloudwatch put-metric-alarm --alarm-name "$G-errors" --namespace $G --metric-name Errors --statistic Sum `
  --period 60 --evaluation-periods 1 --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold --alarm-actions $topic

Write-Host "5/6 autoscaler (M4)"
$zip = Join-Path ([IO.Path]::GetTempPath()) "$G-scaler.zip"
Compress-Archive -Path infra/scaler.py -DestinationPath $zip -Force
$trust = jsonfile 'scaler-trust' '{"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Principal": {"Service": ["lambda.amazonaws.com", "scheduler.amazonaws.com"]}, "Action": "sts:AssumeRole"}]}'
aws2 iam create-role --role-name "$G-scaler-role" --assume-role-policy-document $trust | Out-Null
$policy = jsonfile 'scaler-policy' ('{"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": ["ecs:DescribeServices", "ecs:UpdateService"], "Resource": "arn:aws:ecs:us-east-1:000000000000:service/' + $G + '/' + $G + '-app2"}, {"Effect": "Allow", "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "lambda:InvokeFunction"], "Resource": "*"}]}')
aws2 iam put-role-policy --role-name "$G-scaler-role" --policy-name scale-one-service --policy-document $policy
$scaler = aws lambda create-function --function-name "$G-scaler" --runtime python3.12 --handler scaler.handler `
  --zip-file "fileb://$zip" --role "arn:aws:iam::000000000000:role/$G-scaler-role" `
  --environment "Variables={CLUSTER=$G,SERVICE=$G-app2,MIN=2,MAX=4}" --query FunctionArn --output text
$scaleTopic = aws sns create-topic --name "$G-scale" --query TopicArn --output text
aws sns subscribe --topic-arn $scaleTopic --protocol lambda --notification-endpoint $scaler | Out-Null
aws lambda add-permission --function-name "$G-scaler" --statement-id from-sns --action lambda:InvokeFunction `
  --principal sns.amazonaws.com --source-arn $scaleTopic | Out-Null
aws2 cloudwatch put-metric-alarm --alarm-name "$G-load-high" --namespace $G --metric-name Load --statistic Average `
  --period 60 --evaluation-periods 1 --threshold 70 --comparison-operator GreaterThanThreshold `
  --alarm-actions $scaleTopic --ok-actions $scaleTopic

Write-Host "6/6 status page + CDN"
aws s3api create-bucket --bucket "$G-site" | Out-Null
$page = Join-Path ([IO.Path]::GetTempPath()) "$G-index.html"
[IO.File]::WriteAllText($page, "<h1>$G is up</h1>")
aws s3 cp $page "s3://$G-site/index.html" --content-type text/html | Out-Null
aws2 s3 website "s3://$G-site/" --index-document index.html
aws2 s3api delete-public-access-block --bucket "$G-site"
$bucketPolicy = jsonfile 'site-policy' ('{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::' + $G + '-site/*"}]}')
aws2 s3api put-bucket-policy --bucket "$G-site" --policy $bucketPolicy
aws cloudfront create-distribution --origin-domain-name "$G-site.s3.amazonaws.com" --default-root-object index.html | Out-Null

$secs = [int]((Get-Date) - $start).TotalSeconds
Write-Output "Rebuilt in $secs s. App: http://$(out "$G-app" AlbDns)/"
