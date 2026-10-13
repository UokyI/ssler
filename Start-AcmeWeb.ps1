<#
.SYNOPSIS
    证书续期 Web 控制台：查看证书到期时间、切换自动续期开关、手动续期。

.DESCRIPTION
    仅使用 Windows 内置组件（PowerShell + .NET HttpListener），无需安装任何第三方依赖，
    也无需配置 IIS。启动后浏览器访问 http://<BindAddress>:<Port>/ 即可。

    为低配服务器做了优化：状态结果短缓存、续期异步执行不阻塞、响应必关闭、
    忽略客户端中断异常、请求体限长，避免内存/句柄增长。

    接口：
      GET  /api/status        返回证书与自动续期状态（JSON，默认缓存 5 秒）
      POST /api/renew         启动后台续期，立即返回 { started, running }
      GET  /api/renew/status  查询后台续期进度/结果
      POST /api/autorenew     开启/关闭自动续期计划任务，body: { "enabled": true|false }

.PARAMETER Port
    监听端口，默认 30001。

.PARAMETER BindAddress
    监听地址，默认 localhost（仅本机可访问，最安全）。
    如需局域网访问，用 '+'（所有网卡），并先执行（管理员）：
      netsh http add urlacl url=http://+:30001/ user=Everyone

.PARAMETER StatusCacheSeconds
    状态结果缓存秒数，默认 5，避免每次轮询都执行 netsh / 计划任务查询。

.PARAMETER Install
    注册开机自启计划任务（SYSTEM 身份），随后启动服务并退出。等价于把本脚本做成常驻服务。

.PARAMETER Uninstall
    停止并删除开机自启计划任务。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Start-AcmeWeb.ps1
    然后浏览器打开 http://localhost:30001/

.EXAMPLE
    # 开机自启 + 局域网可访问
    powershell -ExecutionPolicy Bypass -File .\Start-AcmeWeb.ps1 -Install -BindAddress + -Port 30001
#>
[CmdletBinding()]
param(
    [int]$Port = 30001,
    [string]$BindAddress = 'localhost',
    [string]$ConfigPath,
    [string]$ScriptPath,
    [string]$RegisterScript,
    [string]$TaskName = 'AcmeCert-AutoRenew',
    [string]$WebTaskName = 'AcmeCert-WebConsole',
    [int]$StatusCacheSeconds = 5,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not $ConfigPath)     { $ConfigPath     = Join-Path $PSScriptRoot 'acme-config.json' }
if (-not $ScriptPath)     { $ScriptPath     = Join-Path $PSScriptRoot 'Invoke-AcmeCert.ps1' }
if (-not $RegisterScript) { $RegisterScript = Join-Path $PSScriptRoot 'Register-AcmeRenewTask.ps1' }
$script:IndexPath = Join-Path $PSScriptRoot 'index.html'
$script:PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# 运行日志写文件，不写控制台：Windows 控制台一旦被鼠标选中会阻塞进程输出，
# 单线程服务会因此整体挂起（重要！）
$script:WebLog = Join-Path $PSScriptRoot 'acme-web.log'
$script:LogEncoding = New-Object Text.UTF8Encoding($false)
function Write-ALog {
    param([string]$Message)
    $line = "{0}  {1}{2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message, [Environment]::NewLine
    try {
        $fi = [System.IO.FileInfo]$script:WebLog
        if ($fi.Exists -and $fi.Length -gt 512KB) {
            [System.IO.File]::WriteAllText($script:WebLog, $line, $script:LogEncoding)
        } else {
            [System.IO.File]::AppendAllText($script:WebLog, $line, $script:LogEncoding)
        }
    } catch { }
}

# 状态缓存
$script:StatusCache     = $null
$script:StatusCacheTime = [datetime]::MinValue

# 后台续期任务（避免阻塞主循环）
$script:RenewJob = $null

function Reset-StatusCache {
    $script:StatusCache     = $null
    $script:StatusCacheTime = [datetime]::MinValue
}

# ---------------- 计划任务（开机自启） ----------------

function Install-WebConsoleTask {
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Port $Port -BindAddress `"$BindAddress`""
    $action    = New-ScheduledTaskAction -Execute $script:PsExe -Argument $arg -WorkingDirectory $PSScriptRoot
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 3 `
                    -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
    if (Get-ScheduledTask -TaskName $WebTaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $WebTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $WebTaskName -Confirm:$false
    }
    Register-ScheduledTask -TaskName $WebTaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description '证书续期 Web 控制台（开机自启）' | Out-Null
    Start-ScheduledTask -TaskName $WebTaskName
    Write-Host "已注册开机自启任务『$WebTaskName』并启动。访问：http://$BindAddress`:$Port/"
}

