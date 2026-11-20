# Load me in every new PowerShell window:  . .\env.ps1   (dot, space, dot-backslash)
# Points the AWS CLI at Floci (your local AWS), never at a real AWS account.
Remove-Item Env:AWS_PROFILE -ErrorAction SilentlyContinue
Remove-Item Env:AWS_SESSION_TOKEN -ErrorAction SilentlyContinue
$env:AWS_ENDPOINT_URL      = 'http://localhost.floci.io:4566'
$env:AWS_ACCESS_KEY_ID     = 'test'
$env:AWS_SECRET_ACCESS_KEY = 'test'
$env:AWS_DEFAULT_REGION    = 'us-east-1'
$env:AWS_PAGER             = ''
# Floci's container registry. Push here, use it as the image in ECS.
$env:REGISTRY = 'localhost:5100'
# EC2 images and types follow your machine (ARM laptops get arm64)
$arch = if ($env:PROCESSOR_ARCHITECTURE) { $env:PROCESSOR_ARCHITECTURE } else { (uname -m) }
if ($arch -match 'ARM64|arm64|aarch64') { $env:AMI = 'ami-amazonlinux2023-arm64'; $env:TYPE = 't4g.micro' }
else { $env:AMI = 'ami-0abcdef1234567891'; $env:TYPE = 't3.micro' }
Write-Host "Floci env ready: $env:AWS_ENDPOINT_URL, region $env:AWS_DEFAULT_REGION, EC2 $env:TYPE"
