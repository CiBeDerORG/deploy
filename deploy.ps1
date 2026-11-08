#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$CliArgs
)

$ErrorActionPreference = 'Stop'
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$script:RootDir = [IO.Path]::GetFullPath((Split-Path -Parent $PSCommandPath))
$script:SoftwareRoot = ''
$script:GlobalEnvDir = ''
$script:GlobalEnv = ''
$script:GlobalSecrets = ''
$script:Config = @{}
$script:AppEnv = ''
$script:AppSecrets = ''
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-TextFile {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

function Normalize-Path {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd([char[]]@('\','/')) }
    return $full
}

function Read-ConfigFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "配置文件不存在：$Path" }
    $values = @{}
    $lineNo = 0
    foreach ($rawLine in [IO.File]::ReadAllLines($Path)) {
        $lineNo++
        $line = $rawLine.TrimEnd([char]13)
        $trimmed = $line.TrimStart()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }
        $equals = $line.IndexOf('=')
        if ($equals -lt 0) { throw "配置格式错误：$Path 第 $lineNo 行应为 KEY=VALUE。" }
        $key = $line.Substring(0, $equals).Trim()
        $value = $line.Substring($equals + 1)
        if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "配置变量名非法：$Path 第 $lineNo 行。" }
        if ($values.ContainsKey($key)) { throw "配置错误：$Path 中变量 $key 重复定义；为避免使用错误配置，已停止执行。" }
        if ($value.Length -gt 0) {
            $first = $value[0]
            if ($first -eq '"' -or $first -eq "'") {
                if ($value.Length -lt 2 -or $value[$value.Length - 1] -ne $first) {
                    throw "配置引号未闭合：$Path 第 $lineNo 行。"
                }
                $value = $value.Substring(1, $value.Length - 2)
            }
        }
        $values[$key] = $value
    }
    return $values
}

function Get-KeyFromLine {
    param([string]$Line)
    $trimmed = $Line.TrimStart()
    if ($trimmed -match '^([A-Za-z_][A-Za-z0-9_]*)\s*=') { return $Matches[1] }
    return $null
}

function Set-ConfigFileValue {
    param([string]$Path, [string]$Key, [string]$Value)
    $lines = [Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in [IO.File]::ReadAllLines($Path)) { $lines.Add($line) }
    }
    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $matchIndexes = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pattern) { $matchIndexes += $i }
    }
    if ($matchIndexes.Count -gt 1) { throw "$Path 中 $Key 重复定义；拒绝自动覆盖。" }
    if ($matchIndexes.Count -eq 1) {
        $lines[$matchIndexes[0]] = "$Key=$Value"
    } else {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ne '') { $lines.Add('') }
        $lines.Add("$Key=$Value")
    }
    Write-TextFile $Path ($lines -join [Environment]::NewLine)
}

function Remove-ConfigKeys {
    param([string]$Path, [string[]]$Keys)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $keySet = @{}
    foreach ($key in $Keys) { $keySet[$key] = $true }
    $kept = [Collections.Generic.List[string]]::new()
    $changed = $false
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $key = Get-KeyFromLine $line
        if ($key -and $keySet.ContainsKey($key)) { $changed = $true; continue }
        $kept.Add($line)
    }
    if ($changed) { Write-TextFile $Path ($kept -join [Environment]::NewLine) }
    return $changed
}

function Sync-TemplateKeys {
    param([string]$Template, [string]$Target, [string]$Label)
    if (-not (Test-Path -LiteralPath $Template)) { return $false }
    $existing = Read-ConfigFile $Target
    $pending = [Collections.Generic.List[string]]::new()
    $templateSeen = @{}
    foreach ($line in [IO.File]::ReadAllLines($Template)) {
        $key = Get-KeyFromLine $line
        if (-not $key) { continue }
        if ($templateSeen.ContainsKey($key)) { throw "$Label 模板中变量 $key 重复定义；未同步模板。" }
        $templateSeen[$key] = $true
        if (-not $existing.ContainsKey($key)) {
            if ($key -eq 'SOFTWARE_ROOT') { $pending.Add("SOFTWARE_ROOT=$($script:SoftwareRoot)") }
            else { $pending.Add($line) }
        }
    }
    if ($pending.Count -gt 0) {
        $append = [IO.File]::ReadAllText($Target) + [Environment]::NewLine + ($pending -join [Environment]::NewLine) + [Environment]::NewLine
        Write-TextFile $Target $append
        foreach ($line in $pending) {
            $key = Get-KeyFromLine $line
            if ($key) { Write-Host "已补充 $Label 配置项：$key" }
        }
        return $true
    }
    return $false
}

function Protect-SecretFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $acl = [Security.AccessControl.FileSecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $acl.SetOwner($identity.User)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $identity.User,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        ))
        $adminSid = [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
        $systemSid = [Security.Principal.SecurityIdentifier]::new([Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($adminSid, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow))
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($systemSid, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow))
        Set-Acl -LiteralPath $Path -AclObject $acl
    } catch {
        Write-Warning "无法自动限制 .secrets 文件权限，请手动检查：$Path。原因：$($_.Exception.Message)"
    }
}

function Migrate-SensitiveConfig {
    $sensitiveKeys = @('OPENCODE_SERVER_PASSWORD','FRPS_DASHBOARD_USER','FRPS_DASHBOARD_PASSWORD','PORTAINER_ADMIN_PASSWORD','GITHUB_RUNNER_TOKEN','QODER2API_HUB_API_KEY','QODER2API_HUB_HTTP_PROXY','QODER2API_HUB_HTTPS_PROXY','QODER2API_HUB_ALL_PROXY')
    if (-not (Test-Path -LiteralPath $script:GlobalEnv)) { return $false }
    $ordinary = Read-ConfigFile $script:GlobalEnv
    $private = if (Test-Path -LiteralPath $script:GlobalSecrets) { Read-ConfigFile $script:GlobalSecrets } else { @{} }
    $moveKeys = @()
    foreach ($key in $sensitiveKeys) {
        if (-not $ordinary.ContainsKey($key)) { continue }
        $ordinaryValue = [string]$ordinary[$key]
        $privateValue = if ($private.ContainsKey($key)) { [string]$private[$key] } else { '' }
        if (-not [string]::IsNullOrEmpty($ordinaryValue) -or -not $private.ContainsKey($key) -or [string]::IsNullOrEmpty($privateValue)) {
            Set-ConfigFileValue $script:GlobalSecrets $key $ordinaryValue
        }
        $moveKeys += $key
        Write-Host "已迁移敏感配置：$key -> .secrets"
    }
    if ($moveKeys.Count -gt 0) { [void](Remove-ConfigKeys $script:GlobalEnv $moveKeys) }
    return ($moveKeys.Count -gt 0)
}

function Migrate-LegacyDefaults {
    $changed = $false
    $envValues = Read-ConfigFile $script:GlobalEnv
    $portMigrations = @(
        @('EASYTIER_PORT', '11010', '7005'),
        @('EASYTIER_RPC_PORT', '15888', '7006'),
        @('EASYTIER_WEB_PORT', '11211', '7007'),
        @('EASYTIER_CONFIG_PORT', '22020', '7008')
    )
    foreach ($item in $portMigrations) {
        $key = $item[0]
        if ($envValues.ContainsKey($key) -and $envValues[$key] -eq $item[1]) {
            Set-ConfigFileValue $script:GlobalEnv $key $item[2]
            Write-Host "已迁移 EasyTier 默认端口：$key $($item[1]) -> $($item[2])"
            $changed = $true
        }
    }
    $envValues = Read-ConfigFile $script:GlobalEnv
    if ($envValues.ContainsKey('EASYTIER_WEB_API_HOST') -and $envValues['EASYTIER_WEB_API_HOST'] -match ':11211$') {
        Set-ConfigFileValue $script:GlobalEnv 'EASYTIER_WEB_API_HOST' ($envValues['EASYTIER_WEB_API_HOST'] -replace ':11211$', ':7007')
        $changed = $true
    }
    if ($envValues.ContainsKey('EASYTIER_CONFIG_SERVER') -and $envValues['EASYTIER_CONFIG_SERVER'] -match ':22020/') {
        Set-ConfigFileValue $script:GlobalEnv 'EASYTIER_CONFIG_SERVER' ($envValues['EASYTIER_CONFIG_SERVER'] -replace ':22020/', ':7008/')
        $changed = $true
    }
    $envValues = Read-ConfigFile $script:GlobalEnv
    if ($envValues.ContainsKey('FLATNAS_HTTP_PORT') -and $envValues['FLATNAS_HTTP_PORT'] -eq '23000') {
        [void](Remove-ConfigKeys $script:GlobalEnv @('FLATNAS_HTTP_PORT'))
        Set-ConfigFileValue $script:GlobalEnv 'FLATNAS_HTTP_PORT' '7009'
        Write-Host '已迁移 FlatNas 旧默认端口：23000 -> 7009。'
        $changed = $true
    }
    return $changed
}

function Ensure-GlobalConfig {
    $created = $false
    $updated = $false
    New-Item -ItemType Directory -Path $script:SoftwareRoot, $script:GlobalEnvDir -Force | Out-Null
    if (-not (Test-Path -LiteralPath $script:GlobalEnv)) {
        $template = Join-Path $script:RootDir '.env.example'
        if (-not (Test-Path -LiteralPath $template)) { throw "统一环境变量模板不存在：$template" }
        Copy-Item -LiteralPath $template -Destination $script:GlobalEnv
        Set-ConfigFileValue $script:GlobalEnv 'SOFTWARE_ROOT' $script:SoftwareRoot
        Write-Host "已创建普通配置：$($script:GlobalEnv)"
        $created = $true
    }
    if (-not (Test-Path -LiteralPath $script:GlobalSecrets)) {
        $template = Join-Path $script:RootDir '.secrets.example'
        if (-not (Test-Path -LiteralPath $template)) { throw "敏感配置模板不存在：$template" }
        Copy-Item -LiteralPath $template -Destination $script:GlobalSecrets
        Write-Host "已创建敏感配置：$($script:GlobalSecrets)"
        $created = $true
    }
    $updated = (Sync-TemplateKeys (Join-Path $script:RootDir '.env.example') $script:GlobalEnv '.env') -or $updated
    $updated = (Sync-TemplateKeys (Join-Path $script:RootDir '.secrets.example') $script:GlobalSecrets '.secrets') -or $updated
    $deprecated = @(
        'PORTAINER_HTTP_CONTAINER_PORT','OPENCODE_VERSION','FRPS_IMAGE','PORTAINER_IMAGE',
        'FRPS_VHOST_HTTP_PORT','FRPS_VHOST_HTTPS_PORT','FRPS_HTTP_PUBLIC_PORT','FRPS_HTTPS_PUBLIC_PORT',
        'EASYTIER_WEB_USERNAME','EASYTIER_MODE','EASYTIER_PEERS','EASYTIER_NETWORK_NAME',
        'EASYTIER_NETWORK_SECRET','GITHUB_RUNNER_VERSION','GITHUB_RUNNER_WORKDIR',
        'EASYHOSTAGENT_RELEASE','EASYNETTOPO_IMAGE','OPENHANDS_IMAGE','EASYTIER_IMAGE',
        'EASYTIER_EXECUTOR_IMAGE','WEBTOP_IMAGE','QODER2API_HUB_IMAGE','MIHOMO_IMAGE',
        'FLATNAS_IMAGE','SUB2API_IMAGE','SUB2API_POSTGRES_IMAGE','SUB2API_REDIS_IMAGE',
        'OPENCODE_BASE_IMAGE','OPENCODE_LOCAL_IMAGE','OPENCODE_CLI_VERSION',
        'MIHOMO_NODE_VERSION','MIHOMO_METACUBEXD_VERSION','MIHOMO_KERNEL_VERSION'
    )
    $updated = (Remove-ConfigKeys $script:GlobalEnv $deprecated) -or $updated
    $updated = (Remove-ConfigKeys $script:GlobalSecrets $deprecated) -or $updated
    $updated = (Migrate-LegacyDefaults) -or $updated
    $updated = (Migrate-SensitiveConfig) -or $updated
    Protect-SecretFile $script:GlobalSecrets

    $configured = Read-ConfigFile $script:GlobalEnv
    if ($configured.ContainsKey('SOFTWARE_ROOT')) {
        $configuredRoot = Normalize-Path $configured['SOFTWARE_ROOT']
        if (-not [string]::Equals($configuredRoot, $script:SoftwareRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "配置错误：$($script:GlobalEnv) 中 SOFTWARE_ROOT 与实际配置目录不一致。请设置环境变量 SOFTWARE_ROOT 指向配置所在目录，避免覆盖或迁移错误数据。"
        }
    }
    return [pscustomobject]@{ Created = $created; Updated = $updated }
}

function Initialize-Paths {
    $requestedRoot = [Environment]::GetEnvironmentVariable('SOFTWARE_ROOT', 'Process')
    if ([string]::IsNullOrWhiteSpace($requestedRoot)) {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw '无法确定 Windows 软件目录；请设置 SOFTWARE_ROOT 后重试。' }
        $requestedRoot = Join-Path $env:LOCALAPPDATA 'CiBeDerORG\deploy\software'
    }
    $script:SoftwareRoot = Normalize-Path $requestedRoot
    $script:GlobalEnvDir = Join-Path $script:SoftwareRoot 'deploy'
    $script:GlobalEnv = Join-Path $script:GlobalEnvDir '.env'
    $script:GlobalSecrets = Join-Path $script:GlobalEnvDir '.secrets'
    if (Test-Path -LiteralPath $script:GlobalEnv) {
        $values = Read-ConfigFile $script:GlobalEnv
        if ($values.ContainsKey('SOFTWARE_ROOT') -and -not [string]::IsNullOrWhiteSpace($values['SOFTWARE_ROOT'])) {
            $configuredRoot = Normalize-Path $values['SOFTWARE_ROOT']
            if (-not [string]::Equals($configuredRoot, $script:SoftwareRoot, [StringComparison]::OrdinalIgnoreCase)) {
                throw "配置路径不一致：$($script:GlobalEnv) 中的 SOFTWARE_ROOT 与当前软件目录不同。请通过环境变量 SOFTWARE_ROOT 指定正确目录，或先手动迁移整个软件目录。"
            }
        }
    }
}