function Uninstall-WebConsoleTask {
    $task = Get-ScheduledTask -TaskName $WebTaskName -ErrorAction SilentlyContinue
    if ($task) {
        Stop-ScheduledTask -TaskName $WebTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $WebTaskName -Confirm:$false
        Write-Host "已停止并删除开机自启任务『$WebTaskName』。"
    } else {
        Write-Host "未找到任务『$WebTaskName』。"
    }
}

# ---------------- 状态读取 ----------------

function Get-WorkDir {
    if (Test-Path $ConfigPath) {
        try {
            $c = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            if ($c.PSObject.Properties.Name.Contains('WorkDir') -and $c.WorkDir) { return [string]$c.WorkDir }
        } catch { }
    }
    return (Join-Path $PSScriptRoot 'acme-work')
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

function Format-Time {
    param($Time)
    if ($null -eq $Time) { return $null }
    try {
        $dt = [datetime]$Time
        if ($dt.Year -lt 2000) { return $null }
        return $dt.ToString('yyyy-MM-dd HH:mm:ss')
    } catch { return $null }
}

# 计划任务读取走 COM(Schedule.Service)，比 Get-ScheduledTask 快数百倍，
# 避免在低配服务器上轮询时卡住（Get-ScheduledTask 可能极慢甚至挂起）
$script:taskSvc   = $null
$script:taskCache = @{}
function Get-TaskService {
    if (-not $script:taskSvc) {
        $script:taskSvc = New-Object -ComObject Schedule.Service
        $script:taskSvc.Connect()
    }
    return $script:taskSvc
}

function Get-AutoRenewInfo {
    param([string]$Name)
    $hit = $script:taskCache[$Name]
    if ($hit -and ((Get-Date) - $hit.at).TotalSeconds -lt 3) { return $hit.info }

    $info = [ordered]@{
        taskName = $Name; exists = $false; enabled = $false; state = ''
        lastRun = $null; lastResult = $null; nextRun = $null
    }
    try {
        $task = (Get-TaskService).GetFolder('\').GetTask($Name)
        $stateMap = @{ 0 = 'Unknown'; 1 = 'Disabled'; 2 = 'Queued'; 3 = 'Ready'; 4 = 'Running' }
        $sv = [int]$task.State
        $info.exists  = $true
        $info.state   = if ($stateMap.ContainsKey($sv)) { $stateMap[$sv] } else { [string]$sv }
        $info.enabled = [bool]$task.Enabled
        try { if ($task.LastRunTime -and ([datetime]$task.LastRunTime).Year -gt 1900) { $info.lastRun = ([datetime]$task.LastRunTime).ToString('yyyy-MM-dd HH:mm:ss') } } catch { }
        try { $info.lastResult = [int]$task.LastTaskResult } catch { }
        try { if ($task.NextRunTime -and ([datetime]$task.NextRunTime).Year -gt 1900 -and ([datetime]$task.NextRunTime).Year -lt 9000) { $info.nextRun = ([datetime]$task.NextRunTime).ToString('yyyy-MM-dd HH:mm:ss') } } catch { }
    } catch { }

    $script:taskCache[$Name] = @{ at = (Get-Date); info = $info }
    return $info
}

function Get-Status {
    param([switch]$Force)

    if (-not $Force -and $script:StatusCache -and
        ((Get-Date) - $script:StatusCacheTime).TotalSeconds -lt $StatusCacheSeconds) {
        return $script:StatusCache
    }

    $result = [ordered]@{
        serverTime   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        configPath   = $ConfigPath
        configExists = (Test-Path $ConfigPath)
        domains      = @()
        notAfter     = $null
        daysLeft     = $null
        thumbprint   = ''
        subject      = ''
        useStaging   = $false
        bound        = $false
        autoRenew    = [ordered]@{
            taskName   = $TaskName
            exists     = $false
            enabled    = $false
            state      = ''
            lastRun    = $null
            lastResult = $null
            nextRun    = $null
        }
        lastRenew    = ''
        logTail      = @()
    }

    $c = $null
    Write-ALog 'status: 读取配置 ...'
    if (Test-Path $ConfigPath) {
        try { $c = Get-Content $ConfigPath -Raw | ConvertFrom-Json } catch { $c = $null }
    }
    if ($c) {
        $result.domains = @($c.Domains)
        if ($c.PSObject.Properties.Name.Contains('UseStaging')) { $result.useStaging = [bool]$c.UseStaging }
    }

    # 已绑定到 IIS 的证书
    $bindHost = ''
    $bindPort = 443
    if ($c) {
        if ($c.PSObject.Properties.Name.Contains('BindingHost')) { $bindHost = [string]$c.BindingHost }
        if ($c.PSObject.Properties.Name.Contains('BindingPort') -and $c.BindingPort) { $bindPort = [int]$c.BindingPort }
    }
    Write-ALog "status: 查询 netsh sslcert ($bindHost`:$bindPort) ..."
    $thumb = Get-BoundThumbprint -HostHeader $bindHost -Port $bindPort
    Write-ALog "status: netsh 返回 thumb=$thumb"
    if ($thumb) {
        $result.thumbprint = $thumb
        $cert = Get-Item ("Cert:\LocalMachine\My\{0}" -f $thumb) -ErrorAction SilentlyContinue
        if ($cert) {
            $result.notAfter  = $cert.NotAfter.ToString('yyyy-MM-dd HH:mm:ss')
            $result.daysLeft  = [math]::Round(($cert.NotAfter - (Get-Date)).TotalDays, 1)
            $result.subject   = $cert.Subject
            $result.bound     = $true
        }
    }

    # 自动续期计划任务（COM，避免 Get-ScheduledTask 卡顿）
    Write-ALog 'status: 读取计划任务 (COM) ...'
    $result.autoRenew = Get-AutoRenewInfo -Name $TaskName
    Write-ALog "status: 计划任务 exists=$($result.autoRenew.exists) enabled=$($result.autoRenew.enabled)"

    # 日志尾部
    Write-ALog 'status: 读取日志 ...'
    $log = Join-Path (Get-WorkDir) 'acme-cert.log'
    if (Test-Path $log) {
        $tail = Get-Content $log -Tail 20 -ErrorAction SilentlyContinue
        if ($tail) { $result.logTail = @($tail) }
        $last = Get-Content $log -Tail 200 -ErrorAction SilentlyContinue |
                Where-Object { $_ -match '完成。证书到期' } | Select-Object -Last 1
        if ($last) { $result.lastRenew = $last }
    }
    Write-ALog 'status: 采集完成'

    $script:StatusCache     = $result
    $script:StatusCacheTime = Get-Date
    return $result
}

# ---------------- 动作 ----------------

function Start-Renew {
    if ($script:RenewJob -and -not $script:RenewJob.Process.HasExited) {
        return [ordered]@{ started = $false; running = $true; message = '续期任务已在运行' }
    }
    if (-not (Test-Path $ScriptPath)) {
        return [ordered]@{ started = $false; running = $false; message = "找不到脚本：$ScriptPath" }
    }
    $out = Join-Path $env:TEMP ("acme-renew-{0}.out" -f ([guid]::NewGuid().ToString('N')))
    $err = Join-Path $env:TEMP ("acme-renew-{0}.err" -f ([guid]::NewGuid().ToString('N')))
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -ConfigPath `"$ConfigPath`" -ForceRenew"
    $proc = Start-Process -FilePath $script:PsExe -ArgumentList $arg -PassThru -WindowStyle Hidden `
                -RedirectStandardOutput $out -RedirectStandardError $err
    $script:RenewJob = [pscustomobject]@{ Process = $proc; Out = $out; Err = $err; StartedAt = (Get-Date); Result = $null }
    Reset-StatusCache
    return [ordered]@{ started = $true; running = $true; message = '已开始续期' }
}

function Get-RenewStatus {
    if (-not $script:RenewJob) {
        return [ordered]@{ running = $false; finished = $false; success = $null; exitCode = $null; output = ''; status = (Get-Status) }
    }
    $job = $script:RenewJob
    if ($job.Result) { return $job.Result }

    $job.Process.Refresh()
    if (-not $job.Process.HasExited) {
        return [ordered]@{ running = $true; finished = $false; success = $null; exitCode = $null; output = ''; status = (Get-Status) }
    }

    $code = $job.Process.ExitCode
    $text = ''
    try { if (Test-Path $job.Out) { $text = (Get-Content $job.Out -Raw -ErrorAction SilentlyContinue) } } catch { }
    if ([string]::IsNullOrWhiteSpace($text)) {
        try { if (Test-Path $job.Err) { $text = (Get-Content $job.Err -Raw -ErrorAction SilentlyContinue) } } catch { }
    }
    try { Remove-Item $job.Out, $job.Err -Force -ErrorAction SilentlyContinue } catch { }

    Reset-StatusCache
    $job.Result = [ordered]@{
        running  = $false
        finished = $true
        success  = ($code -eq 0)
        exitCode = $code
        output   = ([string]$text).Trim()
        status   = (Get-Status -Force)
    }
    return $job.Result
}

function Set-AutoRenew {
    param([bool]$Enabled)
    $info = Get-AutoRenewInfo -Name $TaskName
    if ($Enabled) {
        if ($info.exists) {
            & schtasks.exe /Change /TN $TaskName /ENABLE 2>&1 | Out-Null
        } elseif (Test-Path $RegisterScript) {
            & $script:PsExe -NoProfile -ExecutionPolicy Bypass -File $RegisterScript `
                -ScriptPath $ScriptPath -ConfigPath $ConfigPath -TaskName $TaskName 2>&1 | Out-Null
        } else {
            throw "找不到注册脚本：$RegisterScript"
        }
    } else {
        if ($info.exists) { & schtasks.exe /Change /TN $TaskName /DISABLE 2>&1 | Out-Null }
    }
    $script:taskCache.Clear()
    Reset-StatusCache
    return (Get-Status -Force)
}

