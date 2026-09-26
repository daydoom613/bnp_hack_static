# Run the FinOps Grafana dashboard natively on Windows (no Docker), reading live
# CloudWatch data with your AWS CLI profile. Use this where Docker containers cannot
# reach the internet; elsewhere `docker compose -f observability/docker-compose.yml up -d`
# does the same thing.
#
#   powershell -File observability\grafana-windows.ps1 [-GrafanaHome C:\Users\<you>\grafana\grafana-v11.3.0] [-Profile finops]
#   then open http://localhost:3000/d/finops-cloudscale   (anonymous view; admin/admin to edit)
#
# Stop it with:  Stop-Process -Name grafana
param(
    [string]$GrafanaHome = "$env:USERPROFILE\grafana\grafana-v11.3.0",
    [string]$Profile = "finops",
    [string]$Region = "eu-west-1"
)

$repo = Split-Path -Parent $PSScriptRoot
$observability = Join-Path $repo "observability\grafana"

if (-not (Test-Path "$GrafanaHome\bin\grafana.exe")) {
    Write-Error "Grafana not found in $GrafanaHome. Download https://dl.grafana.com/oss/release/grafana-11.3.0.windows-amd64.zip and extract it there."
    exit 1
}

# Provisioning: the CloudWatch data source and the FinOps dashboard from this repo.
$env:GF_PATHS_PROVISIONING = Join-Path $observability "provisioning"
$env:FINOPS_DASHBOARDS_DIR = Join-Path $observability "dashboards"
$env:GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH = Join-Path $observability "dashboards\finops-cloudscale.json"
$env:GF_AUTH_ANONYMOUS_ENABLED = "true"
$env:GF_AUTH_ANONYMOUS_ORG_ROLE = "Viewer"
# CloudWatch: the AWS SDK default chain with your profile (%USERPROFILE%\.aws).
$env:GF_AWS_ALLOWED_AUTH_PROVIDERS = "default,keys,credentials"
$env:AWS_PROFILE = $Profile
$env:AWS_REGION = $Region
$env:AWS_SDK_LOAD_CONFIG = "true"

$log = Join-Path $GrafanaHome "data\log\grafana-console.log"
New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
Start-Process -FilePath "$GrafanaHome\bin\grafana.exe" -ArgumentList "server", "--homepath", "`"$GrafanaHome`"" `
    -WorkingDirectory $GrafanaHome -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError "$log.err"

Write-Host "Grafana starting with AWS profile '$Profile' ($Region)."
Write-Host "Open http://localhost:3000/d/finops-cloudscale   (logs: $log)"
