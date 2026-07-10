<#
.SYNOPSIS
    注册 Windows 计划任务，每天自动运行 Invoke-AcmeCert.ps1（Let's Encrypt 续期 + 部署到 IIS）。

.DESCRIPTION
    - 以 SYSTEM 身份运行（可操作 IIS、证书存储、netsh）。
    - 每天执行一次；未到续期窗口自动跳过，安全幂等。
    - 需以管理员身份运行本脚本。
#>

[CmdletBinding()]
param(
    [string]$TaskName   = 'AcmeCert-AutoRenew',
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'Invoke-AcmeCert.ps1'),
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'acme-config.json'),
    [string]$AtTime     = '03:30'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ScriptPath)) { throw "找不到脚本：$ScriptPath" }

$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$psArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -ConfigPath `"$ConfigPath`""

$action    = New-ScheduledTaskAction -Execute $psExe -Argument $psArgs -WorkingDirectory $PSScriptRoot
$trigger   = New-ScheduledTaskTrigger -Daily -At $AtTime
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Hours 1)

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "已移除同名旧任务：$TaskName"
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description 'Let''s Encrypt 免费证书自动续期并部署到 IIS（Posh-ACME + 腾讯DNS）' | Out-Null

Write-Host "计划任务『$TaskName』已注册，每天 $AtTime 运行。"
Write-Host "可立即测试一次：Start-ScheduledTask -TaskName '$TaskName'"
