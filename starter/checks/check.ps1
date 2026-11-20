# Milestone checks, Windows version. Usage: .\checks\check.ps1 M0   (or M1 to M5)
# Same lines as check.sh. Paste the output in your group's NOTES.md at the end of each session.
param([string]$M)
Set-Location (Split-Path $PSScriptRoot -Parent)
. .\env.ps1 | Out-Null
$G = $env:GROUP
if (-not $G) { Write-Host 'set GROUP first, e.g. $env:GROUP = "g07"'; exit 1 }

function ok($label, $cond) { if ($cond) { Write-Output "PASS $label" } else { Write-Output "FAIL $label" } }
function q { $out = & aws @args 2>$null; if ($LASTEXITCODE -ne 0) { return $null }; return ($out -join "`n").Trim() }
function http($url) { try { (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5).StatusCode } catch { if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 } } }
function notes { if (Test-Path NOTES.md) { Get-Content NOTES.md -Raw } else { '' } }
function section($name) {   # lines under "## Idea" (or the older "## Twist") until the next "## "
  $lines = (notes) -split "`r?`n"; $in = $false; $res = @()
  foreach ($l in $lines) { if ($l -match '^## (Idea|Twist)') { $in = $true; continue }; if ($in -and $l -match '^## ') { break }; if ($in -and $l.Trim()) { $res += $l } }
  return $res
}
function words($s) { if ($s) { @($s -split '\s+' | Where-Object { $_ }) } else { @() } }