# ---------------- HTTP ----------------

function ConvertTo-JsonString {
    param([string]$s)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        $code = [int][char]$ch
        if     ($code -eq 34) { [void]$sb.Append('\"') }
        elseif ($code -eq 92) { [void]$sb.Append('\\') }
        elseif ($code -eq 8)  { [void]$sb.Append('\b') }
        elseif ($code -eq 12) { [void]$sb.Append('\f') }
        elseif ($code -eq 10) { [void]$sb.Append('\n') }
        elseif ($code -eq 13) { [void]$sb.Append('\r') }
        elseif ($code -eq 9)  { [void]$sb.Append('\t') }
        elseif ($code -lt 32) { [void]$sb.Append('\u{0:x4}' -f $code) }
        else                  { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# 手写序列化，避免 ConvertTo-Json 在个别环境下卡住
function ConvertTo-JsonText {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [string]) { return (ConvertTo-JsonString $Value) }
    if ($Value -is [System.Collections.IDictionary]) {
        $pairs = New-Object System.Collections.ArrayList
        foreach ($k in $Value.Keys) {
            [void]$pairs.Add((ConvertTo-JsonString ([string]$k)) + ':' + (ConvertTo-JsonText $Value[$k]))
        }
        return '{' + ($pairs -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.ArrayList
        foreach ($i in $Value) { [void]$items.Add((ConvertTo-JsonText $i)) }
        return '[' + ($items -join ',') + ']'
    }
    return (ConvertTo-JsonString ([string]$Value))
}

function Write-Json {
    param($Response, $Object)
    $typeName = 'null'
    if ($null -ne $Object) { $typeName = $Object.GetType().Name }
    Write-ALog "json: 序列化 ($typeName) ..."
    $json  = ConvertTo-JsonText $Object
    Write-ALog ("json: 序列化完成 len={0}" -f ([string]$json).Length)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.ContentType     = 'application/json; charset=utf-8'
    $Response.ContentLength64 = $bytes.Length
    Write-ALog ("json: 写入响应 {0} 字节 ..." -f $bytes.Length)
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    Write-ALog 'json: 写入完成'
    $Response.OutputStream.Close()
}

function Send-File {
    param($Response, [string]$Path, [string]$ContentType)
    if (-not (Test-Path $Path)) {
        $Response.StatusCode = 404
        $Response.Close()
        return
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $Response.ContentType     = $ContentType
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Read-JsonBody {
    param($Request, [int]$MaxBytes = 8192)
    if ($Request.ContentLength64 -gt $MaxBytes) { return $null }
    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    $body = $reader.ReadToEnd()
    $reader.Close()
    if ([string]::IsNullOrWhiteSpace($body)) { return $null }
    try { return ($body | ConvertFrom-Json) } catch { return $null }
}

function Handle-Request {
    param($Context)
    $req = $Context.Request
    $res = $Context.Response
    $res.Headers.Add('Access-Control-Allow-Origin', '*')
    $res.Headers.Add('Access-Control-Allow-Methods', 'GET,POST,OPTIONS')
    $res.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')
    $res.Headers.Add('Cache-Control', 'no-store')

    if ($req.HttpMethod -eq 'OPTIONS') { $res.StatusCode = 204; $res.Close(); return }

    $path = $req.Url.AbsolutePath
    switch -Regex ($path) {
        '^/(index\.html)?$' {
            Send-File $res $script:IndexPath 'text/html; charset=utf-8'
        }
        '^/api/status$' {
            Write-Json $res (Get-Status)
        }
        '^/api/renew$' {
            if ($req.HttpMethod -ne 'POST') { $res.StatusCode = 405; $res.Close(); return }
            Write-Json $res (Start-Renew)
        }
        '^/api/renew/status$' {
            Write-Json $res (Get-RenewStatus)
        }
        '^/api/autorenew$' {
            if ($req.HttpMethod -ne 'POST') { $res.StatusCode = 405; $res.Close(); return }
            $body = Read-JsonBody $req
            $enabled = $false
            if ($body -and $body.PSObject.Properties.Name.Contains('enabled')) { $enabled = [bool]$body.enabled }
            Write-Json $res (Set-AutoRenew -Enabled $enabled)
        }
        default {
            $res.StatusCode = 404
            Write-Json $res @{ error = 'not found' }
        }
    }
}

# ---------------- 入口 ----------------

if ($Uninstall) { Uninstall-WebConsoleTask; return }
if ($Install)   { Install-WebConsoleTask;   return }

function Get-Prefixes {
    param([string]$Bind, [int]$P)
    if ($Bind -eq 'localhost') {
        # 同时监听 localhost / 127.0.0.1 / ::1，避免某些浏览器把 localhost 落到 127.0.0.1 或 ::1 时被 HTTP.SYS 判 400
        return @("http://localhost:$P/", "http://127.0.0.1:$P/", "http://[::1]:$P/")
    }
    return @("http://${Bind}:$P/")
}

function New-Listener {
    param([string[]]$Prefixes)
    $l = New-Object System.Net.HttpListener
    foreach ($p in $Prefixes) {
        try { $l.Prefixes.Add($p) } catch { Write-Host "跳过无效前缀 $p：$($_.Exception.Message)" -ForegroundColor DarkYellow }
    }
    $l.IgnoreWriteExceptions = $true
    return $l
}

$prefixes = Get-Prefixes $BindAddress $Port
$listener = New-Listener $prefixes

try {
    $listener.Start()
} catch {
    if ($BindAddress -ne 'localhost') {
        Write-Host "监听失败，尝试自动添加 URL ACL（需管理员）..." -ForegroundColor Yellow
        & netsh http add urlacl url="http://+:$Port/" user=Everyone 2>&1 | Out-Null
        $listener = New-Listener $prefixes
        try {
            $listener.Start()
        } catch {
            Write-Host "仍无法监听：$($_.Exception.Message)" -ForegroundColor Red
            throw
        }
    } else {
        Write-Host ""
        Write-Host "无法监听：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host "若监听非 localhost 地址，请以管理员身份先执行：" -ForegroundColor Yellow
        Write-Host "  netsh http add urlacl url=http://+:$Port/ user=Everyone" -ForegroundColor Yellow
        Write-Host "或改用默认的 -BindAddress localhost（无需 URL ACL，但仅本机可访问）。" -ForegroundColor Yellow
        throw
    }
}

Write-Host "证书续期控制台已启动，请用以下任一地址访问：" -ForegroundColor Green
foreach ($p in $prefixes) { Write-Host ("  " + $p.TrimEnd('/')) }
Write-Host "按 Ctrl+C 停止。"
if (-not $NoBrowser) { try { Start-Process ("http://localhost:$Port/") } catch { } }

try {
    while ($listener.IsListening) {
        $ctx = $null
        try {
            $ctx = $listener.GetContext()
        } catch {
            if (-not $listener.IsListening) { break }
            Start-Sleep -Milliseconds 50   # 容错，避免异常时空转
            continue
        }
        try {
            Handle-Request $ctx
        } catch {
            try {
                $ctx.Response.StatusCode = 500
                Write-Json $ctx.Response @{ error = $_.Exception.Message }
            } catch { }
        } finally {
            $code = ''
            try { $code = [int]$ctx.Response.StatusCode } catch { }
            try { Write-ALog ("{0,-4} {1} -> {2}" -f $ctx.Request.HttpMethod, $ctx.Request.Url.PathAndQuery, $code) } catch { }
            try { $ctx.Response.Close() } catch { }
        }
    }
} finally {
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
    if ($script:taskSvc) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($script:taskSvc) } catch { } }
}