# 应用模板由 YAML 定义生成；仅初始化缺失项，旧全局配置作为迁移来源保留。
function Initialize-AppConfiguration {
    param([string]$Task)
    $script:AppEnv = ''; $script:AppSecrets = ''
    $base = Join-Path $script:SoftwareRoot $Task
    $templateDir = Join-Path $base 'deploy'
    if (-not (Test-Path -LiteralPath (Join-Path $templateDir 'config.env.example'))) { return }
    $directory = Join-Path $base 'config'
    foreach ($path in @($base, $directory)) {
        if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw '应用配置目录不能是符号链接。' }
    }
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    foreach ($kind in @('env','secrets')) {
        $templatePath = Join-Path $templateDir "config.$kind.example"
        $target = Join-Path $directory ".$kind"
        $oldPath = if ($kind -eq 'env') { $script:GlobalEnv } else { $script:GlobalSecrets }
        foreach ($path in @($templatePath, $target, $oldPath)) {
            if (Test-Path -LiteralPath $path) {
                $item = Get-Item -LiteralPath $path -Force
                if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw '应用配置必须是普通文件，不能是符号链接。' }
            }
        }
        if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { throw '缺少应用配置默认值模板。' }
        $template = Read-ConfigFile $templatePath
        $current = if (Test-Path -LiteralPath $target) { Read-ConfigFile $target } else { @{} }
        $old = if (Test-Path -LiteralPath $oldPath) { Read-ConfigFile $oldPath } else { @{} }
        if (-not (Test-Path -LiteralPath $target)) { Write-TextFile $target '' }
        Protect-SecretFile $target
        foreach ($key in $template.Keys) {
            if ($current.ContainsKey($key)) { continue }
            $value = if ($old.ContainsKey($key)) { $old[$key] } else { $template[$key] }
            Set-ConfigFileValue $target $key ('"' + $value + '"')
        }
        Protect-SecretFile $target
        if ($kind -eq 'env') { $script:AppEnv = $target } else { $script:AppSecrets = $target }
    }
}

function Load-Configuration {
    $ordinary = Read-ConfigFile $script:GlobalEnv
    $private = Read-ConfigFile $script:GlobalSecrets
    $merged = @{}
    foreach ($key in $ordinary.Keys) { $merged[$key] = $ordinary[$key] }
    foreach ($key in $private.Keys) { $merged[$key] = $private[$key] }
    foreach ($path in @($script:AppEnv, $script:AppSecrets)) {
        if ($path) { $appConfig = Read-ConfigFile $path; foreach ($key in $appConfig.Keys) { $merged[$key] = $appConfig[$key] } }
    }
    $script:Config = $merged
    foreach ($key in $merged.Keys) {
        [Environment]::SetEnvironmentVariable([string]$key, [string]$merged[$key], 'Process')
    }
    [Environment]::SetEnvironmentVariable('SOFTWARE_ROOT', $script:SoftwareRoot, 'Process')
}

function Get-ConfigValue {
    param([string]$Key, [string]$Default = '')
    $value = [Environment]::GetEnvironmentVariable($Key, 'Process')
    if ([string]::IsNullOrEmpty($value)) { return $Default }
    return $value
}

function Set-ConfigValue {
    param([string]$File, [string]$Key, [string]$Value)
    Set-ConfigFileValue $File $Key $Value
    [Environment]::SetEnvironmentVariable($Key, $Value, 'Process')
    $script:Config[$Key] = $Value
    if ($File -eq $script:GlobalSecrets -or $File -eq $script:AppSecrets) { Protect-SecretFile $File }
}

function New-HexSecret {
    param([int]$Bytes = 32)
    $buffer = [byte[]]::new($Bytes)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
    return (($buffer | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Ensure-HexSecret {
    param([string]$Key)
    $value = Get-ConfigValue $Key
    if (-not [string]::IsNullOrEmpty($value)) { return }
    $value = New-HexSecret 32
    $target = if ($script:AppSecrets) { $script:AppSecrets } else { $script:GlobalSecrets }
    Set-ConfigValue $target $Key $value
    Write-Host "已在 .secrets 中生成并持久化 $Key（值不显示）。"
}

function Get-TaskNames {
    $tasks = @()
    foreach ($directory in Get-ChildItem -LiteralPath $script:RootDir -Directory) {
        if (Test-Path -LiteralPath (Join-Path $directory.FullName 'deploy\install.sh')) { $tasks += $directory.Name }
    }
    return @($tasks | Sort-Object)
}

function List-Tasks {
    $tasks = Get-TaskNames
    if ($tasks.Count -eq 0) { Write-Host '没有发现可安装业务：期望目录结构为 <业务类型>/deploy/install.sh'; return }
    Write-Host ''
    Write-Host ('{0,-5} {1,-32} {2}' -f '编号', '业务类型', '部署类型')
    for ($i = 0; $i -lt $tasks.Count; $i++) {
        $compose = Join-Path (Join-Path (Join-Path $script:RootDir $tasks[$i]) 'deploy') 'docker-compose.yaml'
        $mode = if (Test-Path -LiteralPath $compose) { 'Docker Compose（PowerShell）' } else { 'Linux/systemd 或其他' }
        Write-Host ('{0,-5} {1,-32} {2}' -f ($i + 1), $tasks[$i], $mode)
    }
    Write-Host ''
}

function Resolve-Task {
    param([string]$Choice)
    $tasks = Get-TaskNames
    if ($Choice -match '^\d+$') {
        $index = [int]$Choice
        if ($index -ge 1 -and $index -le $tasks.Count) { return $tasks[$index - 1] }
    }
    foreach ($task in $tasks) { if ($task -eq $Choice) { return $task } }
    throw "未知业务类型：$Choice"
}

function Sync-SharedLibrary {
    foreach ($module in @('image-sources.sh','versions.sh')) {
        $source = Join-Path (Join-Path $script:RootDir 'lib') $module
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "公共模块不存在：$source" }
        $target = Join-Path (Join-Path $script:GlobalEnvDir 'lib') $module
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        if (-not (Test-Path -LiteralPath $target) -or (Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $target).Hash) {
            Copy-Item -LiteralPath $source -Destination $target -Force
        }
    }
    $source = Join-Path $script:RootDir 'versions.env'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "仓库版本文件不存在：$source" }
    $target = Join-Path $script:GlobalEnvDir 'versions.env'
    if (-not (Test-Path -LiteralPath $target) -or (Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $target).Hash) {
        Copy-Item -LiteralPath $source -Destination $target -Force
    }
}

function Sync-Task {
    param([string]$Task)
    $sourceDir = Join-Path $script:RootDir $Task
    $targetDir = Join-Path $script:SoftwareRoot $Task
    if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) { throw "源目录不存在：$sourceDir" }
    Sync-SharedLibrary
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    $excludeRoots = @('data','state','workspace','backup')
    $sourcePrefix = $sourceDir.TrimEnd([char[]]@('\','/'))
    foreach ($file in Get-ChildItem -LiteralPath $sourceDir -Force -Recurse -File) {
        $relative = $file.FullName.Substring($sourcePrefix.Length).TrimStart([char[]]@('\','/')).Replace('\','/')
        $segments = $relative.Split('/')
        if ($segments.Count -gt 0 -and $excludeRoots -contains $segments[0]) { continue }
        if ($relative -in @('deploy/.env','deploy/.secrets','config/.env','config/.secrets')) { continue }
        if ($segments[0] -eq 'config') {
            $current = $targetDir
            foreach ($part in $segments) {
                $current = Join-Path $current $part
                if ((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw '配置路径不能经过符号链接。' }
            }
            if (Test-Path -LiteralPath $current) { continue }
        }
        if ($Task -eq 'mihomo' -and $segments[0] -eq 'runtime') { continue }
        $destination = Join-Path $targetDir ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    }
    if ($Task -eq 'mihomo') {
        foreach ($relative in @('deploy/lib.sh','deploy/config.example.yaml','deploy/profile.example.yaml','tests/password-config.sh','tests/all-in-one.sh')) {
            $path = Join-Path $targetDir ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
            if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
        }
    }
    Write-Host "已同步：$sourceDir -> $targetDir（保留运行数据、状态和敏感配置）"
}

function Invoke-Docker {
    param([string[]]$DockerArgs)
    & docker @DockerArgs
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "docker $($DockerArgs -join ' ') 执行失败，退出码：$code" }
}

function Get-DockerOutput {
    param([string[]]$DockerArgs)
    $output = & docker @DockerArgs 2>$null
    $code = $LASTEXITCODE
    if ($code -ne 0) { return $null }
    return (($output | Out-String).Trim())
}

function Check-DockerRuntime {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw '未检测到 Docker CLI。请安装并启动 Docker Desktop。' }
    if ($null -eq (Get-DockerOutput @('info'))) { throw 'Docker Engine 不可用。请启动 Docker Desktop 并等待引擎就绪。' }
    if ($null -eq (Get-DockerOutput @('compose','version'))) { throw '未检测到 Docker Compose v2。请更新 Docker Desktop。' }
}

function Get-ComposeBaseArgs {
    param([string]$Task, [switch]$SocketOverride)
    $deployDir = Join-Path (Join-Path $script:SoftwareRoot $Task) 'deploy'
    $composeFile = Join-Path $deployDir 'docker-compose.yaml'
    if (-not (Test-Path -LiteralPath $composeFile)) {
        throw "$Task 没有 Docker Compose 文件；此 PowerShell 入口只原生管理 Docker Compose 服务，不执行 Linux/systemd 或 OpenWrt 脚本。"
    }
    $envFile = if ($script:AppEnv) { $script:AppEnv } else { $script:GlobalEnv }
    $arguments = @('compose','--project-directory',$deployDir,'--file',$composeFile,'--env-file',$envFile)
    if ($SocketOverride) {
        $socketFile = Join-Path $deployDir 'docker-compose.socket.yaml'
        if (-not (Test-Path -LiteralPath $socketFile)) { throw "Docker Socket 扩展配置不存在：$socketFile" }
        $arguments += @('--file',$socketFile)
    }
    return ,$arguments
}

function Invoke-Compose {
    param([string]$Task, [string[]]$ComposeArgs, [switch]$SocketOverride)
    $baseArgs = Get-ComposeBaseArgs -Task $Task -SocketOverride:$SocketOverride
    $arguments = @()
    $arguments += $baseArgs
    $arguments += $ComposeArgs
    Write-Host ('> docker ' + ($arguments -join ' '))
    Invoke-Docker $arguments
}

function Test-ContainerExists {
    param([string]$Name)
    return ($null -ne (Get-DockerOutput @('container','inspect',$Name)))
}

function Get-ComposeProjectName {
    param([string]$Task)
    $composeFile = Join-Path (Join-Path (Join-Path $script:SoftwareRoot $Task) 'deploy') 'docker-compose.yaml'
    if (Test-Path -LiteralPath $composeFile) {
        $match = Select-String -LiteralPath $composeFile -Pattern '^name:\s*([A-Za-z0-9_.-]+)\s*$' | Select-Object -First 1
        if ($match) { return $match.Matches[0].Groups[1].Value }
    }
    return 'deploy'
}

function Assert-ContainerOwner {
    param([string]$Name, [string]$ExpectedProject)
    if (-not (Test-ContainerExists $Name)) { return }
    $actual = Get-DockerOutput @('inspect','--format','{{ index .Config.Labels "com.docker.compose.project" }}',$Name)
    if ($actual -ne $ExpectedProject) {
        throw "已有同名容器 $Name，但 Compose 项目为 '$actual'，预期 '$ExpectedProject'。为保护现有容器和数据，拒绝接管或删除。"
    }
}

function Load-RepositoryVersions {
    # The tracked versions.env is the sole source of image and native release versions.
    # It is synchronized automatically by Sync-Task, not copied from .env.example.
    $path = Join-Path $script:GlobalEnvDir 'versions.env'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "仓库版本文件不存在：$path" }
    $versions = Read-ConfigFile $path
    $required = @(
        'EASYHOSTAGENT_RELEASE','GITHUB_RUNNER_VERSION','EASYNETTOPO_IMAGE',
        'EASYTIER_IMAGE','EASYTIER_EXECUTOR_IMAGE','FRPS_IMAGE','PORTAINER_IMAGE',
        'FLATNAS_IMAGE','WEBTOP_IMAGE','OPENHANDS_IMAGE','QODER2API_HUB_IMAGE',
        'MIHOMO_IMAGE','SUB2API_IMAGE','SUB2API_POSTGRES_IMAGE','SUB2API_REDIS_IMAGE',
        'OPENCODE_BASE_IMAGE','OPENCODE_LOCAL_IMAGE','OPENCODE_CLI_VERSION',
        'MIHOMO_METACUBEXD_VERSION','MIHOMO_KERNEL_VERSION','MIHOMO_NODE_VERSION'
    )
    foreach ($key in $versions.Keys) {
        if ($required -notcontains $key) { throw "仓库版本文件含未知键：$key" }
    }
    foreach ($key in $required) {
        if (-not $versions.ContainsKey($key)) { throw "仓库版本文件缺少：$key" }
        $value = [string]$versions[$key]
        if ($value -notmatch '^[A-Za-z0-9._:/@+-]+
    param([string]$Task)
    $sourceMode = Get-ConfigValue 'DOCKER_IMAGE_SOURCE' 'original'
    if ($sourceMode -notin @('original','mirror')) { throw 'DOCKER_IMAGE_SOURCE 只能是 original 或 mirror。' }
    if ($sourceMode -eq 'original') { return }

    $key = ''
    $image = ''
    switch ($Task) {
        frps {
            $key = 'DEPLOY_FRPS_IMAGE'
            $image = Get-ConfigValue 'FRPS_IMAGE'
        }
        easytier {
            $key = 'DEPLOY_EASYTIER_IMAGE'
            $image = Get-ConfigValue 'EASYTIER_IMAGE'
        }
        'easytier-automation-executor' {
            $key = 'DEPLOY_EASYTIER_EXECUTOR_IMAGE'
            $image = Get-ConfigValue 'EASYTIER_EXECUTOR_IMAGE'
        }
        'qoder2api-hub' {
            $key = 'DEPLOY_QODER2API_HUB_IMAGE'
            $image = Get-ConfigValue 'QODER2API_HUB_IMAGE'
        }
        mihomo {
            $key = 'DEPLOY_MIHOMO_IMAGE'
            $image = Get-ConfigValue 'MIHOMO_IMAGE'
        }
        default { return }
    }
    if (-not $image.StartsWith('ghcr.io/', [StringComparison]::OrdinalIgnoreCase)) { return }

    $providers = @( (Get-ConfigValue 'DOCKER_IMAGE_MIRRORS' 'dockerproxy,ghproxy').Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } )
    $allowed = @('dockerproxy','ghproxy','nju','1ms','daocloud')
    foreach ($providerName in $providers) {
        if ($providerName -notin $allowed) { throw "DOCKER_IMAGE_MIRRORS 中不支持的站点：$providerName" }
    }
    $providers = @($providers | Select-Object -Unique)
    if ($providers.Count -eq 0) { throw 'DOCKER_IMAGE_MIRRORS 没有有效候选站。' }

    $stateDir = Join-Path $script:GlobalEnvDir 'state'
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $stateFile = Join-Path $stateDir 'image-mirror.last'
    $lockFile = "$stateFile.lock"
    $lock = $null
    $deadline = (Get-Date).AddSeconds(10)
    while (-not $lock) {
        try { $lock = [IO.File]::Open($lockFile,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
        catch {
            if ((Get-Date) -gt $deadline) { throw '镜像源轮换状态正被其他部署占用，请稍后重试。' }
            Start-Sleep -Milliseconds 200
        }
    }
    try {
        $previous = ''
        if (Test-Path -LiteralPath $stateFile) { $previous = [IO.File]::ReadAllText($stateFile).Trim() }
        $previousIndex = [Array]::IndexOf([string[]]$providers, $previous)
        $index = if ($previousIndex -lt 0) { 0 } else { ($previousIndex + 1) % $providers.Count }
        $provider = $providers[$index]
        Write-TextFile $stateFile $provider
    } finally { $lock.Dispose() }

    $path = $image.Substring('ghcr.io/'.Length)
    switch ($provider) {
        dockerproxy { $rewritten = "ghcr.dockerproxy.net/$path" }
        ghproxy { $rewritten = "gh-proxy.com/docker/ghcr.io/$path" }
        nju { $rewritten = "ghcr.nju.edu.cn/$path" }
        '1ms' { $rewritten = "ghcr.1ms.run/$path" }
        daocloud { $rewritten = "m.daocloud.io/ghcr.io/$path" }
    }
    [Environment]::SetEnvironmentVariable($key, $rewritten, 'Process')
    Write-Host "本次 GHCR 镜像源：$provider"
}
function Ensure-TaskDirectories {
    param([string]$Task)
    $base = Join-Path $script:SoftwareRoot $Task
    $dirs = switch ($Task) {
        opencode { @('config','data','state','workspace') }
        frps { @('config','data') }
        easytier { @('data\core','data\cloud-managed-core','data\web') }
        'easytier-automation-executor' { @('data','data\runtime','data\adb') }
        portainer { @('data') }
        flatnas { @('data','music','PC','APP','doc') }
        sub2api { @('data\app','data\postgres','data\redis') }
        'qoder2api-hub' { @('data\accounts','data\usage') }
        mihomo { @('data') }
        default { @('data') }
    }
    foreach ($relative in $dirs) { New-Item -ItemType Directory -Path (Join-Path $base $relative) -Force | Out-Null }
}

function Test-IPv4 {
    param([string]$Name, [string]$Value)
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Value, [ref]$parsed) -or $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw "$Name 必须是有效 IPv4 地址。"
    }
}

function Test-Port {
    param([string]$Name, [string]$Value)
    $number = 0
    if (-not [int]::TryParse($Value, [ref]$number) -or $number -lt 1 -or $number -gt 65535) {
        throw "$Name 必须是 1-65535 的数字端口。"
    }
    return $number
}

function Replace-ManagedBlock {
    param([string]$Path, [string]$BeginMarker, [string]$EndMarker, [string[]]$ReplacementLines)
    $lines = [IO.File]::ReadAllLines($Path)
    $begin = -1
    $end = -1
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -ceq $BeginMarker) { $begin = $i }
        if ($lines[$i] -ceq $EndMarker) { $end = $i }
    }
    if ($begin -lt 0 -or $end -le $begin) { throw "缺少动态区块标记：$BeginMarker / $EndMarker（$Path）" }
    $output = [Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($i -eq $begin) {
            $output.Add($lines[$i])
            foreach ($replacement in $ReplacementLines) { $output.Add([string]$replacement) }
            $i = $end - 1
            continue
        }
        $output.Add($lines[$i])
    }
    Write-TextFile $Path ($output -join [Environment]::NewLine)
}

function Prepare-Frps {
    param([string]$Task, [string]$Mode)
    $base = Join-Path $script:SoftwareRoot $Task
    $configFile = Join-Path $base 'config\frps.toml'
    $composeFile = Join-Path $base 'deploy\docker-compose.yaml'
    if (-not (Test-Path -LiteralPath $configFile)) { throw "FRPS 配置文件不存在：$configFile" }
    $bind = Test-Port 'FRPS_BIND_PORT' (Get-ConfigValue 'FRPS_BIND_PORT' '7000')
    $dashboard = Test-Port 'FRPS_DASHBOARD_PORT' (Get-ConfigValue 'FRPS_DASHBOARD_PORT' '7001')
    if ($bind -eq $dashboard -or @($bind,$dashboard) -contains 80 -or @($bind,$dashboard) -contains 443 -or @($bind,$dashboard) -contains 9080 -or @($bind,$dashboard) -contains 9443) {
        throw 'FRPS bind/dashboard 端口冲突：不能重复，也不能占用 80/443/9080/9443。'
    }
    $raw = Get-ConfigValue 'FRPS_PROXY_PORTS' '["3389","7100-7800"]'
    try { $items = @($raw | ConvertFrom-Json -ErrorAction Stop) } catch { throw 'FRPS_PROXY_PORTS 必须是 JSON 数组，例如 ["3389","7100-7800"]。' }
    if ($items.Count -eq 0) { throw 'FRPS_PROXY_PORTS 不能为空数组。' }
    $seenItems = @{}
    $seenPorts = @{}
    $tomlLines = [Collections.Generic.List[string]]::new()
    $composeLines = [Collections.Generic.List[string]]::new()
    foreach ($itemValue in $items) {
        $item = [string]$itemValue
        if ($seenItems.ContainsKey($item)) { throw "FRPS_PROXY_PORTS 存在重复项：$item" }
        $seenItems[$item] = $true
        if ($item -match '^(\d+)$') {
            $start = Test-Port 'FRPS_PROXY_PORTS 单端口' $Matches[1]
            $end = $start
            $tomlLines.Add("    { single = $start },")
            $composeLines.Add(('      - "' + $start + ':' + $start + '"'))
        } elseif ($item -match '^(\d+)-(\d+)$') {
            $start = Test-Port 'FRPS_PROXY_PORTS 范围起始端口' $Matches[1]
            $end = Test-Port 'FRPS_PROXY_PORTS 范围结束端口' $Matches[2]
            if ($start -gt $end) { throw "FRPS_PROXY_PORTS 范围起始端口大于结束端口：$item" }
            $tomlLines.Add("    { start = $start, end = $end },")
            $composeLines.Add(('      - "' + $start + '-' + $end + ':' + $start + '-' + $end + '"'))
        } else { throw "FRPS_PROXY_PORTS 非法项：$item，只支持单端口或范围。" }
        for ($port = $start; $port -le $end; $port++) {
            if (@($bind,$dashboard,80,443,9080,9443) -contains $port) { throw "FRPS_PROXY_PORTS 包含保留端口 $port。" }
            if ($seenPorts.ContainsKey([string]$port)) { throw "FRPS_PROXY_PORTS 存在重复或重叠端口：$port" }
            $seenPorts[[string]$port] = $true
        }
    }
    $tomlBlock = @('allowPorts = [') + @($tomlLines) + @(']')
    Replace-ManagedBlock $configFile '# BEGIN FRPS_PROXY_PORTS' '# END FRPS_PROXY_PORTS' $tomlBlock
    $toml = [IO.File]::ReadAllText($configFile)
    $toml = [regex]::Replace($toml, '(?m)^bindPort\s*=\s*\d+\s*$', "bindPort = $bind")
    $toml = [regex]::Replace($toml, '(?m)^webServer\.port\s*=\s*\d+\s*$', "webServer.port = $dashboard")
    Write-TextFile $configFile $toml

    Replace-ManagedBlock $composeFile '      # BEGIN FRPS_PROXY_PORTS' '      # END FRPS_PROXY_PORTS' @($composeLines)
    $compose = [IO.File]::ReadAllText($composeFile)
    $compose = [regex]::Replace($compose, '(?m)^(\s*-\s*")[0-9]+:[0-9]+(" # FRPS_BIND_PORT)\s*$', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + $bind.ToString() + ':' + $bind.ToString() + $m.Groups[2].Value })
    $compose = [regex]::Replace($compose, '(?m)^(\s*-\s*")[0-9]+:[0-9]+(" # FRPS_DASHBOARD_PORT)\s*$', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + $dashboard.ToString() + ':' + $dashboard.ToString() + $m.Groups[2].Value })
    $compose = [regex]::Replace($compose, 'http://127\.0\.0\.1:\d+/healthz', "http://127.0.0.1:$dashboard/healthz")
    Write-TextFile $composeFile $compose

    if ($Mode -eq 'update') {
        $clients = Join-Path $base 'data\clients.json'
        if (Test-Path -LiteralPath $clients) {
            $backupDir = Join-Path $base 'data\backup'
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            $backup = Join-Path $backupDir ("clients-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
            Copy-Item -LiteralPath $clients -Destination $backup
            Write-Host "已备份 FRPS clients.json：$backup"
        }
    }
}

