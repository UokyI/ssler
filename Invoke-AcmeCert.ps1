<#
.SYNOPSIS
    用 Posh-ACME + Let's Encrypt + 腾讯云 DNS（TencentDNS 插件）申请/续期免费证书，并部署到本机 IIS。
    Let's Encrypt 永久免费、无限次续期，彻底摆脱腾讯免费证书的配额限制。

.DESCRIPTION
    流程：
      1. 读取 acme-config.json（腾讯云 API 密钥、域名、IIS 绑定等）。
      2. 确保 Posh-ACME 模块已安装（首次自动从 PSGallery 安装）。
      3. 用固定的 POSHACME_HOME 目录，保证管理员首跑与 SYSTEM 计划任务共用同一份账户/订单。
      4. 首次：New-PACertificate 申请；之后：Submit-Renewal 到期才续（否则空跑）。
      5. DNS-01 验证由 TencentDNS 插件自动写入/删除 TXT 记录（域名需在同账号腾讯云 DNS/DNSPod）。
      6. 拿到 fullchain.pfx 后导入本机存储，绑定到指定 IIS 站点的 443（指纹变化才重绑）。

.NOTES
    要求：Windows Server + IIS；以管理员身份首次运行；服务器需能访问 acme-v02.api.letsencrypt.org。
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'acme-config.json'),
    [switch]$ForceRenew   # 强制立即续期（无视续期窗口）
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 }
}

function Initialize-PoshAcme {
    param([string]$PoshAcmeHome)

    # 固定 Posh-ACME 数据目录，确保 admin 首跑与 SYSTEM 计划任务共用配置
    $env:POSHACME_HOME = $PoshAcmeHome
    if (-not (Test-Path $PoshAcmeHome)) { New-Item -ItemType Directory -Path $PoshAcmeHome -Force | Out-Null }

    if (-not (Get-Module -ListAvailable -Name Posh-ACME)) {
        Write-Log "未检测到 Posh-ACME 模块，开始安装 ..."
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
        }
        if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        }
        Install-Module -Name Posh-ACME -Scope AllUsers -Force
        Write-Log "Posh-ACME 安装完成。"
    }
    Import-Module Posh-ACME -Force
}

