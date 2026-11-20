# Checks that your machine can run the course. Everything should say OK.
# Run: .\doctor.ps1
$script:failed = $false
function Ok($m) { Write-Host "OK   $m" }
function Ko($m, $fix) { Write-Host "FAIL $m  ->  $fix"; $script:failed = $true }

docker info *> $null
if ($LASTEXITCODE -eq 0) { Ok "Docker is running" } else { Ko "Docker is running" "start Docker Desktop and wait for it to say 'Engine running'" }

$sec = docker info --format '{{.SecurityOptions}}' 2>$null
if ("$sec" -match 'rootless') { Ko "Docker is not rootless" "rootless Docker is not supported, use a Codespace" } else { Ok "Docker is not rootless" }

if (Get-Command aws -ErrorAction SilentlyContinue) { Ok ("AWS CLI " + ((aws --version) -split ' ')[0]) }
else { Ko "AWS CLI installed" "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" }

if (Get-Command git -ErrorAction SilentlyContinue) { Ok "git" } else { Ko "git" "install Git for Windows" }

curl.exe -s -o NUL -m 3 http://localhost:4566 2>$null
if ($LASTEXITCODE -ne 0) { curl.exe -s -o /dev/null -m 3 http://localhost:4566 2>$null }
if ($LASTEXITCODE -eq 0) { Ok "Floci answers on :4566" } else { Ko "Floci answers on :4566" "docker compose up -d, then wait 20 s" }

if ((docker ps --format '{{.Image}}') -match 'floci/floci:2.5.0') { Ok "Floci 2.5.0" } else { Ko "Floci 2.5.0" "docker compose up -d in this folder" }

if ((docker exec floci env 2>$null) -match 'SECURITY_GROUP_ENFORCEMENT_ENABLED=true') { Ok "Security groups enforced" }
else { Ko "Security groups enforced" "start Floci with this folder's docker-compose.yml" }

. "$PSScriptRoot\env.ps1" | Out-Null
if ((aws sts get-caller-identity --query Account --output text 2>$null) -eq '000000000000') { Ok "AWS CLI talks to Floci" }
else { Ko "AWS CLI talks to Floci" "run: . .\env.ps1" }

if ($script:failed) { exit 1 } else { Write-Host "All good, you're ready." }
