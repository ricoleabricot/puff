# Windows version of intruder.sh. Launches a throwaway "intruder" container inside
# your private subnets, in a security group nobody trusts, and tries to open your
# app (port 80) and your database directly. Prints REACHED or BLOCKED for each.
# Usage: .\checks\intruder.ps1
Set-Location (Split-Path $PSScriptRoot -Parent)
. .\env.ps1 | Out-Null
$G = $env:GROUP
if (-not $G) { Write-Host 'set GROUP first, e.g. $env:GROUP = "g07"'; exit 1 }
function q { $out = & aws @args 2>$null; if ($LASTEXITCODE -ne 0) { return $null }; return ($out -join "`n").Trim() }

$vpc = q ec2 describe-vpcs --filters "Name=tag:Name,Values=$G-vpc" --query 'Vpcs[0].VpcId' --output text
if (-not $vpc -or $vpc -eq 'None') { Write-Host "no VPC tagged Name=$G-vpc"; exit 1 }
$svc = ((q ecs list-services --cluster $G --query 'serviceArns[-1]' --output text) -split '/')[-1]
$task = ((q ecs list-tasks --cluster $G --service-name $svc --query 'taskArns[0]' --output text) -split '/')[-1]
$subnet = q ecs describe-services --cluster $G --services $svc --query 'services[0].networkConfiguration.awsvpcConfiguration.subnets[0]' --output text

# The app container's real address on your machine (Floci runs it in Docker)
$appIp = ((docker inspect "floci-aws-sg-$task" -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>$null) -split ' ')[0]
$db = (q rds describe-db-instances --query "DBInstances[?starts_with(DBInstanceIdentifier,'$G-db')]|[-1].Endpoint.[Address,Port]" --output text) -split '\s+'

$sg = q ec2 describe-security-groups --filters "Name=group-name,Values=$G-intruder-sg" "Name=vpc-id,Values=$vpc" --query 'SecurityGroups[0].GroupId' --output text
if (-not $sg -or $sg -eq 'None') { $sg = q ec2 create-security-group --group-name "$G-intruder-sg" --description "trusted by nobody" --vpc-id $vpc --query GroupId --output text }

$cmd = "sleep 3; nc -z -w3 $appIp 80 && echo APP_REACHED || echo APP_BLOCKED; nc -z -w3 $($db[0]) $($db[1]) && echo DB_REACHED || echo DB_BLOCKED; sleep 30"
$defs = @(@{ name = 'x'; image = 'alpine:3.20'; entryPoint = @('sh', '-c'); command = @($cmd) }) | ConvertTo-Json -Depth 5 -Compress
if (-not $defs.StartsWith('[')) { $defs = "[$defs]" }
$tmp = Join-Path ([IO.Path]::GetTempPath()) "$G-intruder.json"
[IO.File]::WriteAllText($tmp, $defs)
q ecs register-task-definition --family "$G-intruder" --network-mode awsvpc --requires-compatibilities FARGATE --cpu 256 --memory 512 --container-definitions "file://$tmp" | Out-Null
q ecs run-task --cluster $G --task-definition "$G-intruder" --launch-type FARGATE --network-configuration "awsvpcConfiguration={subnets=[$subnet],securityGroups=[$sg]}" | Out-Null
$t = ((q ecs list-tasks --cluster $G --family "$G-intruder" --query 'taskArns[-1]' --output text) -split '/')[-1]
$out = ''
for ($i = 0; $i -lt 60; $i++) { $out = (docker logs "floci-aws-ecs-$t-x" 2>&1) -join "`n"; if (([regex]::Matches($out, 'REACHED|BLOCKED')).Count -ge 2) { break }; Start-Sleep 2 }
$app = if ($out -match 'APP_(REACHED|BLOCKED)') { $Matches[1] } else { '' }
$dbr = if ($out -match 'DB_(REACHED|BLOCKED)') { $Matches[1] } else { '' }
Write-Output "intruder -> app $($appIp):80        : $app"
Write-Output "intruder -> db  $($db[0]):$($db[1]) : $dbr"
