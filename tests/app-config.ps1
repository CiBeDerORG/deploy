# 从真实入口提取函数，使用临时目录验证配置迁移，不触发 Docker 或部署入口。
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'deploy.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'PowerShell 入口存在语法错误。' }
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([ScriptBlock]::Create($definition.Extent.Text))
}
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('deploy-config-test-' + [guid]::NewGuid())
try {
    $script:Utf8NoBom = [Text.UTF8Encoding]::new($false)
    $script:SoftwareRoot = $temporary
    $script:GlobalEnv = Join-Path $temporary 'deploy/.env'
    $script:GlobalSecrets = Join-Path $temporary 'deploy/.secrets'
    $script:Config = @{}
    # 非 Windows 只验证配置行为，不冒充验证 Windows ACL。
    if ($env:OS -ne 'Windows_NT') { function Protect-SecretFile { param([string]$Path) } }
    $deployment = Join-Path $temporary 'unregistered-demo/deploy'
    New-Item -ItemType Directory -Path $deployment -Force | Out-Null
    Write-TextFile (Join-Path $deployment 'config.env.example') 'APP_PORT="8080"'
    Write-TextFile (Join-Path $deployment 'config.secrets.example') 'APP_SECRET=""'
    Write-TextFile $script:GlobalEnv "APP_PORT=8123`nUNRELATED=retain`n"
    $credential = '"特殊 引号''中文 $() `literal`'
    Write-TextFile $script:GlobalSecrets ('APP_SECRET="' + $credential + '"')
    Initialize-AppConfiguration 'unregistered-demo'
    Load-Configuration
    if ((Get-ConfigValue 'APP_PORT') -ne '8123' -or (Get-ConfigValue 'APP_SECRET') -cne $credential) { throw '迁移改变了配置或密钥原值。' }
    $before = [IO.File]::ReadAllText($script:AppSecrets)
    Write-TextFile $script:GlobalSecrets 'APP_SECRET="replacement"'
    Initialize-AppConfiguration 'unregistered-demo'
    if ([IO.File]::ReadAllText($script:AppSecrets) -cne $before) { throw '重复初始化覆盖了密钥。' }
    if ((Read-ConfigFile $script:AppEnv).ContainsKey('UNRELATED')) { throw '迁移复制了其他应用配置。' }
    Write-TextFile $script:AppEnv "APP_PORT=8000`nAPP_PORT=9000"
    $rejected = $false
    try { Initialize-AppConfiguration 'unregistered-demo' } catch { $rejected = $true }
    if (-not $rejected) { throw '重复配置键未被拒绝。' }
    Write-Host 'PowerShell 应用配置迁移、原值保留与重复键检查通过。'
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