function Prepare-Mihomo {
    param([string]$Task)
    foreach ($key in @('MIHOMO_API_SECRET','MIHOMO_CONTROL_TOKEN')) { Ensure-HexSecret $key }
    $mixed = Test-Port 'MIHOMO_MIXED_PORT' (Get-ConfigValue 'MIHOMO_MIXED_PORT' '7011')
    $web = Test-Port 'MIHOMO_API_PORT' (Get-ConfigValue 'MIHOMO_API_PORT' '7012')
    $core = Test-Port 'MIHOMO_CORE_API_PORT' (Get-ConfigValue 'MIHOMO_CORE_API_PORT' '7013')
    if ($mixed -eq $web -or $mixed -eq $core -or $web -eq $core) { throw 'Mihomo 代理、Web/Agent、内核 API 端口不能冲突。' }
    foreach ($entry in @(
        @('MIHOMO_PROXY_BIND_IP',(Get-ConfigValue 'MIHOMO_PROXY_BIND_IP' '127.0.0.1')),
        @('MIHOMO_API_BIND_IP',(Get-ConfigValue 'MIHOMO_API_BIND_IP' '0.0.0.0')),
        @('MIHOMO_CORE_API_BIND_IP',(Get-ConfigValue 'MIHOMO_CORE_API_BIND_IP' '0.0.0.0'))
    )) { Test-IPv4 $entry[0] $entry[1] }

    $base = Join-Path $script:SoftwareRoot $Task
    $network = Get-DockerOutput @('network','inspect','proxy-net')
    if ($null -eq $network) {
        Invoke-Docker @('network','create','--driver','bridge','--internal','--label','org.cibeder.deploy.role=mihomo-proxy','proxy-net') | Out-Null
        Write-Host '已创建 Mihomo 内部代理网络 proxy-net。'
    } else {
        $driver = Get-DockerOutput @('network','inspect','--format','{{.Driver}}','proxy-net')
        $internal = Get-DockerOutput @('network','inspect','--format','{{.Internal}}','proxy-net')
        $scope = Get-DockerOutput @('network','inspect','--format','{{.Scope}}','proxy-net')
        if ($driver -ne 'bridge' -or $internal -ne 'true' -or $scope -ne 'local') { throw '已有同名 proxy-net 不是 local internal bridge，拒绝接管。' }
    }

    $data = Join-Path $base 'data'
    $final = Join-Path $data 'all-in-one'
    $old = Join-Path $data 'config.yaml'
    if ((Test-Path -LiteralPath $final) -and (Test-Path -LiteralPath (Join-Path $final 'profiles\index.json')) -and (Test-Path -LiteralPath (Join-Path $final 'active.yaml'))) {
        Write-Host '检测到已有 Mihomo All-in-One 配置，保留所有配置和凭据。'
        return
    }
    if (Test-Path -LiteralPath $final) {
        $entries = @(Get-ChildItem -LiteralPath $final -Force -ErrorAction SilentlyContinue)
        if ($entries.Count -gt 0) { throw "Mihomo 数据目录不完整：$final。拒绝覆盖。" }
        Remove-Item -LiteralPath $final -Force
    }
    $template = Join-Path $base 'deploy\default-profile.yaml'
    if (-not (Test-Path -LiteralPath $template)) { throw "Mihomo 初始 Profile 模板不存在：$template" }
    $staging = Join-Path $data ('.aio-stage-' + [Guid]::NewGuid().ToString('N'))
    $profiles = Join-Path $staging 'profiles'
    New-Item -ItemType Directory -Path $profiles -Force | Out-Null
    $initial = Join-Path $profiles 'deploy-initial.yaml'
    if (Test-Path -LiteralPath $old) {
        Copy-Item -LiteralPath $old -Destination $initial
        $profileText = [IO.File]::ReadAllText($initial)
        $profileText = [regex]::Replace($profileText, '(?m)^external-ui(?:-url)?\s*:.*(?:\r?\n)?', '')
        Write-TextFile $initial $profileText
        $authMatch = [regex]::Match($profileText, '(?ms)^authentication\s*:\s*\r?\n(?:(?:[ \t].*|[ \t]*\r?\n))*')
        if ($authMatch.Success) { Write-TextFile (Join-Path $profiles 'deploy-proxy-auth.yaml') $authMatch.Value }
        $backupDir = Join-Path $data 'backup\pre-all-in-one'
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        $backup = Join-Path $backupDir 'config.yaml'
        if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $old -Destination $backup }
        Write-Host '旧 config.yaml 已保留，并作为初始 Profile。'
    } else {
        Ensure-HexSecret 'MIHOMO_PROXY_PASSWORD'
        Copy-Item -LiteralPath $template -Destination $initial
        $user = Get-ConfigValue 'MIHOMO_PROXY_USER' 'deploy'
        $password = Get-ConfigValue 'MIHOMO_PROXY_PASSWORD'
        $yamlAuth = ($user + ':' + $password).Replace("'", "''")
        $append = [Environment]::NewLine + 'authentication:' + [Environment]::NewLine + "  - '" + $yamlAuth + "'" + [Environment]::NewLine
        Write-TextFile $initial ([IO.File]::ReadAllText($initial) + $append)
    }
    $origins = @("http://localhost:$web", "http://127.0.0.1:$web")
    try {
        $ips = Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction Stop |
            Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } |
            Select-Object -ExpandProperty IPAddress -Unique
        foreach ($ip in $ips) { $origins += "http://$($ip):$($web)" }
    } catch { }
    $myIp = Get-ConfigValue 'MYAI_IP'
    if ($myIp) {
        Test-IPv4 'MYAI_IP' $myIp
        $origins += "http://$($myIp):$($web)"
    }
    $origins = @($origins | Select-Object -Unique)
    $cors = @('external-controller-cors:','  allow-private-network: true','  allow-origins:') + @($origins | ForEach-Object { "    - '" + $_.Replace("'","''") + "'" })
    Write-TextFile (Join-Path $profiles 'deploy-web-cors.yaml') ($cors -join [Environment]::NewLine)
    $activeText = [IO.File]::ReadAllText($initial)
    if ($activeText -notmatch '(?m)^external-controller-cors\s*:') {
        $activeText = $activeText.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + ($cors -join [Environment]::NewLine) + [Environment]::NewLine
    }
    Write-TextFile (Join-Path $staging 'active.yaml') $activeText
    $hasAuth = Test-Path -LiteralPath (Join-Path $profiles 'deploy-proxy-auth.yaml')
    $index = @(
        [ordered]@{ id='deploy-initial'; name='Deploy initial profile'; type='local'; updatedAt=0 },
        [ordered]@{ id='deploy-web-cors'; name='Deploy trusted Web origins'; type='merge'; enabled=$true; updatedAt=0 }
    )
    if ($hasAuth) { $index += [ordered]@{ id='deploy-proxy-auth'; name='Deploy proxy authentication'; type='merge'; enabled=$true; updatedAt=0 } }
    Write-TextFile (Join-Path $profiles 'index.json') (ConvertTo-Json -InputObject @($index) -Depth 8)
    Write-TextFile (Join-Path $profiles 'state.json') '{"activeId":"deploy-initial"}'
    Move-Item -LiteralPath $staging -Destination $final
    Write-Host "已初始化 Mihomo All-in-One 数据：$final"
}

