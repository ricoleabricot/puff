# Wipes your local AWS completely (all resources, all state). Keeps your code.
# Run: .\wipe.ps1
$a = Read-Host "Delete everything in Floci? [y/N]"
if ($a -ne 'y') { exit 0 }
Set-Location $PSScriptRoot
docker compose down
$ids = docker ps -aq --filter name=floci-aws
if ($ids) { docker rm -f $ids | Out-Null }
if (Test-Path data) { Rename-Item data ("data-old-" + [DateTimeOffset]::Now.ToUnixTimeSeconds()) }
docker compose up -d
Write-Host "Clean Floci starting, wait 20 s."