switch ($M) {
'M0' {
  ok "M0 Floci reachable" ($null -ne (q sts get-caller-identity))
  $n = q iam list-users --query "length(Users[?starts_with(UserName,'$G-')])"
  ok "M0 one IAM user per member (found $n)" ([int]$n -ge 3)
  ok "M0 read-only auditor user exists" ($null -ne (q iam get-user --user-name "$G-auditor"))
  ok "M0 auditor denied proof saved in NOTES.md" ((notes) -match 'AccessDenied|UnauthorizedOperation')
  ok "M0 group bucket exists" ([bool](q s3api list-buckets --query "Buckets[?Name=='$G-site'].Name" --output text))
}
'M1' {
  ok "M1 app image in ECR" ([int](q ecr list-images --repository-name "$G-app" --query 'length(imageIds)') -ge 1)
  $r = q ecs describe-services --cluster $G --services "$G-app" --query 'services[0].runningCount'
  ok "M1 ECS service running ($r task)" ([int]$r -ge 1)
  $dns = q elbv2 describe-load-balancers --names "$G-alb" --query 'LoadBalancers[0].DNSName' --output text
  ok "M1 ALB answers 200" ((http "http://$dns/") -eq 200)
  ok "M1 RDS Postgres available" ((q rds describe-db-instances --db-instance-identifier "$G-db" --query 'DBInstances[0].DBInstanceStatus' --output text) -eq 'available')
  ok "M1 S3 status page online" ((http "http://$G-site.s3-website-us-east-1.localhost:4566/") -eq 200)
  git ls-files --error-unmatch infra/deploy.ps1 *> $null; $a = $LASTEXITCODE
  git ls-files --error-unmatch infra/deploy.sh *> $null; $b = $LASTEXITCODE
  ok "M1 infra/deploy script committed" (($a -eq 0) -or ($b -eq 0))
}
'M2' {
  $vpc = q ec2 describe-vpcs --filters "Name=tag:Name,Values=$G-vpc" --query 'Vpcs[0].VpcId' --output text
  ok "M2 VPC $G-vpc exists" ($vpc -and $vpc -ne 'None')
  $pub = words (q ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" --query "RouteTables[?Routes[?starts_with(GatewayId||'','igw-')]].Associations[].SubnetId" --output text)
  $priv = words (q ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" --query "RouteTables[?Routes[?NatGatewayId]].Associations[].SubnetId" --output text)
  ok "M2 2 public subnets (route to IGW)" ($pub.Count -ge 2)
  ok "M2 2 private subnets (route to NAT)" ($priv.Count -ge 2)
  $dns = q elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='$vpc']|[0].DNSName" --output text
  $azs = words (q elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='$vpc']|[0].AvailabilityZones[].SubnetId" --output text)
  ok "M2 ALB in the public subnets" ($azs.Count -gt 0 -and -not ($azs | Where-Object { $pub -notcontains $_ }))
  ok "M2 ALB answers 200" ((http "http://$dns/") -eq 200)
  $svc = $null
  foreach ($s in (words (q ecs list-services --cluster $G --query 'serviceArns[]' --output text))) {
    $name = ($s -split '/')[-1]
    $n = q ecs describe-services --cluster $G --services $name --query 'services[0].networkConfiguration.awsvpcConfiguration.subnets[0]' --output text
    if ($priv -contains $n) { $svc = $name; break }
  }
  ok "M2 app service in the private subnets" ([bool]$svc)
  ok "M2 app tasks without public IP" ((q ecs describe-services --cluster $G --services $svc --query 'services[0].networkConfiguration.awsvpcConfiguration.assignPublicIp' --output text) -eq 'DISABLED')
  $appsg = q ecs describe-services --cluster $G --services $svc --query 'services[0].networkConfiguration.awsvpcConfiguration.securityGroups[0]' --output text
  ok "M2 app security group not open to 0.0.0.0/0" ($appsg -and (q ec2 describe-security-groups --group-ids $appsg --query "length(SecurityGroups[0].IpPermissions[?IpRanges[?CidrIp=='0.0.0.0/0']])") -eq '0')
  $db = q rds describe-db-instances --query "DBInstances[?DBSubnetGroup.VpcId=='$vpc']|[0].[DBInstanceIdentifier,PubliclyAccessible]" --output text
  ok "M2 database in the VPC, not public" ($db -match 'False')
  $dbid = (words $db)[0]
  $dbsg = q rds describe-db-instances --db-instance-identifier $dbid --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text
  ok "M2 database only reachable from the app's group" (((q ec2 describe-security-groups --group-ids $dbsg --query 'SecurityGroups[0].IpPermissions[0].UserIdGroupPairs[0].GroupId' --output text) -eq $appsg) -and ((q ec2 describe-security-groups --group-ids $dbsg --query 'length(SecurityGroups[0].IpPermissions[].IpRanges[])') -eq '0'))
  $i = & "$PSScriptRoot\intruder.ps1" 2>$null | Where-Object { $_ -match 'app' }
  ok "M2 intruder blocked from the app" ("$i" -match 'BLOCKED')
  ok "M2 naive deploy deleted (no public DB, no service outside the VPC)" (((q rds describe-db-instances --query 'length(DBInstances[?PubliclyAccessible])') -eq '0') -and ((q ecs list-services --cluster $G --query 'length(serviceArns)') -eq '1'))
}
'M3' {
  ok "M3 secret $G/db-password exists" ($null -ne (q secretsmanager describe-secret --secret-id "$G/db-password"))
  $svc = ((q ecs list-services --cluster $G --query 'serviceArns[-1]' --output text) -split '/')[-1]
  $td = q ecs describe-services --cluster $G --services $svc --query 'services[0].taskDefinition' --output text
  $def = q ecs describe-task-definition --task-definition $td --query taskDefinition --output json | ConvertFrom-Json
  $c = $def.containerDefinitions[0]
  ok "M3 the running task gets the password from Secrets Manager" ("$($c.secrets[0].valueFrom)" -match ':secretsmanager:')
  ok "M3 no password in clear in the task definition" (-not ($c.environment | Where-Object { "$($_.name)" -match '(?i)pass|secret' }))
  $role = ("$($def.executionRoleArn)" -split '/')[-1]
  ok "M3 an execution role, not admin" ($role -and -not ((q iam list-attached-role-policies --role-name $role --output text) -match 'AdministratorAccess'))
  $lg = $c.logConfiguration.options.'awslogs-group'
  ok "M3 app logs land in CloudWatch ($lg)" ($lg -and [int](q logs describe-log-streams --log-group-name $lg --query 'length(logStreams)') -ge 1)
  $t = q sns list-topics --query "Topics[?ends_with(TopicArn,':$G-alerts')].TopicArn" --output text
  ok "M3 an alarm pages the $G-alerts topic" ($t -and [int](q cloudwatch describe-alarms --query "length(MetricAlarms[?contains(AlarmActions,'$t')])") -ge 1)
  ok "M3 the topic delivers to an SQS pager" ($t -and ((q sns list-subscriptions-by-topic --topic-arn $t --query 'Subscriptions[].Protocol' --output text) -match 'sqs'))
  ok "M3 a paged alarm saved in NOTES.md" ((notes) -match 'ALARM')
  $p = q iam get-role-policy --role-name "$G-deployer" --policy-name deploy-only --query PolicyDocument --output json
  ok "M3 deployer role without wildcard actions" ($p -and -not ($p -match '"Action":\s*"\*"|"\*:\*"'))
  ok "M3 deployer AccessDenied proof saved in NOTES.md" ((notes) -match '(?is)deployer.{0,400}(AccessDenied|not authorized)')
  git grep -q -E "ChangeMe|master-user-password '" HEAD -- infra *> $null
  ok "M3 no password left in your current scripts" ($LASTEXITCODE -ne 0)
}
'M4' {
  $svc = ((q ecs list-services --cluster $G --query 'serviceArns[-1]' --output text) -split '/')[-1]
  $r = q ecs describe-services --cluster $G --services $svc --query 'services[0].runningCount'
  ok "M4 at least 2 containers running ($r)" ([int]$r -ge 2)
  $nets = words (q ecs describe-services --cluster $G --services $svc --query 'services[0].networkConfiguration.awsvpcConfiguration.subnets' --output text)
  $zones = @(words (q ec2 describe-subnets --subnet-ids @nets --query 'Subnets[].AvailabilityZone' --output text) | Sort-Object -Unique)
  ok "M4 the service spans 2 Availability Zones" ($zones.Count -ge 2)
  $vpc = q ec2 describe-vpcs --filters "Name=tag:Name,Values=$G-vpc" --query 'Vpcs[0].VpcId' --output text
  $dns = q elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='$vpc']|[0].DNSName" --output text
  ok "M4 the load balancer answers 200" ((http "http://$dns/") -eq 200)
  $fn = words (q lambda get-function --function-name "$G-scaler" --query 'Configuration.[FunctionArn,Role]' --output text)
  ok "M4 your autoscaler function exists" ($fn.Count -ge 2)
  $rn = if ($fn.Count -ge 2) { ($fn[1] -split '/')[-1] } else { '' }
  $pol = if ($rn) { (q iam list-role-policies --role-name $rn --query 'PolicyNames[0]' --output text) } else { '' }
  $doc = if ($pol) { q iam get-role-policy --role-name $rn --policy-name $pol --query PolicyDocument --output json } else { '' }
  ok "M4 its role can scale your service only" ($rn -and -not ((q iam list-attached-role-policies --role-name $rn --output text) -match 'AdministratorAccess') -and ($doc -match "service/$G/"))
  $wired = $false
  if ($fn.Count -ge 2) { foreach ($t in (words (q cloudwatch describe-alarms --query 'MetricAlarms[].AlarmActions[]' --output text) | Sort-Object -Unique)) {
    if ((q sns list-subscriptions-by-topic --topic-arn $t --query 'Subscriptions[].Endpoint' --output text) -match [regex]::Escape($fn[0])) { $wired = $true } } }
  ok "M4 an alarm calls your autoscaler" $wired
  $log = q logs filter-log-events --log-group-name "/aws/lambda/$G-scaler" --query 'events[].message' --output text
  $moves = [regex]::Matches("$log", '(\d+) -> (\d+)')
  ok "M4 your autoscaler scaled out" (@($moves | Where-Object { [int]$_.Groups[1].Value -lt [int]$_.Groups[2].Value }).Count -gt 0)
  ok "M4 your autoscaler scaled back in" (@($moves | Where-Object { [int]$_.Groups[1].Value -gt [int]$_.Groups[2].Value }).Count -gt 0)
  $cf = q cloudfront list-distributions --query "DistributionList.Items[?contains(Origins.Items[0].DomainName,'$G-site')]|[0].Id" --output text
  ok "M4 CloudFront serves your status page" ($cf -and $cf -ne 'None' -and (http "http://$cf.cloudfront.localhost.floci.io:4566/") -eq 200)
  ok "M4 your idea is designed in NOTES.md" ((section).Count -ge 3)
}
'M5' {
  foreach ($s in 'network', 'app') {
    $st = q cloudformation describe-stacks --stack-name "$G-$s" --query 'Stacks[0].StackStatus' --output text
    ok "M5 stack $G-$s is deployed ($st)" ($st -match '^(CREATE|UPDATE)_COMPLETE$')
  }
  $res = (q cloudformation list-stack-resources --stack-name "$G-network" --query 'StackResourceSummaries[].ResourceType' --output text) + ' ' + (q cloudformation list-stack-resources --stack-name "$G-app" --query 'StackResourceSummaries[].ResourceType' --output text)
  foreach ($t in 'AWS::EC2::VPC', 'AWS::ElasticLoadBalancingV2::LoadBalancer', 'AWS::ECS::Service', 'AWS::RDS::DBInstance', 'AWS::SecretsManager::Secret') {
    ok "M5 $t comes from your templates" ($res -match [regex]::Escape($t))
  }
  ok "M5 your stacks are tagged Project=$G" ((q cloudformation describe-stacks --stack-name "$G-app" --query "Stacks[0].Tags[?Key=='Project'].Value" --output text) -eq $G)
  $dns = q cloudformation describe-stacks --stack-name "$G-app" --query "Stacks[0].Outputs[?OutputKey=='AlbDns'].OutputValue" --output text
  ok "M5 the rebuilt app answers 200" ((http "http://$dns/") -eq 200)
  git ls-files --error-unmatch infra/network.yaml infra/app.yaml *> $null; $tpl = $LASTEXITCODE
  git ls-files --error-unmatch infra/rebuild.ps1 *> $null; $a = $LASTEXITCODE
  git ls-files --error-unmatch infra/rebuild.sh *> $null; $b = $LASTEXITCODE
  ok "M5 infra/rebuild script and templates committed" (($tpl -eq 0) -and (($a -eq 0) -or ($b -eq 0)))
  ok "M5 a rebuild from zero is recorded in NOTES.md" ((notes) -match 'Rebuilt in \d+ s')
  ok "M5 your idea is built (a 'Built:' line under ## Idea)" (@((section) | Where-Object { $_ -match '(?i)^- *built:' }).Count -gt 0)
}
default { Write-Host "usage: .\checks\check.ps1 M0|M1|M2|M3|M4|M5"; exit 1 }
}