function Prepare-Task {
    param([string]$Task, [string]$Mode)
    Ensure-TaskDirectories $Task
    switch ($Task) {
        opencode {
            if (-not (Test-Path -LiteralPath (Join-Path $script:SoftwareRoot 'opencode\config\opencode.jsonc'))) { throw 'OpenCode 配置文件 opencode/config/opencode.jsonc 不存在。' }
            if ([string]::IsNullOrWhiteSpace((Get-ConfigValue 'OPENCODE_SERVER_PASSWORD'))) { throw "请先在 $($script:GlobalSecrets) 设置 OPENCODE_SERVER_PASSWORD。" }
            if ([string]::IsNullOrWhiteSpace((Get-ConfigValue 'MYAI_IP'))) { throw "请先在 $($script:GlobalEnv) 设置 MYAI_IP。" }
            foreach ($key in @('BUILD_HTTP_PROXY','BUILD_HTTPS_PROXY')) {
                $proxy = Get-ConfigValue $key
                if ($proxy -match '^https?://(127\.0\.0\.1|localhost):') { throw "$key 不能使用 localhost/127.0.0.1；Docker build 应使用 host.docker.internal。" }
            }
            if ($Mode -eq 'update') {
                $data = Join-Path $script:SoftwareRoot 'opencode\data'
                $backupDir = Join-Path $data ('backup\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
                New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
                $backedUp = $false
                foreach ($file in Get-ChildItem -LiteralPath $data -File -Force -ErrorAction SilentlyContinue) {
                    if ($file.Name -match '\.db(-.*)?$' -or $file.Name -eq 'auth.json') {
                        Copy-Item -LiteralPath $file.FullName -Destination $backupDir
                        $backedUp = $true
                    }
                }
                if (-not $backedUp) { Remove-Item -LiteralPath $backupDir -Force -ErrorAction SilentlyContinue; Write-Host '暂无 OpenCode 数据库/认证文件，跳过备份。' }
                else { Write-Host "已备份 OpenCode 数据：$backupDir" }
            }
            [Environment]::SetEnvironmentVariable('OPENCODE_CACHE_BUST',[DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString(),'Process')
        }
        frps { Prepare-Frps $Task $Mode }
        portainer {
            $null = Test-Port 'PORTAINER_HTTP_PORT' (Get-ConfigValue 'PORTAINER_HTTP_PORT' '7004')
            $password = Get-ConfigValue 'PORTAINER_ADMIN_PASSWORD'
            if ([string]::IsNullOrEmpty($password) -or $password.Length -lt 12) { throw 'PORTAINER_ADMIN_PASSWORD 必须设置且至少 12 个字符，请在 .secrets 中配置。' }
            if ($Mode -eq 'update' -and -not (Test-Path -LiteralPath (Join-Path $script:SoftwareRoot 'portainer\data'))) { throw 'Portainer 数据目录不存在，请先安装。' }
        }
        flatnas {
            $null = Test-Port 'FLATNAS_HTTP_PORT' (Get-ConfigValue 'FLATNAS_HTTP_PORT' '7009')
            Test-IPv4 'FLATNAS_BIND_IP' (Get-ConfigValue 'FLATNAS_BIND_IP' '0.0.0.0')
            if ($Mode -eq 'update' -and -not (Test-ContainerExists 'flatnas')) { throw '未找到已部署的 FlatNas 容器，请先安装。' }
            if ((Get-ConfigValue 'FLATNAS_DOCKER_SOCKET' 'false') -eq 'true') { Write-Warning '已启用 Docker Socket：FlatNas 将获得宿主 Docker 管理权限。' }
        }
        easytier {
            $role = Get-ConfigValue 'EASYTIER_ROLE' 'cloud'
            if ($role -notin @('cloud','intranet')) { throw 'EASYTIER_ROLE 只能是 cloud 或 intranet。' }
            $mainPort = Test-Port 'EASYTIER_PORT' (Get-ConfigValue 'EASYTIER_PORT' '7005')
            $rpcPort = Test-Port 'EASYTIER_RPC_PORT' (Get-ConfigValue 'EASYTIER_RPC_PORT' '7006')
            if ($mainPort -eq $rpcPort) { throw 'EASYTIER_PORT 与 EASYTIER_RPC_PORT 不能重复。' }
            if ($role -eq 'cloud') {
                $webPort = Test-Port 'EASYTIER_WEB_PORT' (Get-ConfigValue 'EASYTIER_WEB_PORT' '7007')
                $configPort = Test-Port 'EASYTIER_CONFIG_PORT' (Get-ConfigValue 'EASYTIER_CONFIG_PORT' '7008')
                if ($mainPort -eq $webPort -or $mainPort -eq $configPort -or $rpcPort -eq $webPort -or $rpcPort -eq $configPort -or $webPort -eq $configPort) { throw 'EasyTier 主端口、RPC、Web、Config 四个端口不能重复。' }
                $registration = Get-ConfigValue 'EASYTIER_WEB_ENABLE_REGISTRATION' 'true'
                if ($registration -notin @('true','false')) { throw 'EASYTIER_WEB_ENABLE_REGISTRATION 只能是 true 或 false。' }
                $hostUrl = Get-ConfigValue 'EASYTIER_WEB_API_HOST'
                if (-not $hostUrl -or $hostUrl -notmatch '^https?://') { throw 'cloud 模式必须在 .env 设置以 http:// 或 https:// 开头的 EASYTIER_WEB_API_HOST。' }
            } else {
                $server = Get-ConfigValue 'EASYTIER_CONFIG_SERVER'
                if (-not $server -or $server -notmatch '^(udp|tcp)://') { throw 'intranet 模式必须设置以 udp:// 或 tcp:// 开头的 EASYTIER_CONFIG_SERVER。' }
            }
            Write-Warning 'EasyTier Compose 使用 host 网络、/dev/net/tun 和 Linux 主机 machine-id；Windows Docker Desktop 的网络/TUN 行为与 Linux 主机不同，请确认 Docker Desktop 支持后再继续。'
        }
        'easytier-automation-executor' {
            $image = Get-ConfigValue 'EASYTIER_EXECUTOR_IMAGE' 'ghcr.io/cibederorg/easytier-automation-executor:feat-automation-center'
            if (-not $image) { throw 'EASYTIER_EXECUTOR_IMAGE 不能为空。' }
            $null = Test-Port 'EASYTIER_EXECUTOR_PORT' (Get-ConfigValue 'EASYTIER_EXECUTOR_PORT' '8766')
            Test-IPv4 'EASYTIER_EXECUTOR_BIND_IP' (Get-ConfigValue 'EASYTIER_EXECUTOR_BIND_IP' '127.0.0.1')
            $callback = Get-ConfigValue 'EASYTIER_EXECUTOR_CALLBACK_URL'
            if ($callback -notmatch '^https?://[^/@?#\s]+(/[^?#\s]*)?$') { throw '必须在 .env 设置可达的 EASYTIER_EXECUTOR_CALLBACK_URL（http/https）。' }
            foreach ($key in @('EASYTIER_EXECUTOR_MAX_RUNNING','EASYTIER_EXECUTOR_MAX_PENDING','EASYTIER_EXECUTOR_MAX_MEDIA_SESSIONS','EASYTIER_EXECUTOR_MAX_MEDIA_STARTING')) {
                $value = Get-ConfigValue $key
                if ($value -notmatch '^[1-9]\d*$') { throw "$key 必须为正整数。" }
            }
            $ttl = 0
            if (-not [int]::TryParse((Get-ConfigValue 'EASYTIER_EXECUTOR_TURN_TTL_SECONDS' '3600'),[ref]$ttl) -or $ttl -lt 1 -or $ttl -gt 86400) { throw 'EASYTIER_EXECUTOR_TURN_TTL_SECONDS 必须在 1-86400 范围内。' }
            $existing = Test-ContainerExists 'easytier-automation-executor'
            if ([string]::IsNullOrEmpty((Get-ConfigValue 'EASYTIER_EXECUTOR_TOKEN'))) {
                $runtime = Join-Path $script:SoftwareRoot 'easytier-automation-executor\data\runtime'
                $adb = Join-Path $script:SoftwareRoot 'easytier-automation-executor\data\adb'
                if ($existing -or @(Get-ChildItem -LiteralPath $runtime -Force -ErrorAction SilentlyContinue).Count -gt 0 -or @(Get-ChildItem -LiteralPath $adb -Force -ErrorAction SilentlyContinue).Count -gt 0) {
                    throw '已有执行器容器/运行记录/ADB 密钥但 Token 为空；请恢复 .secrets 中原有 Token，拒绝自动轮换。'
                }
                Ensure-HexSecret 'EASYTIER_EXECUTOR_TOKEN'
            }
            $token = Get-ConfigValue 'EASYTIER_EXECUTOR_TOKEN'
            if ([Text.Encoding]::UTF8.GetByteCount($token) -lt 32 -or [Text.Encoding]::UTF8.GetByteCount($token) -gt 4096 -or $token -match '[\x00-\x1f]') {
                throw 'EASYTIER_EXECUTOR_TOKEN 必须为 32-4096 字节且不能包含控制字符。'
            }
            $turnSecret = Get-ConfigValue 'EASYTIER_EXECUTOR_TURN_SECRET'
            $turnUrls = Get-ConfigValue 'EASYTIER_EXECUTOR_TURN_URLS' '[]'
            if ($turnSecret -and $turnUrls -eq '[]') { throw '设置 TURN_SECRET 时还必须提供 TURN_URLS。' }
            if (-not $turnSecret -and $turnUrls -ne '[]') { throw '设置 TURN_URLS 时还必须在 .secrets 中提供 TURN_SECRET。' }
            Write-Warning '执行器 Compose 使用 host 网络；请确认 Docker Desktop 已启用 host networking，且执行器可访问配置中的回调地址。'
        }
        sub2api {
            $null = Test-Port 'SUB2API_HTTP_PORT' (Get-ConfigValue 'SUB2API_HTTP_PORT' '7010')
            Test-IPv4 'SUB2API_BIND_IP' (Get-ConfigValue 'SUB2API_BIND_IP' '0.0.0.0')
            foreach ($key in @('SUB2API_POSTGRES_PASSWORD','SUB2API_REDIS_PASSWORD','SUB2API_JWT_SECRET','SUB2API_TOTP_ENCRYPTION_KEY')) { Ensure-HexSecret $key }
            $password = Get-ConfigValue 'SUB2API_ADMIN_PASSWORD'
            if ($password) {
                $length = [Text.Encoding]::UTF8.GetByteCount($password)
                if ($length -lt 8 -or $length -gt 72) { throw 'SUB2API_ADMIN_PASSWORD 必须符合上游要求：8-72 UTF-8 字节。' }
            }
        }
        'qoder2api-hub' {
            $image = Get-ConfigValue 'QODER2API_HUB_IMAGE' 'ghcr.io/shuishuipingan/qoder2api-hub:latest'
            if (-not $image) { throw 'QODER2API_HUB_IMAGE 不能为空。' }
            $null = Test-Port 'QODER2API_HUB_PORT' (Get-ConfigValue 'QODER2API_HUB_PORT' '8790')
            Test-IPv4 'QODER2API_HUB_BIND_IP' (Get-ConfigValue 'QODER2API_HUB_BIND_IP' '127.0.0.1')
        }
        mihomo { Prepare-Mihomo $Task }
        default { }
    }
}

function Get-TaskContainers {
    param([string]$Task)
    switch ($Task) {
        opencode { return @('opencode') }
        frps { return @('frps') }
        easytier { return @('easytier') }
        'easytier-automation-executor' { return @('easytier-automation-executor') }
        portainer { return @('portainer') }
        flatnas { return @('flatnas') }
        sub2api { return @('sub2api','sub2api-postgres','sub2api-redis') }
        'qoder2api-hub' { return @('qoder2api-hub') }
        mihomo { return @('mihomo') }
        default { return @() }
    }
}

function Test-TaskOwnership {
    param([string]$Task)
    $expected = Get-ComposeProjectName $Task
    foreach ($name in (Get-TaskContainers $Task)) { Assert-ContainerOwner $name $expected }
}

function Ensure-ProxyNetwork {
    $network = Get-DockerOutput @('network','inspect','proxy-net')
    if ($null -eq $network) {
        Invoke-Docker @('network','create','--driver','bridge','--internal','--label','org.cibeder.deploy.role=mihomo-proxy','proxy-net') | Out-Null
        Write-Host '已创建 proxy-net。'
        return
    }
    $driver = Get-DockerOutput @('network','inspect','--format','{{.Driver}}','proxy-net')
    $internal = Get-DockerOutput @('network','inspect','--format','{{.Internal}}','proxy-net')
    $scope = Get-DockerOutput @('network','inspect','--format','{{.Scope}}','proxy-net')
    if ($driver -ne 'bridge' -or $internal -ne 'true' -or $scope -ne 'local') { throw '已有同名 proxy-net 不是 local internal bridge，拒绝接管。' }
}

function Invoke-ProxyCommand {
    param([string[]]$Arguments)
    Check-DockerRuntime
    $action = if ($Arguments.Count -gt 0) { $Arguments[0] } else { '' }
    $target = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
    switch ($action) {
        ensure {
            if ($Arguments.Count -ne 1) { throw '用法：.\deploy.ps1 proxy ensure' }
            Ensure-ProxyNetwork
        }
        connect {
            if ($Arguments.Count -ne 2 -or -not $target) { throw '用法：.\deploy.ps1 proxy connect <容器名>' }
            Ensure-ProxyNetwork
            if (-not (Test-ContainerExists 'mihomo')) { throw '找不到 mihomo 容器，请先安装 Mihomo Docker 模式。' }
            if ((Get-DockerOutput @('inspect','--format','{{.State.Status}}','mihomo')) -ne 'running') { throw 'Mihomo 容器未运行。' }
            $targetId = Get-DockerOutput @('inspect','--format','{{.Id}}',$target)
            if (-not $targetId) { throw "找不到目标容器：$target" }
            $mihomoId = Get-DockerOutput @('inspect','--format','{{.Id}}','mihomo')
            if ($targetId -eq $mihomoId) { throw '禁止修改 Mihomo 自身的网络连接。' }
            $mode = Get-DockerOutput @('inspect','--format','{{.HostConfig.NetworkMode}}',$target)
            if ($mode -eq 'host' -or $mode -eq 'none' -or $mode.StartsWith('container:')) { throw "$target 的 $mode 网络模式不支持动态接入。" }
            $members = Get-DockerOutput @('network','inspect','--format','{{range $key, $_ := .Containers}}{{println $key}}{{end}}','proxy-net')
            if ($members -notmatch [regex]::Escape($targetId)) { Invoke-Docker @('network','connect','proxy-net',$target) }
            Write-Host "$target 已接入 proxy-net；应用需自行配置有认证的 mihomo:7890。"
        }
        disconnect {
            if ($Arguments.Count -ne 2 -or -not $target) { throw '用法：.\deploy.ps1 proxy disconnect <容器名>' }
            Ensure-ProxyNetwork
            $targetId = Get-DockerOutput @('inspect','--format','{{.Id}}',$target)
            if (-not $targetId) { throw "找不到目标容器：$target" }
            $mihomoId = Get-DockerOutput @('inspect','--format','{{.Id}}','mihomo')
            if ($targetId -eq $mihomoId) { throw '禁止修改 Mihomo 自身的网络连接。' }
            $members = Get-DockerOutput @('network','inspect','--format','{{range $key, $_ := .Containers}}{{println $key}}{{end}}','proxy-net')
            if ($members -match [regex]::Escape($targetId)) { Invoke-Docker @('network','disconnect','proxy-net',$target) }
            Write-Host "$target 已断开或此前未连接 proxy-net。"
        }
        status {
            if ($Arguments.Count -gt 2) { throw '用法：.\deploy.ps1 proxy status [容器名]' }
            Ensure-ProxyNetwork
            if ($target) {
                $targetId = Get-DockerOutput @('inspect','--format','{{.Id}}',$target)
                if (-not $targetId) { throw "找不到目标容器：$target" }
                $members = Get-DockerOutput @('network','inspect','--format','{{range $key, $_ := .Containers}}{{println $key}}{{end}}','proxy-net')
                if ($members -match [regex]::Escape($targetId)) { Write-Host "$target：已接入 proxy-net" }
                else { Write-Host "$target：未接入 proxy-net" }
            } else {
                Write-Host (Get-DockerOutput @('network','inspect','--format','{{range .Containers}}{{println .Name}}{{end}}','proxy-net'))
            }
        }
        default { throw '用法：.\deploy.ps1 proxy {ensure|connect|disconnect|status} [容器名]' }
    }
}

function Invoke-Task {
    param([string]$Task, [string]$Action = 'install')
    if ($Action -in @('up','')) { $Action = 'install' }
    if ($Action -eq 'pull') { $Action = 'update' }
    if ($Action -in @('host','host-update')) {
        if ($Task -ne 'mihomo') { throw 'host/host-update 仅支持 mihomo。' }
        throw 'Mihomo host 是 Linux systemd 原生安装，不使用 Docker；此 Windows PowerShell 入口不会执行它。'
    }
    if ($Action -notin @('install','update','sync')) {
        throw "不支持的操作：$Action。支持 install / update / sync；mihomo host 模式不属于 Windows Docker 部署。"
    }
    Sync-Task $Task
    if ($Action -eq 'sync') { Initialize-AppConfiguration $Task; return }

    $composeFile = Join-Path (Join-Path (Join-Path $script:SoftwareRoot $Task) 'deploy') 'docker-compose.yaml'
    if (-not (Test-Path -LiteralPath $composeFile)) {
        throw "$Task 不是 Docker Compose 服务。Windows PowerShell 入口不会调用任何 Bash 脚本；Linux/systemd 或 OpenWrt 业务请继续在对应 Linux 环境部署。"
    }
    $configResult = Ensure-GlobalConfig
    Initialize-AppConfiguration $Task
    Load-Configuration
    Load-RepositoryVersions
    if ($configResult.Created) {
        Write-Host '统一配置已创建。请先编辑普通配置和敏感配置，再重新执行安装。'
        Write-Host "普通配置：$(if ($script:AppEnv) { $script:AppEnv } else { $script:GlobalEnv })"
        Write-Host "敏感配置：$(if ($script:AppSecrets) { $script:AppSecrets } else { $script:GlobalSecrets })"
        return
    }
    Check-DockerRuntime
    if ($Action -eq 'update' -and $Task -ne 'easytier-automation-executor') {
        $firstContainer = Get-TaskContainers $Task | Select-Object -First 1
        if ($firstContainer -and -not (Test-ContainerExists $firstContainer)) { throw "未找到 $Task 的现有容器；请先执行 .\deploy.ps1 $Task install。" }
    }
    Prepare-Task $Task $Action
    Load-Configuration
    Load-RepositoryVersions
    Set-MirrorImages $Task
    Test-TaskOwnership

    $socket = $Task -eq 'flatnas' -and (Get-ConfigValue 'FLATNAS_DOCKER_SOCKET' 'false') -eq 'true'
    Invoke-Compose $Task @('config','--quiet') -SocketOverride:$socket

    switch ($Task) {
        opencode {
            Write-Host '构建 OpenCode 镜像...'
            Invoke-Compose $Task @('build','--pull','--progress','plain','opencode')
            if ($Action -eq 'update' -and (Test-ContainerExists 'opencode')) {
                try { Invoke-Compose $Task @('stop','opencode') } catch { Write-Warning '停止 OpenCode 容器时返回错误，将继续尝试更新。' }
            }
            Invoke-Compose $Task @('up','-d','--wait','--wait-timeout','120','opencode')
        }
        frps {
            Invoke-Compose $Task @('pull','frps')
            if ($Action -eq 'update') {
                try { Invoke-Compose $Task @('stop','frps') } catch { }
            }
            Invoke-Compose $Task @('up','-d','--wait','--wait-timeout','120','frps')
        }
        portainer {
            Invoke-Compose $Task @('pull','portainer')
            $upArgs = if ($Action -eq 'update') { @('up','-d','--wait','--wait-timeout','90','--no-deps','portainer') } else { @('up','-d','--wait','--wait-timeout','90','portainer') }
            Invoke-Compose $Task $upArgs
            $legacy = Join-Path (Join-Path $script:SoftwareRoot 'portainer\deploy') '.secrets\admin_password'
            if (Test-Path -LiteralPath $legacy) {
                Remove-Item -LiteralPath $legacy -Force
                $parent = Split-Path -Parent $legacy
                if ((Test-Path -LiteralPath $parent) -and @(Get-ChildItem -LiteralPath $parent -Force).Count -eq 0) { Remove-Item -LiteralPath $parent -Force }
            }
        }
        flatnas {
            Invoke-Compose $Task @('pull','flatnas') -SocketOverride:$socket
            Invoke-Compose $Task @('up','-d','--wait','--wait-timeout','90','flatnas') -SocketOverride:$socket
        }
        easytier {
            Invoke-Compose $Task @('pull','easytier')
            Invoke-Compose $Task @('up','-d','--wait','--wait-timeout','90','easytier')
        }
        'easytier-automation-executor' {
            Invoke-Compose $Task @('pull','easytier-automation-executor')
            $image = Get-ConfigValue 'DEPLOY_EASYTIER_EXECUTOR_IMAGE' (Get-ConfigValue 'EASYTIER_EXECUTOR_IMAGE' 'ghcr.io/cibederorg/easytier-automation-executor:feat-automation-center')
            $arch = Get-DockerOutput @('image','inspect','--format','{{.Architecture}}',$image)
            if ($arch -and $arch -ne 'amd64') { throw "执行器镜像架构为 $arch，预期 amd64；未替换容器。" }
            Invoke-Compose $Task @('up','-d','--no-deps','--force-recreate','--pull','never','easytier-automation-executor')
            $healthCode = 'import json, os, urllib.request; from automation_executor.auth import authorization; ip = os.environ.get("EASYTIER_EXECUTOR_BIND_IP", "127.0.0.1"); ip = "127.0.0.1" if ip == "0.0.0.0" else ip; port = os.environ.get("EASYTIER_EXECUTOR_PORT", "8766"); request = urllib.request.Request("http://%s:%s/internal/v1/health" % (ip, port), headers={"Authorization": authorization(os.environ["AUTOMATION_TOKEN"])}); response = urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=2); data = json.load(response); assert data["protocol_version"] == 1 and data["executor_id"] and data["state"] == "ready"'
            $ready = $false
            $bindIp = Get-ConfigValue 'EASYTIER_EXECUTOR_BIND_IP' '127.0.0.1'
            $port = Get-ConfigValue 'EASYTIER_EXECUTOR_PORT' '8766'
            for ($attempt = 0; $attempt -lt 25; $attempt++) {
                $health = Get-DockerOutput @('exec','-e',"EASYTIER_EXECUTOR_BIND_IP=$bindIp",'-e',"EASYTIER_EXECUTOR_PORT=$port",'easytier-automation-executor','python','-c',$healthCode)
                if ($null -ne $health) { $ready = $true; break }
                Start-Sleep -Seconds 1
            }
            if (-not $ready) {
                try { Invoke-Compose $Task @('logs','--tail=80','easytier-automation-executor') } catch { }
                throw '执行器未通过内部认证健康检查；请检查 docker logs easytier-automation-executor。Token 和 ADB 数据不会被删除。'
            }
        }
        sub2api {
            Invoke-Compose $Task @('pull')
            Invoke-Compose $Task @('up','-d','--wait','--wait-timeout','240')
        }
        'qoder2api-hub' {
            Invoke-Compose $Task @('pull','qoder2api-hub')
            Invoke-Compose $Task @('up','-d','--no-deps','--force-recreate','--pull','never','--wait','--wait-timeout','120','qoder2api-hub')
        }
        mihomo {
            Invoke-Compose $Task @('pull','mihomo')
            Invoke-Compose $Task @('up','-d','--force-recreate','--wait','--wait-timeout','180','mihomo')
            $healthy = $false
            for ($attempt = 0; $attempt -lt 30; $attempt++) {
                $result = Get-DockerOutput @('exec','mihomo','node','-e','fetch("http://127.0.0.1:9090/version",{headers:{Authorization:"Bearer "+process.env.CLASH_SECRET}}).then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))')
                if ($null -ne $result) { $healthy = $true; break }
                Start-Sleep -Seconds 1
            }
            if (-not $healthy) { throw 'Mihomo Web/Agent 已提交启动，但内核 API 未通过检查；请查看 docker logs mihomo。' }
        }
        default { throw "尚未实现 $Task 的 Windows 原生 Docker 部署处理。" }
    }
    Write-Host ''
    Write-Host "[$Task] $Action 完成。"
    try { Invoke-Compose $Task @('ps') -SocketOverride:$socket } catch { Write-Warning $_.Exception.Message }
}

function Show-Usage {
    $usageText = @'
用法：
  .\deploy.ps1                       交互选择业务
  .\deploy.ps1 list                  列出业务
  .\deploy.ps1 env                   初始化/检查 Windows 全局配置
  .\deploy.ps1 <业务>                 安装 Docker Compose 服务
  .\deploy.ps1 <业务> install         安装
  .\deploy.ps1 <业务> update          更新
  .\deploy.ps1 <业务> sync            仅同步文件，不启动容器
  .\deploy.ps1 proxy ensure           创建/验证 Mihomo 内部代理网络
  .\deploy.ps1 proxy connect <容器>   接入代理网络
  .\deploy.ps1 proxy disconnect <容器> 断开代理网络
  .\deploy.ps1 proxy status [容器]    查看代理网络状态

说明：
  这是 Windows 原生 PowerShell 入口，不调用 Bash 或 WSL。
  Docker 服务直接调用 Windows 上的 Docker CLI / Docker Compose。
  Windows 默认软件根目录为 %LOCALAPPDATA%\CiBeDerORG\deploy\software。
  可通过环境变量 SOFTWARE_ROOT 指定其他目录。
  Linux systemd、OpenWrt 和 Mihomo host 原生模式不由此脚本执行。
  EasyTier/执行器使用 Linux host 网络或 TUN 的配置在 Docker Desktop 上可能受限。
'@
    Write-Host $usageText
}

function Invoke-Main {
    param([string[]]$Arguments)
    if (-not $Arguments -or $Arguments.Count -eq 0) {
        List-Tasks
        $choice = Read-Host '请选择业务编号或名称（0 退出）'
        if ($choice -in @('0','q','quit')) { return }
        $task = Resolve-Task $choice
        $action = Read-Host '操作 install/update/sync（默认 install）'
        if ([string]::IsNullOrWhiteSpace($action)) { $action = 'install' }
        Invoke-Task $task $action
        return
    }
    switch ($Arguments[0]) {
        { $_ -in @('-h','--help','help') } { Show-Usage; return }
        list { List-Tasks; return }
        env {
            $result = Ensure-GlobalConfig
            if ($result.Created) { Write-Host "统一配置已创建：$($script:GlobalEnv) / $($script:GlobalSecrets)" }
            elseif ($result.Updated) { Write-Host "统一配置已更新：$($script:GlobalEnv) / $($script:GlobalSecrets)" }
            else { Write-Host "统一配置已是最新：$($script:GlobalEnv) / $($script:GlobalSecrets)" }
            return
        }
        proxy {
            if ($Arguments.Count -lt 2) { throw '用法：.\deploy.ps1 proxy {ensure|connect|disconnect|status} [容器名]' }
            Invoke-ProxyCommand -Arguments @($Arguments | Select-Object -Skip 1)
            return
        }
        default {
            if ($Arguments.Count -gt 2) { Show-Usage; throw '参数过多。' }
            $task = Resolve-Task $Arguments[0]
            $action = if ($Arguments.Count -gt 1) { $Arguments[1] } else { 'install' }
            Invoke-Task $task $action
        }
    }
}

try {
    Initialize-Paths
    if ($CliArgs -and $CliArgs.Count -gt 0) { Invoke-Main -Arguments $CliArgs }
    else { Invoke-Main -Arguments @() }
} catch {
    Write-Host ''
    Write-Host ("[ERROR] " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
) { throw "仓库版本值非法：$key" }
        [Environment]::SetEnvironmentVariable($key, $value, 'Process')
        if ($key.EndsWith('_IMAGE')) {
            [Environment]::SetEnvironmentVariable('DEPLOY_' + $key, $value, 'Process')
        }
    }
}

function Set-MirrorImages {
    param([string]$Task)
    $sourceMode = Get-ConfigValue 'DOCKER_IMAGE_SOURCE' 'original'
    if ($sourceMode -notin @('original','mirror')) { throw 'DOCKER_IMAGE_SOURCE 只能是 original 或 mirror。' }
    if ($sourceMode -eq 'original') { return }

    $key = ''
    $image = ''
    switch ($Task) {
        frps {
            $key = 'DEPLOY_FRPS_IMAGE'
            $image = 'ghcr.io/cibeder/frps:dev-multi-latest'
        }
        easytier {
            $key = 'DEPLOY_EASYTIER_IMAGE'
            $image = Get-ConfigValue 'EASYTIER_IMAGE' 'ghcr.io/cibederorg/easytier:feat-node-attributes-main'
        }
        'easytier-automation-executor' {
            $key = 'DEPLOY_EASYTIER_EXECUTOR_IMAGE'
            $image = Get-ConfigValue 'EASYTIER_EXECUTOR_IMAGE' 'ghcr.io/cibederorg/easytier-automation-executor:feat-automation-center'
        }
        'qoder2api-hub' {
            $key = 'DEPLOY_QODER2API_HUB_IMAGE'
            $image = Get-ConfigValue 'QODER2API_HUB_IMAGE' 'ghcr.io/shuishuipingan/qoder2api-hub:latest'
        }
        mihomo {
            $key = 'DEPLOY_MIHOMO_IMAGE'
            $image = 'ghcr.io/metacubex/metacubexd-server:latest'
        }
        default { return }
    }
    if (-not $image.StartsWith('ghcr.io/', [StringComparison]::OrdinalIgnoreCase)) { return }

    $providers = @( (Get-ConfigValue 'DOCKER_IMAGE_MIRRORS' 'dockerproxy,ghproxy').Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } )
    $allowed = @('dockerproxy','ghproxy','nju','1ms','daocloud')
    foreach ($providerName in $providers) {
        if ($providerName -notin $allowed) { throw "DOCKER_IMAGE_MIRRORS 中不支持的站点：$providerName" }
    }
    $providers = @($providers | Select-Object -Unique)
    if ($providers.Count -eq 0) { throw 'DOCKER_IMAGE_MIRRORS 没有有效候选站。' }

    $stateDir = Join-Path $script:GlobalEnvDir 'state'
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $stateFile = Join-Path $stateDir 'image-mirror.last'
    $lockFile = "$stateFile.lock"
    $lock = $null
    $deadline = (Get-Date).AddSeconds(10)
    while (-not $lock) {
        try { $lock = [IO.File]::Open($lockFile,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
        catch {
            if ((Get-Date) -gt $deadline) { throw '镜像源轮换状态正被其他部署占用，请稍后重试。' }
            Start-Sleep -Milliseconds 200
        }
    }
    try {
        $previous = ''
        if (Test-Path -LiteralPath $stateFile) { $previous = [IO.File]::ReadAllText($stateFile).Trim() }
        $previousIndex = [Array]::IndexOf([string[]]$providers, $previous)
        $index = if ($previousIndex -lt 0) { 0 } else { ($previousIndex + 1) % $providers.Count }
        $provider = $providers[$index]
        Write-TextFile $stateFile $provider
    } finally { $lock.Dispose() }

    $path = $image.Substring('ghcr.io/'.Length)
    switch ($provider) {
        dockerproxy { $rewritten = "ghcr.dockerproxy.net/$path" }
        ghproxy { $rewritten = "gh-proxy.com/docker/ghcr.io/$path" }
        nju { $rewritten = "ghcr.nju.edu.cn/$path" }
        '1ms' { $rewritten = "ghcr.1ms.run/$path" }
        daocloud { $rewritten = "m.daocloud.io/ghcr.io/$path" }
    }
    [Environment]::SetEnvironmentVariable($key, $rewritten, 'Process')
    Write-Host "本次 GHCR 镜像源：$provider"
}
function Ensure-TaskDirectories {
    param([string]$Task)
    $base = Join-Path $script:SoftwareRoot $Task
    $dirs = switch ($Task) {
        opencode { @('config','data','state','workspace') }
        frps { @('config','data') }
        easytier { @('data\core','data\cloud-managed-core','data\web') }
        'easytier-automation-executor' { @('data','data\runtime','data\adb') }
        portainer { @('data') }
        flatnas { @('data','music','PC','APP','doc') }
        sub2api { @('data\app','data\postgres','data\redis') }
        'qoder2api-hub' { @('data\accounts','data\usage') }
        mihomo { @('data') }
        default { @('data') }
    }
    foreach ($relative in $dirs) { New-Item -ItemType Directory -Path (Join-Path $base $relative) -Force | Out-Null }
}

function Test-IPv4 {
    param([string]$Name, [string]$Value)
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Value, [ref]$parsed) -or $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw "$Name 必须是有效 IPv4 地址。"
    }
}