function Get-BoundThumbprint {
    param([string]$HostHeader, [int]$Port)
    $filter = if ($HostHeader) { "hostnameport=`"${HostHeader}:$Port`"" } else { "ipport=`"0.0.0.0:$Port`"" }
    $out = & netsh http show sslcert $filter 2>$null
    if ($out) {
        $line = $out | Where-Object { $_ -match '证书哈希|Certificate Hash' }
        if ($line) { return (($line -split ':')[-1]).Trim() }
    }
    return $null
}

function Install-CertToIIS {
    param([string]$PfxPath, [string]$PfxPassword, [string]$SiteName, [string]$HostHeader, [int]$Port)

    Import-Module WebAdministration -ErrorAction Stop

    $securePwd = if ($PfxPassword) { ConvertTo-SecureString $PfxPassword -AsPlainText -Force } else { (New-Object System.Security.SecureString) }
    $imported  = Import-PfxCertificate -FilePath $PfxPath -CertStoreLocation 'Cert:\LocalMachine\My' -Password $securePwd
    $thumb     = $imported.Thumbprint
    Write-Log "证书已导入本机存储，指纹=$thumb，NotAfter=$($imported.NotAfter)"

    # 确保 https 绑定存在
    $existing = Get-WebBinding -Name $SiteName -Protocol 'https' -ErrorAction SilentlyContinue |
                Where-Object { $_.bindingInformation -like "*:${Port}:$HostHeader" }
    if (-not $existing) {
        if ($HostHeader) {
            New-WebBinding -Name $SiteName -Protocol 'https' -Port $Port -HostHeader $HostHeader -SslFlags 1
            Write-Log "已创建 https 绑定（SNI）：$SiteName $HostHeader`:$Port"
        } else {
            New-WebBinding -Name $SiteName -Protocol 'https' -Port $Port
            Write-Log "已创建 https 绑定：$SiteName *:$Port"
        }
    }

    $appId = '{' + ([guid]::NewGuid().ToString()) + '}'
    if ($HostHeader) {
        & netsh http delete sslcert hostnameport="${HostHeader}:$Port" 2>$null | Out-Null
        $r = & netsh http add sslcert hostnameport="${HostHeader}:$Port" certhash=$thumb appid="$appId" certstorename=MY
    } else {
        & netsh http delete sslcert ipport="0.0.0.0:$Port" 2>$null | Out-Null
        $r = & netsh http add sslcert ipport="0.0.0.0:$Port" certhash=$thumb appid="$appId" certstorename=MY
    }
    if ($LASTEXITCODE -ne 0) { throw "netsh 绑定证书失败：$r" }
    Write-Log "已将证书绑定到 IIS 站点『$SiteName』端口 $Port。"
    return $thumb
}

function Main {
    if (-not (Test-Path $ConfigPath)) { throw "找不到配置文件：$ConfigPath（请复制 acme-config.example.json 为 acme-config.json 并填写）。" }
    $c = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    foreach ($k in @('TencentKeyId','TencentSecret','Domains','ContactEmail','IISSiteName')) {
        if (-not $c.PSObject.Properties.Name.Contains($k)) { throw "配置项缺失：$k" }
    }

    $workDir = if ($c.PSObject.Properties.Name.Contains('WorkDir') -and $c.WorkDir) { [string]$c.WorkDir } else { Join-Path $PSScriptRoot 'acme-work' }
    if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }
    $script:LogFile = Join-Path $workDir 'acme-cert.log'
    $poshHome = Join-Path $workDir 'pa'

    $domains = @($c.Domains)
    $mainDomain = $domains[0]
    $email = [string]$c.ContactEmail
    $site  = [string]$c.IISSiteName
    $port  = if ($c.PSObject.Properties.Name.Contains('BindingPort') -and $c.BindingPort) { [int]$c.BindingPort } else { 443 }
    $bindHost = if ($c.PSObject.Properties.Name.Contains('BindingHost')) { [string]$c.BindingHost } else { '' }
    $pfxPass  = if ($c.PSObject.Properties.Name.Contains('PfxPassword') -and $c.PfxPassword) { [string]$c.PfxPassword } else { 'poshacme' }
    $useStaging = ($c.PSObject.Properties.Name.Contains('UseStaging') -and $c.UseStaging)
    $renewBeforeDays = if ($c.PSObject.Properties.Name.Contains('RenewBeforeDays') -and $c.RenewBeforeDays) { [double]$c.RenewBeforeDays } else { 30 }

    Write-Log "==== 开始处理证书：$($domains -join ', ') ===="
    Initialize-PoshAcme -PoshAcmeHome $poshHome

    # 选择 CA：生产 / 测试（测试用于调试，不受速率限制，但浏览器不信任）
    Set-PAServer -DirectoryUrl ($(if ($useStaging) { 'LE_STAGE' } else { 'LE_PROD' }))

    # 首次运行还没有账户，先创建（否则 Get-PAOrder 会抛"No ACME account configured"）
    if (-not (Get-PAAccount)) {
        Write-Log "首次运行，创建 ACME 账户（联系邮箱 $email）..."
        New-PAAccount -AcceptTOS -Contact $email -Force | Out-Null
    }

    $pArgs = @{
        TencentKeyId  = [string]$c.TencentKeyId
        TencentSecret = (ConvertTo-SecureString ([string]$c.TencentSecret) -AsPlainText -Force)
    }

    $order = $null
    try { $order = Get-PAOrder -MainDomain $mainDomain -ErrorAction Stop } catch { $order = $null }
    if (-not $order) {
        Write-Log "首次申请证书 ..."
        New-PACertificate -Domain $domains -AcceptTOS -Contact $email `
            -Plugin TencentDNS -PluginArgs $pArgs -PfxPass $pfxPass -Force | Out-Null
    } else {
        $existing = Get-PACertificate -MainDomain $mainDomain -ErrorAction SilentlyContinue
        $daysLeft = if ($existing) { ($existing.NotAfter - (Get-Date)).TotalDays } else { -1 }
        if ($ForceRenew) {
            Write-Log "强制续期（-ForceRenew）..."
            Submit-Renewal -MainDomain $mainDomain -Force -PluginArgs $pArgs | Out-Null
        } elseif ($daysLeft -le $renewBeforeDays) {
            Write-Log ("证书剩余 {0:N1} 天 ≤ 阈值 {1} 天，开始续期 ..." -f $daysLeft, $renewBeforeDays)
            Submit-Renewal -MainDomain $mainDomain -Force -PluginArgs $pArgs | Out-Null
        } else {
            Write-Log ("证书剩余 {0:N1} 天 > 阈值 {1} 天，无需续期。" -f $daysLeft, $renewBeforeDays)
        }
    }

    $cert = Get-PACertificate -MainDomain $mainDomain
    if (-not $cert) { throw "未能获取证书对象。" }

    $pfxPath = $cert.PfxFullChain
    if (-not (Test-Path $pfxPath)) { throw "找不到 PFX：$pfxPath" }

    # 指纹未变则说明本次没续期，IIS 已绑定，跳过重绑
    $currentBound = Get-BoundThumbprint -HostHeader $bindHost -Port $port
    if ($currentBound -and ($currentBound -ieq $cert.Thumbprint)) {
        Write-Log "IIS 已绑定当前证书（指纹 $($cert.Thumbprint)），无需变更。"
    } else {
        Install-CertToIIS -PfxPath $pfxPath -PfxPassword $pfxPass -SiteName $site -HostHeader $bindHost -Port $port | Out-Null
    }

    Write-Log "==== 完成。证书到期：$($cert.NotAfter) ===="
}

try {
    Main
} catch {
    Write-Log "执行失败：$($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    exit 1
}