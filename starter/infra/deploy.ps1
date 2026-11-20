# Your group's deploy script, Windows version. Put every command you run here,
# in order, so any member can rebuild your infra from zero on their machine.
$ErrorActionPreference = 'Continue'
Set-Location (Split-Path $PSScriptRoot -Parent)
. .\env.ps1
if (-not $env:GROUP) { throw 'set GROUP first, e.g. $env:GROUP = "g07"' }