function Test-Port {
    param([string]$Name, [string]$Value)
    $number = 0
    if (-not [int]::TryParse($Value, [ref]$number) -or $number -lt 1 -or $number -gt 65535) {
        throw "$Name 必须是 1-65535 的数字端口。"
    }
    return $number
}

function Replace-ManagedBlock {
    param([string]$Path, [string]$BeginMarker, [string]$EndMarker, [string[]]$ReplacementLines)
    $lines = [IO.File]::ReadAllLines($Path)
    $begin = -1
    $end = -1
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -ceq $BeginMarker) { $begin = $i }
        if ($lines[$i] -ceq $EndMarker) { $end = $i }
    }
    if ($begin -lt 0 -or $end -le $begin) { throw "缺少动态区块标记：$BeginMarker / $EndMarker（$Path）" }
    $output = [Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($i -eq $begin) {
            $output.Add($lines[$i])
            foreach ($replacement in $ReplacementLines) { $output.Add([string]$replacement) }
            $i = $end - 1
            continue
        }
        $output.Add($lines[$i])
    }
    Write-TextFile $Path ($output -join [Environment]::NewLine)
}

function Prepare-Frps {
    param([string]$Task, [string]$Mode)
    $base = Join-Path $script:SoftwareRoot $Task
    $configFile = Join-Path $base 'config\frps.toml'
    $composeFile = Join-Path $base 'deploy\docker-compose.yaml'
    if (-not (Test-Path -LiteralPath $configFile)) { throw "FRPS 配置文件不存在：$configFile" }
    $bind = Test-Port 'FRPS_BIND_PORT' (Get-ConfigValue 'FRPS_BIND_PORT' '7000')
    $dashboard = Test-Port 'FRPS_DASHBOARD_PORT' (Get-ConfigValue 'FRPS_DASHBOARD_PORT' '7001')
    if ($bind -eq $dashboard -or @($bind,$dashboard) -contains 80 -or @($bind,$dashboard) -contains 443 -or @($bind,$dashboard) -contains 9080 -or @($bind,$dashboard) -contains 9443) {
        throw 'FRPS bind/dashboard 端口冲突：不能重复，也不能占用 80/443/9080/9443。'
    }
    $raw = Get-ConfigValue 'FRPS_PROXY_PORTS' '["3389","7100-7800"]'
    try { $items = @($raw | ConvertFrom-Json -ErrorAction Stop) } catch { throw 'FRPS_PROXY_PORTS 必须是 JSON 数组，例如 ["3389","7100-7800"]。' }
    if ($items.Count -eq 0) { throw 'FRPS_PROXY_PORTS 不能为空数组。' }
    $seenItems = @{}
    $seenPorts = @{}
    $tomlLines = [Collections.Generic.List[string]]::new()
    $composeLines = [Collections.Generic.List[string]]::new()
    foreach ($itemValue in $items) {
        $item = [string]$itemValue
        if ($seenItems.ContainsKey($item)) { throw "FRPS_PROXY_PORTS 存在重复项：$item" }
        $seenItems[$item] = $true
        if ($item -match '^(\d+)$') {
            $start = Test-Port 'FRPS_PROXY_PORTS 单端口' $Matches[1]
            $end = $start
            $tomlLines.Add("    { single = $start },")
            $composeLines.Add(('      - "' + $start + ':' + $start + '"'))
        } elseif ($item -match '^(\d+)-(\d+)$') {
            $start = Test-Port 'FRPS_PROXY_PORTS 范围起始端口' $Matches[1]
            $end = Test-Port 'FRPS_PROXY_PORTS 范围结束端口' $Matches[2]
            if ($start -gt $end) { throw "FRPS_PROXY_PORTS 范围起始端口大于结束端口：$item" }
            $tomlLines.Add("    { start = $start, end = $end },")
            $composeLines.Add(('      - "' + $start + '-' + $end + ':' + $start + '-' + $end + '"'))
        } else { throw "FRPS_PROXY_PORTS 非法项：$item，只支持单端口或范围。" }
        for ($port = $start; $port -le $end; $port++) {
            if (@($bind,$dashboard,80,443,9080,9443) -contains $port) { throw "FRPS_PROXY_PORTS 包含保留端口 $port。" }
            if ($seenPorts.ContainsKey([string]$port)) { throw "FRPS_PROXY_PORTS 存在重复或重叠端口：$port" }
            $seenPorts[[string]$port] = $true
        }
    }
    $tomlBlock = @('allowPorts = [') + @($tomlLines) + @(']')
    Replace-ManagedBlock $configFile '# BEGIN FRPS_PROXY_PORTS' '# END FRPS_PROXY_PORTS' $tomlBlock
    $toml = [IO.File]::ReadAllText($configFile)
    $toml = [regex]::Replace($toml, '(?m)^bindPort\s*=\s*\d+\s*$', "bindPort = $bind")
    $toml = [regex]::Replace($toml, '(?m)^webServer\.port\s*=\s*\d+\s*$', "webServer.port = $dashboard")
    Write-TextFile $configFile $toml

    Replace-ManagedBlock $composeFile '      # BEGIN FRPS_PROXY_PORTS' '      # END FRPS_PROXY_PORTS' @($composeLines)
    $compose = [IO.File]::ReadAllText($composeFile)
    $compose = [regex]::Replace($compose, '(?m)^(\s*-\s*")[0-9]+:[0-9]+(" # FRPS_BIND_PORT)\s*$', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + $bind.ToString() + ':' + $bind.ToString() + $m.Groups[2].Value })
    $compose = [regex]::Replace($compose, '(?m)^(\s*-\s*")[0-9]+:[0-9]+(" # FRPS_DASHBOARD_PORT)\s*$', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Groups[1].Value + $dashboard.ToString() + ':' + $dashboard.ToString() + $m.Groups[2].Value })
    $compose = [regex]::Replace($compose, 'http://127\.0\.0\.1:\d+/healthz', "http://127.0.0.1:$dashboard/healthz")
    Write-TextFile $composeFile $compose

    if ($Mode -eq 'update') {
        $clients = Join-Path $base 'data\clients.json'
        if (Test-Path -LiteralPath $clients) {
            $backupDir = Join-Path $base 'data\backup'
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            $backup = Join-Path $backupDir ("clients-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
            Copy-Item -LiteralPath $clients -Destination $backup
            Write-Host "已备份 FRPS clients.json：$backup"
        }
    }
}

function Prepare-Mihomo {
    param([string]$Task)
    foreach ($key in @('MIHOMO_API_SECRET','MIHOMO_CONTROL_TOKEN')) { Ensure-HexSecret $key }
    $mixed = Test-Port 'MIHOMO_MIXED_PORT' (Get-ConfigValue 'MIHOMO_MIXED_PORT' '7011')
    $web = Test-Port 'MIHOMO_API_PORT' (Get-ConfigValue 'MIHOMO_API_PORT' '7012')
    $core = Test-Port 'MIHOMO_CORE_API_PORT' (Get-ConfigValue 'MIHOMO_CORE_API_PORT' '7013')
    if ($mixed -eq $web -or $mixed -eq $core -or $web -eq $core) { throw 'Mihomo 代理、Web/Agent、内核 API 端口不能冲突。' }
    foreach ($entry in @(
        @('MIHOMO_PROXY_BIND_IP',(Get-ConfigValue 'MIHOMO_PROXY_BIND_IP' '127.0.0.1')),
        @('MIHOMO_API_BIND_IP',(Get-ConfigValue 'MIHOMO_API_BIND_IP' '0.0.0.0')),
        @('MIHOMO_CORE_API_BIND_IP',(Get-ConfigValue 'MIHOMO_CORE_API_BIND_IP' '0.0.0.0'))
    )) { Test-IPv4 $entry[0] $entry[1] }

    $base = Join-Path $script:SoftwareRoot $Task
    $network = Get-DockerOutput @('network','inspect','proxy-net')
    if ($null -eq $network) {
        Invoke-Docker @('network','create','--driver','bridge','--internal','--label','org.cibeder.deploy.role=mihomo-proxy','proxy-net') | Out-Null
        Write-Host '已创建 Mihomo 内部代理网络 proxy-net。'
    } else {
        $driver = Get-DockerOutput @('network','inspect','--format','{{.Driver}}','proxy-net')
        $internal = Get-DockerOutput @('network','inspect','--format','{{.Internal}}','proxy-net')
        $scope = Get-DockerOutput @('network','inspect','--format','{{.Scope}}','proxy-net')
        if ($driver -ne 'bridge' -or $internal -ne 'true' -or $scope -ne 'local') { throw '已有同名 proxy-net 不是 local internal bridge，拒绝接管。' }
    }

    $data = Join-Path $base 'data'
    $final = Join-Path $data 'all-in-one'
    $old = Join-Path $data 'config.yaml'
    if ((Test-Path -LiteralPath $final) -and (Test-Path -LiteralPath (Join-Path $final 'profiles\index.json')) -and (Test-Path -LiteralPath (Join-Path $final 'active.yaml'))) {
        Write-Host '检测到已有 Mihomo All-in-One 配置，保留所有配置和凭据。'
        return
    }
    if (Test-Path -LiteralPath $final) {
        $entries = @(Get-ChildItem -LiteralPath $final -Force -ErrorAction SilentlyContinue)
        if ($entries.Count -gt 0) { throw "Mihomo 数据目录不完整：$final。拒绝覆盖。" }
        Remove-Item -LiteralPath $final -Force
    }
    $template = Join-Path $base 'deploy\default-profile.yaml'
    if (-not (Test-Path -LiteralPath $template)) { throw "Mihomo 初始 Profile 模板不存在：$template" }
    $staging = Join-Path $data ('.aio-stage-' + [Guid]::NewGuid().ToString('N'))
    $profiles = Join-Path $staging 'profiles'
    New-Item -ItemType Directory -Path $profiles -Force | Out-Null
    $initial = Join-Path $profiles 'deploy-initial.yaml'
    if (Test-Path -LiteralPath $old) {
        Copy-Item -LiteralPath $old -Destination $initial
        $profileText = [IO.File]::ReadAllText($initial)
        $profileText = [regex]::Replace($profileText, '(?m)^external-ui(?:-url)?\s*:.*(?:\r?\n)?', '')
        Write-TextFile $initial $profileText
        $authMatch = [regex]::Match($profileText, '(?ms)^authentication\s*:\s*\r?\n(?:(?:[ \t].*|[ \t]*\r?\n))*')
        if ($authMatch.Success) { Write-TextFile (Join-Path $profiles 'deploy-proxy-auth.yaml') $authMatch.Value }
        $backupDir = Join-Path $data 'backup\pre-all-in-one'
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        $backup = Join-Path $backupDir 'config.yaml'
        if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $old -Destination $backup }
        Write-Host '旧 config.yaml 已保留，并作为初始 Profile。'
    } else {
        Ensure-HexSecret 'MIHOMO_PROXY_PASSWORD'
        Copy-Item -LiteralPath $template -Destination $initial
        $user = Get-ConfigValue 'MIHOMO_PROXY_USER' 'deploy'
        $password = Get-ConfigValue 'MIHOMO_PROXY_PASSWORD'
        $yamlAuth = ($user + ':' + $password).Replace("'", "''")
        $append = [Environment]::NewLine + 'authentication:' + [Environment]::NewLine + "  - '" + $yamlAuth + "'" + [Environment]::NewLine
        Write-TextFile $initial ([IO.File]::ReadAllText($initial) + $append)
    }
    $origins = @("http://localhost:$web", "http://127.0.0.1:$web")
    try {
        $ips = Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction Stop |
            Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } |
            Select-Object -ExpandProperty IPAddress -Unique
        foreach ($ip in $ips) { $origins += "http://$($ip):$($web)" }
    } catch { }
    $myIp = Get-ConfigValue 'MYAI_IP'
    if ($myIp) {
        Test-IPv4 'MYAI_IP' $myIp
        $origins += "http://$($myIp):$($web)"
    }
    $origins = @($origins | Select-Object -Unique)
    $cors = @('external-controller-cors:','  allow-private-network: true','  allow-origins:') + @($origins | ForEach-Object { "    - '" + $_.Replace("'","''") + "'" })
    Write-TextFile (Join-Path $profiles 'deploy-web-cors.yaml') ($cors -join [Environment]::NewLine)
    $activeText = [IO.File]::ReadAllText($initial)
    if ($activeText -notmatch '(?m)^external-controller-cors\s*:') {
        $activeText = $activeText.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + ($cors -join [Environment]::NewLine) + [Environment]::NewLine
    }
    Write-TextFile (Join-Path $staging 'active.yaml') $activeText
    $hasAuth = Test-Path -LiteralPath (Join-Path $profiles 'deploy-proxy-auth.yaml')
    $index = @(
        [ordered]@{ id='deploy-initial'; name='Deploy initial profile'; type='local'; updatedAt=0 },
        [ordered]@{ id='deploy-web-cors'; name='Deploy trusted Web origins'; type='merge'; enabled=$true; updatedAt=0 }
    )
    if ($hasAuth) { $index += [ordered]@{ id='deploy-proxy-auth'; name='Deploy proxy authentication'; type='merge'; enabled=$true; updatedAt=0 } }
    Write-TextFile (Join-Path $profiles 'index.json') (ConvertTo-Json -InputObject @($index) -Depth 8)
    Write-TextFile (Join-Path $profiles 'state.json') '{"activeId":"deploy-initial"}'
    Move-Item -LiteralPath $staging -Destination $final
    Write-Host "已初始化 Mihomo All-in-One 数据：$final"
}

function Prepare-Task {
    param([string]$Task, [string]$Mode)
    Ensure-TaskDirectories $Task
    switch ($Task) {
        opencode {
            if (-not (Test-Path -LiteralPath (Join-Path $script:SoftwareRoot 'opencode\config\opencode.jsonc'))) { throw 'OpenCode 配置文件 opencode/config/opencode.jsonc 不存在。' }
            if ([string]::IsNullOrWhiteSpace((Get-ConfigValue 'OPENCODE_SERVER_PASSWORD'))) { throw "请先在 $($script:GlobalSecrets) 设置 OPENCODE_SERVER_PASSWORD。" }
            if ([string]::IsNullOrWhiteSpace((Get-ConfigValue 'MYAI_IP'))) { throw "请先在 $($script:GlobalEnv) 设置 MYAI_IP。" }
            foreach ($key in @('BUILD_HTTP_PROXY','BUILD_HTTPS_PROXY')) {
                $proxy = Get-ConfigValue $key
                if ($proxy -match '^https?://(127\.0\.0\.1|localhost):') { throw "$key 不能使用 localhost/127.0.0.1；Docker build 应使用 host.docker.internal。" }
            }
            if ($Mode -eq 'update') {
                $data = Join-Path $script:SoftwareRoot 'opencode\data'
                $backupDir = Join-Path $data ('backup\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
                New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
                $backedUp = $false
                foreach ($file in Get-ChildItem -LiteralPath $data -File -Force -ErrorAction SilentlyContinue) {
                    if ($file.Name -match '\.db(-.*)?$' -or $file.Name -eq 'auth.json') {
                        Copy-Item -LiteralPath $file.FullName -Destination $backupDir
                        $backedUp = $true
                    }
                }
                if (-not $backedUp) { Remove-Item -LiteralPath $backupDir -Force -ErrorAction SilentlyContinue; Write-Host '暂无 OpenCode 数据库/认证文件，跳过备份。' }
                else { Write-Host "已备份 OpenCode 数据：$backupDir" }
            }
            [Environment]::SetEnvironmentVariable('OPENCODE_CACHE_BUST',[DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString(),'Process')
        }
        frps { Prepare-Frps $Task $Mode }
        portainer {
            $null = Test-Port 'PORTAINER_HTTP_PORT' (Get-ConfigValue 'PORTAINER_HTTP_PORT' '7004')
            $password = Get-ConfigValue 'PORTAINER_ADMIN_PASSWORD'
            if ([string]::IsNullOrEmpty($password) -or $password.Length -lt 12) { throw 'PORTAINER_ADMIN_PASSWORD 必须设置且至少 12 个字符，请在 .secrets 中配置。' }
            if ($Mode -eq 'update' -and -not (Test-Path -LiteralPath (Join-Path $script:SoftwareRoot 'portainer\data'))) { throw 'Portainer 数据目录不存在，请先安装。' }
        }
        flatnas {
            $null = Test-Port 'FLATNAS_HTTP_PORT' (Get-ConfigValue 'FLATNAS_HTTP_PORT' '7009')
            Test-IPv4 'FLATNAS_BIND_IP' (Get-ConfigValue 'FLATNAS_BIND_IP' '0.0.0.0')
            if ($Mode -eq 'update' -and -not (Test-ContainerExists 'flatnas')) { throw '未找到已部署的 FlatNas 容器，请先安装。' }
            if ((Get-ConfigValue 'FLATNAS_DOCKER_SOCKET' 'false') -eq 'true') { Write-Warning '已启用 Docker Socket：FlatNas 将获得宿主 Docker 管理权限。' }
        }
        easytier {
            $role = Get-ConfigValue 'EASYTIER_ROLE' 'cloud'
            if ($role -notin @('cloud','intranet')) { throw 'EASYTIER_ROLE 只能是 cloud 或 intranet。' }
            $mainPort = Test-Port 'EASYTIER_PORT' (Get-ConfigValue 'EASYTIER_PORT' '7005')
            $rpcPort = Test-Port 'EASYTIER_RPC_PORT' (Get-ConfigValue 'EASYTIER_RPC_PORT' '7006')
            if ($mainPort -eq $rpcPort) { throw 'EASYTIER_PORT 与 EASYTIER_RPC_PORT 不能重复。' }
            if ($role -eq 'cloud') {
                $webPort = Test-Port 'EASYTIER_WEB_PORT' (Get-ConfigValue 'EASYTIER_WEB_PORT' '7007')
                $configPort = Test-Port 'EASYTIER_CONFIG_PORT' (Get-ConfigValue 'EASYTIER_CONFIG_PORT' '7008')
                if ($mainPort -eq $webPort -or $mainPort -eq $configPort -or $rpcPort -eq $webPort -or $rpcPort -eq $configPort -or $webPort -eq $configPort) { throw 'EasyTier 主端口、RPC、Web、Config 四个端口不能重复。' }
                $registration = Get-ConfigValue 'EASYTIER_WEB_ENABLE_REGISTRATION' 'true'
                if ($registration -notin @('true','false')) { throw 'EASYTIER_WEB_ENABLE_REGISTRATION 只能是 true 或 false。' }
                $hostUrl = Get-ConfigValue 'EASYTIER_WEB_API_HOST'
                if (-not $hostUrl -or $hostUrl -notmatch '^https?://') { throw 'cloud 模式必须在 .env 设置以 http:// 或 https:// 开头的 EASYTIER_WEB_API_HOST。' }
            } else {
                $server = Get-ConfigValue 'EASYTIER_CONFIG_SERVER'
                if (-not $server -or $server -notmatch '^(udp|tcp)://') { throw 'intranet 模式必须设置以 udp:// 或 tcp:// 开头的 EASYTIER_CONFIG_SERVER。' }
            }
            Write-Warning 'EasyTier Compose 使用 host 网络、/dev/net/tun 和 Linux 主机 machine-id；Windows Docker Desktop 的网络/TUN 行为与 Linux 主机不同，请确认 Docker Desktop 支持后再继续。'
        }
        'easytier-automation-executor' {
            $image = Get-ConfigValue 'EASYTIER_EXECUTOR_IMAGE' 'ghcr.io/cibederorg/easytier-automation-executor:feat-automation-center'
            if (-not $image) { throw 'EASYTIER_EXECUTOR_IMAGE 不能为空。' }
            $null = Test-Port 'EASYTIER_EXECUTOR_PORT' (Get-ConfigValue 'EASYTIER_EXECUTOR_PORT' '8766')
            Test-IPv4 'EASYTIER_EXECUTOR_BIND_IP' (Get-ConfigValue 'EASYTIER_EXECUTOR_BIND_IP' '127.0.0.1')
            $callback = Get-ConfigValue 'EASYTIER_EXECUTOR_CALLBACK_URL'
            if ($callback -notmatch '^https?://[^/@?#\s]+(/[^?#\s]*)?$') { throw '必须在 .env 设置可达的 EASYTIER_EXECUTOR_CALLBACK_URL（http/https）。' }
            foreach ($key in @('EASYTIER_EXECUTOR_MAX_RUNNING','EASYTIER_EXECUTOR_MAX_PENDING','EASYTIER_EXECUTOR_MAX_MEDIA_SESSIONS','EASYTIER_EXECUTOR_MAX_MEDIA_STARTING')) {
                $value = Get-ConfigValue $key
                if ($value -notmatch '^[1-9]\d*$') { throw "$key 必须为正整数。" }
            }
            $ttl = 0
            if (-not [int]::TryParse((Get-ConfigValue 'EASYTIER_EXECUTOR_TURN_TTL_SECONDS' '3600'),[ref]$ttl) -or $ttl -lt 1 -or $ttl -gt 86400) { throw 'EASYTIER_EXECUTOR_TURN_TTL_SECONDS 必须在 1-86400 范围内。' }
            $existing = Test-ContainerExists 'easytier-automation-executor'
            if ([string]::IsNullOrEmpty((Get-ConfigValue 'EASYTIER_EXECUTOR_TOKEN'))) {
                $runtime = Join-Path $script:SoftwareRoot 'easytier-automation-executor\data\runtime'
                $adb = Join-Path $script:SoftwareRoot 'easytier-automation-executor\data\adb'
                if ($existing -or @(Get-ChildItem -LiteralPath $runtime -Force -ErrorAction SilentlyContinue).Count -gt 0 -or @(Get-ChildItem -LiteralPath $adb -Force -ErrorAction SilentlyContinue).Count -gt 0) {
                    throw '已有执行器容器/运行记录/ADB 密钥但 Token 为空；请恢复 .secrets 中原有 Token，拒绝自动轮换。'
                }
                Ensure-HexSecret 'EASYTIER_EXECUTOR_TOKEN'
            }
            $token = Get-ConfigValue 'EASYTIER_EXECUTOR_TOKEN'
            if ([Text.Encoding]::UTF8.GetByteCount($token) -lt 32 -or [Text.Encoding]::UTF8.GetByteCount($token) -gt 4096 -or $token -match '[\x00-\x1f]') {
                throw 'EASYTIER_EXECUTOR_TOKEN 必须为 32-4096 字节且不能包含控制字符。'
            }
            $turnSecret = Get-ConfigValue 'EASYTIER_EXECUTOR_TURN_SECRET'
            $turnUrls = Get-ConfigValue 'EASYTIER_EXECUTOR_TURN_URLS' '[]'
            if ($turnSecret -and $turnUrls -eq '[]') { throw '设置 TURN_SECRET 时还必须提供 TURN_URLS。' }
            if (-not $turnSecret -and $turnUrls -ne '[]') { throw '设置 TURN_URLS 时还必须在 .secrets 中提供 TURN_SECRET。' }
            Write-Warning '执行器 Compose 使用 host 网络；请确认 Docker Desktop 已启用 host networking，且执行器可访问配置中的回调地址。'
        }
        sub2api {
            $null = Test-Port 'SUB2API_HTTP_PORT' (Get-ConfigValue 'SUB2API_HTTP_PORT' '7010')
            Test-IPv4 'SUB2API_BIND_IP' (Get-ConfigValue 'SUB2API_BIND_IP' '0.0.0.0')
            foreach ($key in @('SUB2API_POSTGRES_PASSWORD','SUB2API_REDIS_PASSWORD','SUB2API_JWT_SECRET','SUB2API_TOTP_ENCRYPTION_KEY')) { Ensure-HexSecret $key }
            $password = Get-ConfigValue 'SUB2API_ADMIN_PASSWORD'
            if ($password) {
                $length = [Text.Encoding]::UTF8.GetByteCount($password)
                if ($length -lt 8 -or $length -gt 72) { throw 'SUB2API_ADMIN_PASSWORD 必须符合上游要求：8-72 UTF-8 字节。' }
            }
        }
        'qoder2api-hub' {
            $image = Get-ConfigValue 'QODER2API_HUB_IMAGE' 'ghcr.io/shuishuipingan/qoder2api-hub:latest'
            if (-not $image) { throw 'QODER2API_HUB_IMAGE 不能为空。' }
            $null = Test-Port 'QODER2API_HUB_PORT' (Get-ConfigValue 'QODER2API_HUB_PORT' '8790')
            Test-IPv4 'QODER2API_HUB_BIND_IP' (Get-ConfigValue 'QODER2API_HUB_BIND_IP' '127.0.0.1')
        }
        mihomo { Prepare-Mihomo $Task }
        default { }
    }
}

function Get-TaskContainers {
    param([string]$Task)
    switch ($Task) {
        opencode { return @('opencode') }
        frps { return @('frps') }
        easytier { return @('easytier') }
        'easytier-automation-executor' { return @('easytier-automation-executor') }
        portainer { return @('portainer') }
        flatnas { return @('flatnas') }
        sub2api { return @('sub2api','sub2api-postgres','sub2api-redis') }
        'qoder2api-hub' { return @('qoder2api-hub') }
        mihomo { return @('mihomo') }
        default { return @() }
    }
}

function Test-TaskOwnership {
    param([string]$Task)
    $expected = Get-ComposeProjectName $Task
    foreach ($name in (Get-TaskContainers $Task)) { Assert-ContainerOwner $name $expected }
}

function Ensure-ProxyNetwork {
    $network = Get-DockerOutput @('network','inspect','proxy-net')
    if ($null -eq $network) {
        Invoke-Docker @('network','create','--driver','bridge','--internal','--label','org.cibeder.deploy.role=mihomo-proxy','proxy-net') | Out-Null
        Write-Host '已创建 proxy-net。'
        return
    }
    $driver = Get-DockerOutput @('network','inspect','--format','{{.Driver}}','proxy-net')
    $internal = Get-DockerOutput @('network','inspect','--format','{{.Internal}}','proxy-net')
    $scope = Get-DockerOutput @('network','inspect','--format','{{.Scope}}','proxy-net')
    if ($driver -ne 'bridge' -or $internal -ne 'true' -or $scope -ne 'local') { throw '已有同名 proxy-net 不是 local internal bridge，拒绝接管。' }
}

function Invoke-ProxyCommand {
    param([string[]]$Arguments)
    Check-DockerRuntime
    $action = if ($Arguments.Count -gt 0) { $Arguments[0] } else { '' }
    $target = if ($Arguments.Count -gt 1) { $Arguments[1] } else { '' }
    switch ($action) {
        ensure {
            if ($Arguments.Count -ne 1) { throw '用法：.\deploy.ps1 proxy ensure' }
            Ensure-ProxyNetwork
        }
        connect {
            if ($Arguments.Count -ne 2 -or -not $target) { throw '用法：.\deploy.ps1 proxy connect <容器名>' }
            Ensure-ProxyNetwork
            if (-not (Test-ContainerExists 'mihomo')) { throw '找不到 mihomo 容器，请先安装 Mihomo Docker 模式。' }
            if ((Get-DockerOutput @('inspect','--format','{{.State.Status}}','mihomo')) -ne 'running') { throw 'Mihomo 容器未运行。' }
            $targetId = Get-DockerOutput @('inspect','--format','{{.Id}}',$target)
            if (-not $targetId) { throw "找不到目标容器：$target" }
            $mihomoId = Get-DockerOutput @('inspect','--format','{{.Id}}','mihomo')
            if ($targetId -eq $mihomoId) { throw '禁止修改 Mihomo 自身的网络连接。' }
            $mode = Get-DockerOutput @('inspect','--format','{{.HostConfig.NetworkMode}}',$target)
            if ($mode -eq 'host' -or $mode -eq 'none' -or $mode.StartsWith('container:')) { throw "$target 的 $mode 网络模式不支持动态接入。" }
            $members = Get-DockerOutput @('network','inspect','--format','{{range $key, $_ := .Containers}}{{println $key}}{{end}}','proxy-net')
            if ($members -notmatch [regex]::Escape($targetId)) { Invoke-Docker @('network','connect','proxy-net',$target) }
            Write-Host "$target 已接入 proxy-net；应用需自行配置有认证的 mihomo:7890。"
        }
        disconnect {
            if ($Arguments.Count -ne 2 -or -not $target) { throw '用法：.\deploy.ps1 proxy disconnect <容器名>' }
            Ensure-ProxyNetwork
            $targetId = Get-DockerOutput @('inspect','--format','{{.Id}}',$target)
            if (-not $targetId) { throw "找不到目标容器：$target" }
            $mihomoId = Get-DockerOutput @('inspect','--format','{{.Id}}','mihomo')
            if ($targetId -eq $mihomoId) { throw '禁止修改 Mihomo 自身的网络连接。' }
            $members = Get-DockerOutput @('network','inspect','--format','{{range $key, $_ := .Containers}}{{println $key}}{{end}}','proxy-net')
            if ($members -match [regex]::Escape($targetId)) { Invoke-Docker @('network','disconnect','proxy-net',$target) }
            Write-Host "$target 已断开或此前未连接 proxy-net。"
        }
        status {
            if ($Arguments.Count -gt 2) { throw '用法：.\deploy.ps1 proxy status [容器名]' }
            Ensure-ProxyNetwork
            if ($target) {
                $targetId = Get-DockerOutput @('inspect','--format','{{.Id}}',$target)
                if (-not $targetId) { throw "找不到目标容器：$target" }
                $members = Get-DockerOutput @('network','inspect','--format','{{range $key, $_ := .Containers}}{{println $key}}{{end}}','proxy-net')
                if ($members -match [regex]::Escape($targetId)) { Write-Host "$target：已接入 proxy-net" }
                else { Write-Host "$target：未接入 proxy-net" }
            } else {
                Write-Host (Get-DockerOutput @('network','inspect','--format','{{range .Containers}}{{println .Name}}{{end}}','proxy-net'))
            }
        }
        default { throw '用法：.\deploy.ps1 proxy {ensure|connect|disconnect|status} [容器名]' }
    }
}

function Invoke-Task {
    param([string]$Task, [string]$Action = 'install')
    if ($Action -in @('up','')) { $Action = 'install' }
    if ($Action -eq 'pull') { $Action = 'update' }
    if ($Action -in @('host','host-update')) {
        if ($Task -ne 'mihomo') { throw 'host/host-update 仅支持 mihomo。' }
        throw 'Mihomo host 是 Linux systemd 原生安装，不使用 Docker；此 Windows PowerShell 入口不会执行它。'
    }
    if ($Action -notin @('install','update','sync')) {
        throw "不支持的操作：$Action。支持 install / update / sync；mihomo host 模式不属于 Windows Docker 部署。"
    }
    Sync-Task $Task
    if ($Action -eq 'sync') { Initialize-AppConfiguration $Task; return }

    $composeFile = Join-Path (Join-Path (Join-Path $script:SoftwareRoot $Task) 'deploy') 'docker-compose.yaml'
    if (-not (Test-Path -LiteralPath $composeFile)) {
        throw "$Task 不是 Docker Compose 服务。Windows PowerShell 入口不会调用任何 Bash 脚本；Linux/systemd 或 OpenWrt 业务请继续在对应 Linux 环境部署。"
    }
    $configResult = Ensure-GlobalConfig
    Initialize-AppConfiguration $Task
    Load-Configuration
    if ($configResult.Created) {
        Write-Host '统一配置已创建。请先编辑普通配置和敏感配置，再重新执行安装。'
        Write-Host "普通配置：$(if ($script:AppEnv) { $script:AppEnv } else { $script:GlobalEnv })"
        Write-Host "敏感配置：$(if ($script:AppSecrets) { $script:AppSecrets } else { $script:GlobalSecrets })"
        return
    }
    Check-DockerRuntime
    if ($Action -eq 'update' -and $Task -ne 'easytier-automation-executor') {
        $firstContainer = Get-TaskContainers $Task | Select-Object -First 1
        if ($firstContainer -and -not (Test-ContainerExists $firstContainer)) { throw "未找到 $Task 的现有容器；请先执行 .\deploy.ps1 $Task install。" }
    }
    Prepare-Task $Task $Action
    Load-Configuration
    Set-MirrorImages $Task
    Test-TaskOwnership

    $socket = $Task -eq 'flatnas' -and (Get-ConfigValue 'FLATNAS_DOCKER_SOCKET' 'false') -eq 'true'
    Invoke-Compose $Task @('config','--quiet') -SocketOverride:$socket

    switch ($Task) {
        opencode {
            Write-Host '构建 OpenCode 镜像...'
            Invoke-Compose $Task @('build','--pull','--progress','plain','opencode')
            if ($Action -eq 'update' -and (Test-ContainerExists 'opencode')) {
                try { Invoke-Compose $Task @('stop','opencode') } catch { Write-Warning '停止 OpenCode 容器时返回错误，将继续尝试更新。' }
            }
            Invoke-Compose $Task @('up','-d','--wait','--wait-timeout','120','opencode')
        }
        frps {
            Invoke-Compose $Task @('pull','frps')
            if ($Action -eq 'update') {
                try { Invoke-Compose $Task @('stop','frps') } catch { }
            }
            Invoke-Compose $Task @('up','-d','--wait','--wait-timeout','120','frps')
        }
        portainer {
            Invoke-Compose $Task @('pull','portainer')
            $upArgs = if ($Action -eq 'update') { @('up','-d','--wait','--wait-timeout','90','--no-deps','portainer') } else { @('up','-d','--wait','--wait-timeout','90','portainer') }
            Invoke-Compose $Task $upArgs
            $legacy = Join-Path (Join-Path $script:SoftwareRoot 'portainer\deploy') '.secrets\admin_password'
            if (Test-Path -LiteralPath $legacy) {
                Remove-Item -LiteralPath $legacy -Force
                $parent = Split-Path -Parent $legacy
                if ((Test-Path -LiteralPath $parent) -and @(Get-ChildItem -LiteralPath $parent -Force).Count -eq 0) { Remove-Item -LiteralPath $parent -Force }
            }
        }
        flatnas {
            Invoke-Compose $Task @('pull','flatnas') -SocketOverride:$socket
            Invoke-Compose $Task @('up','-d','--wait','--wait-timeout','90','flatnas') -SocketOverride:$socket
        }
        easytier {
            Invoke-Compose $Task @('pull','easytier')
            Invoke-Compose $Task @('up','-d','--wait','--wait-timeout','90','easytier')
        }
        'easytier-automation-executor' {
            Invoke-Compose $Task @('pull','easytier-automation-executor')
            $image = Get-ConfigValue 'DEPLOY_EASYTIER_EXECUTOR_IMAGE' (Get-ConfigValue 'EASYTIER_EXECUTOR_IMAGE' 'ghcr.io/cibederorg/easytier-automation-executor:feat-automation-center')
            $arch = Get-DockerOutput @('image','inspect','--format','{{.Architecture}}',$image)
            if ($arch -and $arch -ne 'amd64') { throw "执行器镜像架构为 $arch，预期 amd64；未替换容器。" }
            Invoke-Compose $Task @('up','-d','--no-deps','--force-recreate','--pull','never','easytier-automation-executor')
            $healthCode = 'import json, os, urllib.request; from automation_executor.auth import authorization; ip = os.environ.get("EASYTIER_EXECUTOR_BIND_IP", "127.0.0.1"); ip = "127.0.0.1" if ip == "0.0.0.0" else ip; port = os.environ.get("EASYTIER_EXECUTOR_PORT", "8766"); request = urllib.request.Request("http://%s:%s/internal/v1/health" % (ip, port), headers={"Authorization": authorization(os.environ["AUTOMATION_TOKEN"])}); response = urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=2); data = json.load(response); assert data["protocol_version"] == 1 and data["executor_id"] and data["state"] == "ready"'
            $ready = $false
            $bindIp = Get-ConfigValue 'EASYTIER_EXECUTOR_BIND_IP' '127.0.0.1'
            $port = Get-ConfigValue 'EASYTIER_EXECUTOR_PORT' '8766'
            for ($attempt = 0; $attempt -lt 25; $attempt++) {
                $health = Get-DockerOutput @('exec','-e',"EASYTIER_EXECUTOR_BIND_IP=$bindIp",'-e',"EASYTIER_EXECUTOR_PORT=$port",'easytier-automation-executor','python','-c',$healthCode)
                if ($null -ne $health) { $ready = $true; break }
                Start-Sleep -Seconds 1
            }
            if (-not $ready) {
                try { Invoke-Compose $Task @('logs','--tail=80','easytier-automation-executor') } catch { }
                throw '执行器未通过内部认证健康检查；请检查 docker logs easytier-automation-executor。Token 和 ADB 数据不会被删除。'
            }
        }
        sub2api {
            Invoke-Compose $Task @('pull')
            Invoke-Compose $Task @('up','-d','--wait','--wait-timeout','240')
        }
        'qoder2api-hub' {
            Invoke-Compose $Task @('pull','qoder2api-hub')
            Invoke-Compose $Task @('up','-d','--no-deps','--force-recreate','--pull','never','--wait','--wait-timeout','120','qoder2api-hub')
        }
        mihomo {
            Invoke-Compose $Task @('pull','mihomo')
            Invoke-Compose $Task @('up','-d','--force-recreate','--wait','--wait-timeout','180','mihomo')
            $healthy = $false
            for ($attempt = 0; $attempt -lt 30; $attempt++) {
                $result = Get-DockerOutput @('exec','mihomo','node','-e','fetch("http://127.0.0.1:9090/version",{headers:{Authorization:"Bearer "+process.env.CLASH_SECRET}}).then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))')
                if ($null -ne $result) { $healthy = $true; break }
                Start-Sleep -Seconds 1
            }
            if (-not $healthy) { throw 'Mihomo Web/Agent 已提交启动，但内核 API 未通过检查；请查看 docker logs mihomo。' }
        }
        default { throw "尚未实现 $Task 的 Windows 原生 Docker 部署处理。" }
    }
    Write-Host ''
    Write-Host "[$Task] $Action 完成。"
    try { Invoke-Compose $Task @('ps') -SocketOverride:$socket } catch { Write-Warning $_.Exception.Message }
}

function Show-Usage {
    $usageText = @'
用法：
  .\deploy.ps1                       交互选择业务
  .\deploy.ps1 list                  列出业务
  .\deploy.ps1 env                   初始化/检查 Windows 全局配置
  .\deploy.ps1 <业务>                 安装 Docker Compose 服务
  .\deploy.ps1 <业务> install         安装
  .\deploy.ps1 <业务> update          更新
  .\deploy.ps1 <业务> sync            仅同步文件，不启动容器
  .\deploy.ps1 proxy ensure           创建/验证 Mihomo 内部代理网络
  .\deploy.ps1 proxy connect <容器>   接入代理网络
  .\deploy.ps1 proxy disconnect <容器> 断开代理网络
  .\deploy.ps1 proxy status [容器]    查看代理网络状态

说明：
  这是 Windows 原生 PowerShell 入口，不调用 Bash 或 WSL。
  Docker 服务直接调用 Windows 上的 Docker CLI / Docker Compose。
  Windows 默认软件根目录为 %LOCALAPPDATA%\CiBeDerORG\deploy\software。
  可通过环境变量 SOFTWARE_ROOT 指定其他目录。
  Linux systemd、OpenWrt 和 Mihomo host 原生模式不由此脚本执行。
  EasyTier/执行器使用 Linux host 网络或 TUN 的配置在 Docker Desktop 上可能受限。
'@
    Write-Host $usageText
}

function Invoke-Main {
    param([string[]]$Arguments)
    if (-not $Arguments -or $Arguments.Count -eq 0) {
        List-Tasks
        $choice = Read-Host '请选择业务编号或名称（0 退出）'
        if ($choice -in @('0','q','quit')) { return }
        $task = Resolve-Task $choice
        $action = Read-Host '操作 install/update/sync（默认 install）'
        if ([string]::IsNullOrWhiteSpace($action)) { $action = 'install' }
        Invoke-Task $task $action
        return
    }
    switch ($Arguments[0]) {
        { $_ -in @('-h','--help','help') } { Show-Usage; return }
        list { List-Tasks; return }
        env {
            $result = Ensure-GlobalConfig
            if ($result.Created) { Write-Host "统一配置已创建：$($script:GlobalEnv) / $($script:GlobalSecrets)" }
            elseif ($result.Updated) { Write-Host "统一配置已更新：$($script:GlobalEnv) / $($script:GlobalSecrets)" }
            else { Write-Host "统一配置已是最新：$($script:GlobalEnv) / $($script:GlobalSecrets)" }
            return
        }
        proxy {
            if ($Arguments.Count -lt 2) { throw '用法：.\deploy.ps1 proxy {ensure|connect|disconnect|status} [容器名]' }
            Invoke-ProxyCommand -Arguments @($Arguments | Select-Object -Skip 1)
            return
        }
        default {
            if ($Arguments.Count -gt 2) { Show-Usage; throw '参数过多。' }
            $task = Resolve-Task $Arguments[0]
            $action = if ($Arguments.Count -gt 1) { $Arguments[1] } else { 'install' }
            Invoke-Task $task $action
        }
    }
}

try {
    Initialize-Paths
    if ($CliArgs -and $CliArgs.Count -gt 0) { Invoke-Main -Arguments $CliArgs }
    else { Invoke-Main -Arguments @() }
} catch {
    Write-Host ''
    Write-Host ("[ERROR] " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
