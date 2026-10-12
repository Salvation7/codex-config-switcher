Set-StrictMode -Version 2.0

$script:SwitcherRootKeys = @(
    'model_provider', 'model', 'model_reasoning_effort', 'model_catalog_json', 'service_tier', 'web_search',
    'preferred_auth_method', 'forced_login_method', 'show_raw_agent_reasoning',
    'profile', 'oss_provider', 'openai_base_url', 'model_context_window', 'model_auto_compact_token_limit',
    'model_auto_compact_token_limit_scope', 'base_instructions', 'model_instructions_file', 'compact_prompt',
    'experimental_compact_prompt_file', 'model_verbosity', 'model_reasoning_summary',
    'plan_mode_reasoning_effort', 'experimental_use_unified_exec_tool'
)
$script:DesktopEfforts = '["low", "medium", "high", "xhigh", "ultra", "max"]'

function ConvertTo-TomlString {
    param([AllowEmptyString()][string]$Value)
    return (ConvertTo-Json -InputObject $Value -Compress)
}

function ConvertFrom-TomlScalar {
    param([string]$Value)
    if ($Value -match '^\s*"((?:\\.|[^"\\])*)"') {
        return (ConvertFrom-Json -InputObject $Matches[0].Trim())
    }
    if ($Value -match "^\s*'([^']*)'") { return $Matches[1] }
    return (($Value -split '#', 2)[0].Trim())
}

function Get-TomlLineMap {
    # Track multiline strings so text resembling a table/key inside a prompt is untouched.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $lines = [regex]::Split($Text, '\r\n|\n|\r')
    $section = ''
    $multi = ''
    $depth = 0
    $active = $null
    $entries = New-Object 'System.Collections.Generic.List[object]'
    for ($lineIndex = 0; $lineIndex -lt $lines.Length; $lineIndex++) {
        $line = $lines[$lineIndex]
        $entry = [pscustomobject]@{ Index = $lineIndex; EndIndex = $lineIndex; Line = $line; Section = $section; Key = $null; Value = $null; IsHeader = $false }
        if ($multi -eq '' -and $depth -eq 0) {
            if ($line -match '^\s*\[\[?(.*?)\]\]?\s*(?:#.*)?$') {
                $section = $Matches[1].Trim()
                $entry.Section = $section
                $entry.IsHeader = $true
            } elseif ($line -match '^\s*(?:([A-Za-z0-9_-]+)|"([A-Za-z0-9_-]+)"|''([A-Za-z0-9_-]+)'')\s*=\s*(.*)$') {
                foreach ($keyGroup in 1..3) { if ($Matches[$keyGroup]) { $entry.Key = $Matches[$keyGroup]; break } }
                $entry.Value = $Matches[4]
                $active = $entry
            }
        }
        $entries.Add($entry)
        $quote = ''
        for ($charIndex = 0; $charIndex -lt $line.Length; $charIndex++) {
            $character = $line[$charIndex]
            $triple = if ($charIndex + 2 -lt $line.Length) { $line.Substring($charIndex, 3) } else { '' }
            if ($multi -ne '') {
                if ($multi -eq '"""' -and $character -eq '\') { $charIndex++; continue }
                if ($triple -eq $multi) { $multi = ''; $charIndex += 2 }
                continue
            }
            if ($quote -ne '') {
                if ($quote -eq '"' -and $character -eq '\') { $charIndex++; continue }
                if ([string]$character -eq $quote) { $quote = '' }
                continue
            }
            if ($character -eq '#') { break }
            if ($triple -eq '"""' -or $triple -eq "'''") { $multi = $triple; $charIndex += 2; continue }
            if ($character -eq '"' -or $character -eq "'") { $quote = [string]$character }
            elseif ($character -eq '[' -or $character -eq '{') { $depth++ }
            elseif ($character -eq ']' -or $character -eq '}') { $depth-- }
        }
        if ($null -ne $active) {
            $active.EndIndex = $lineIndex
            if ($multi -eq '' -and $depth -eq 0) { $active = $null }
        }
    }
    if ($multi -ne '') { throw 'The configuration contains an unterminated TOML multiline string.' }
    if ($depth -ne 0) { throw 'The configuration contains an unterminated TOML array or inline table.' }
    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    foreach ($entry in $entries) {
        if ($entry.Key -and $entry.EndIndex -gt $entry.Index) {
            $entry.Value += $newline + ($lines[($entry.Index + 1)..$entry.EndIndex] -join $newline)
        }
        $entry
    }
}

function Get-RootSettings {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $settings = [ordered]@{}
    foreach ($entry in @(Get-TomlLineMap -Text $Text)) {
        if ($entry.Section -eq '' -and $script:SwitcherRootKeys -ccontains $entry.Key) {
            if ($settings.Contains($entry.Key)) { throw ('Duplicate root setting: ' + $entry.Key) }
            $settings[$entry.Key] = $entry.Value
        }
    }
    return ,$settings
}

function Set-RootSettings {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $body = New-Object 'System.Collections.Generic.List[string]'
    $skipThrough = -1
    foreach ($entry in @(Get-TomlLineMap -Text $Text)) {
        if ($entry.Index -le $skipThrough) { continue }
        if (($entry.Section -eq '' -and $script:SwitcherRootKeys -ccontains $entry.Key) -or
            ($entry.Section -ceq 'memories' -and $script:SwitcherRootKeys[0..3] -ccontains $entry.Key)) {
            $skipThrough = $entry.EndIndex; continue
        }
        $body.Add($entry.Line)
    }
    while ($body.Count -gt 0 -and [string]::IsNullOrWhiteSpace($body[0])) { $body.RemoveAt(0) }
    $prefix = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in $script:SwitcherRootKeys) {
        if ($Settings.Contains($key) -and $null -ne $Settings[$key]) {
            $prefix.Add($key + ' = ' + $Settings[$key])
        }
    }
    return (($prefix -join $newline) + $newline + $newline + ($body -join $newline))
}

function Get-DesktopSettings {
    param([string]$Text)
    $map = [ordered]@{}
    foreach ($entry in @(Get-TomlLineMap -Text $Text)) {
        if ($entry.Section -ceq 'desktop' -and $entry.Key -ceq 'enabled-reasoning-efforts') {
            if ($map.Contains($entry.Key)) { throw 'Duplicate desktop reasoning setting.' }
            $map[$entry.Key] = $entry.Value
        }
    }
    return ,$map
}

function Set-DesktopSettings {
    param([string]$Text, [System.Collections.IDictionary]$Settings, [bool]$PreserveEmptyTable = $true)
    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $out = New-Object 'System.Collections.Generic.List[string]'
    $written = $false
    $skipThrough = -1
    $removeSeparator = $false
    $headers = @(Get-TomlLineMap -Text $Text | Where-Object { $_.IsHeader -and $_.Section -ceq 'desktop' })
    if ($headers.Count -gt 1) { throw 'Duplicate desktop section.' }
    $entries = @(Get-TomlLineMap -Text $Text)
    $otherDesktopKeys = @($entries | Where-Object { $_.Section -ceq 'desktop' -and $_.Key -and $_.Key -cne 'enabled-reasoning-efforts' })
    foreach ($entry in $entries) {
        if ($entry.Index -le $skipThrough) { continue }
        if ($entry.Section -ceq 'desktop' -and $entry.Key -ceq 'enabled-reasoning-efforts') {
            $skipThrough = $entry.EndIndex; continue
        }
        if ($entry.IsHeader -and $entry.Section -ceq 'desktop' -and -not $PreserveEmptyTable -and $otherDesktopKeys.Count -eq 0 -and $Settings.Count -eq 0) {
            if ($out.Count -gt 0 -and [string]::IsNullOrWhiteSpace($out[$out.Count - 1])) { $out.RemoveAt($out.Count - 1) }
            $removeSeparator = $true
            continue
        }
        if ($removeSeparator -and [string]::IsNullOrWhiteSpace($entry.Line)) { $removeSeparator = $false; continue }
        $out.Add($entry.Line)
        if ($entry.IsHeader -and $entry.Section -ceq 'desktop') {
            if ($Settings.Contains('enabled-reasoning-efforts')) { $out.Add('enabled-reasoning-efforts = ' + $Settings['enabled-reasoning-efforts']) }
            $written = $true
        }
    }
    if (-not $written -and $Settings.Contains('enabled-reasoning-efforts')) {
        $out.Add(''); $out.Add('[desktop]'); $out.Add('enabled-reasoning-efforts = ' + $Settings['enabled-reasoning-efforts']); $out.Add('')
    }
    return ($out -join $newline)
}

function Resolve-ProviderId {
    param([string]$Text, [string]$PreferredId)
    $ids = @(Get-TomlLineMap -Text $Text | Where-Object {
        $_.IsHeader -and $_.Section -cmatch '^model_providers\.([A-Za-z0-9_-]+)$'
    } | ForEach-Object { $_.Section.Substring('model_providers.'.Length) } | Select-Object -Unique)
    $exact = @($ids | Where-Object { $_ -ceq $PreferredId })
    if ($exact.Count -eq 1) { return $exact[0] }
    $compatible = @($ids | Where-Object { $_ -ieq $PreferredId })
    if ($compatible.Count -eq 1) { return $compatible[0] }
    if ($compatible.Count -gt 1) { throw 'Multiple provider IDs differ only by case. Select one explicitly in config.toml.' }
    return $PreferredId
}

function Get-ProviderSettings {
    param([string]$Text, [string]$ProviderId)
    $ProviderId = Resolve-ProviderId -Text $Text -PreferredId $ProviderId
    $settings = [ordered]@{}
    foreach ($entry in @(Get-TomlLineMap -Text $Text)) {
        if ($entry.Section -ceq ('model_providers.' + $ProviderId) -and $entry.Key) { $settings[$entry.Key] = $entry.Value }
    }
    return ,$settings
}

function Set-ProviderSettings {
    param([string]$Text, [string]$ProviderId, [System.Collections.IDictionary]$Settings)
    if ($ProviderId -notmatch '^[A-Za-z0-9_-]+$') { throw 'Invalid provider ID.' }
    $ProviderId = Resolve-ProviderId -Text $Text -PreferredId $ProviderId
    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $entries = @(Get-TomlLineMap -Text $Text)
    $section = 'model_providers.' + $ProviderId
    $headers = @($entries | Where-Object { $_.IsHeader -and $_.Section -ceq $section })
    if ($headers.Count -gt 1) { throw 'Duplicate provider section.' }
    $output = New-Object 'System.Collections.Generic.List[string]'
    $written = $false
    $skipThrough = -1
    foreach ($entry in $entries) {
        if ($entry.Index -le $skipThrough) { continue }
        if ($entry.Section -ceq $section -and $entry.Key -and @($Settings.Keys) -ccontains $entry.Key) { $skipThrough = $entry.EndIndex; continue }
        $output.Add($entry.Line)
        if ($entry.IsHeader -and $entry.Section -ceq $section) {
            foreach ($key in $Settings.Keys) {
                if ($null -ne $Settings[$key]) { $output.Add($key + ' = ' + $Settings[$key]) }
            }
            $written = $true
        }
    }
    if (-not $written) {
        $output.Add('')
        $output.Add('[' + $section + ']')
        foreach ($key in $Settings.Keys) {
            if ($null -ne $Settings[$key]) { $output.Add($key + ' = ' + $Settings[$key]) }
        }
        $output.Add('')
    }
    return ($output -join $newline)
}

function Get-SettingsMap {
    param($Object)
    $map = [ordered]@{}
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) { $map[$key] = $Object[$key] }
    } else {
        foreach ($property in $Object.PSObject.Properties) { $map[$property.Name] = $property.Value }
    }
    return ,$map
}

function Write-SwitcherState {
    param([string]$AppDirectory, $State)
    $path = Join-Path $AppDirectory 'state.json'
    $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($State | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temporary, $path, [System.Management.Automation.Language.NullString]::Value) } else { [IO.File]::Move($temporary, $path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Initialize-Switcher {
    param([string]$ConfigPath, [string]$AppDirectory)
    if (-not [IO.File]::Exists($ConfigPath)) { throw 'Codex config.toml was not found.' }
    $statePath = Join-Path $AppDirectory 'state.json'
    if ([IO.File]::Exists($statePath)) {
        $state = Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath | ConvertFrom-Json
        if ($state.Version -eq 1) {
            $current = [IO.File]::ReadAllText($ConfigPath)
            $saved = Get-SettingsMap $state.Native
            $currentRoot = Get-RootSettings $current
            foreach ($key in $script:SwitcherRootKeys | Select-Object -Skip 6) {
                if ($currentRoot.Contains($key)) { $saved[$key] = $currentRoot[$key] }
            }
            $state.Native = $saved
            $state | Add-Member NativeDesktop (Get-DesktopSettings $current)
            $state | Add-Member NativeDesktopExists (@(Get-TomlLineMap $current | Where-Object { $_.IsHeader -and $_.Section -ceq 'desktop' }).Count -gt 0)
            $state | Add-Member ConfigPath ([IO.Path]::GetFullPath($ConfigPath))
            $state.Version = 2
        }
        if ($state.Version -ne 2) { throw 'Unsupported switcher state version.' }
        if ($state.ConfigPath -ine [IO.Path]::GetFullPath($ConfigPath)) { throw 'This switcher belongs to a different CODEX_HOME. Native settings were not applied.' }
        return $state
    }
    $root = Get-RootSettings -Text ([IO.File]::ReadAllText($ConfigPath))
    $provider = if ($root.Contains('model_provider')) { ConvertFrom-TomlScalar $root['model_provider'] } else { 'openai' }
    if ($provider -ne 'openai') { throw 'Initialize while the native OpenAI profile is active, so it can be saved accurately.' }
    $state = [pscustomobject]@{
        Version = 2
        ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
        Native = $root
        NativeDesktop = Get-DesktopSettings ([IO.File]::ReadAllText($ConfigPath))
        NativeDesktopExists = (@(Get-TomlLineMap ([IO.File]::ReadAllText($ConfigPath)) | Where-Object { $_.IsHeader -and $_.Section -ceq 'desktop' }).Count -gt 0)
        Glm = [pscustomobject]@{ Model = 'glm-5.3'; Effort = 'max' }
        Deepseek = [pscustomobject]@{ Model = 'deepseek-flash'; Effort = 'high' }
    }
    Write-SwitcherState -AppDirectory $AppDirectory -State $state
    return $state
}

function Get-CodexExecutable {
    $command = Get-Command codex.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return $command.Source }
    $binRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $binRoot) {
        $executables = @(Get-ChildItem -LiteralPath $binRoot -Filter codex.exe -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if ($executables.Count -gt 0) { return $executables[0].FullName }
    }
    throw 'Codex CLI was not found. Configuration was not changed.'
}

function Test-CodexConfiguration {
    # Use Codex's own parser in an isolated home. No login, model request, or MCP startup.
    param([string]$Text)
    $executable = Get-CodexExecutable
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('codex-switcher-validate-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($temporary) | Out-Null
    $process = $null
    try {
        [IO.File]::WriteAllText((Join-Path $temporary 'config.toml'), $Text, (New-Object Text.UTF8Encoding($false)))
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $executable
        $start.Arguments = 'features list'
        $start.WorkingDirectory = $temporary
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.EnvironmentVariables['CODEX_HOME'] = $temporary
        foreach ($name in @('OPENAI_API_KEY', 'CODEX_API_KEY', 'CODEX_ACCESS_TOKEN')) { $start.EnvironmentVariables.Remove($name) }
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $start
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Codex configuration validation timed out. Configuration was not changed.' }
        [void]$stdout.Result; [void]$stderr.Result
        if ($process.ExitCode -ne 0) { throw 'Codex rejected the configuration. Check TOML syntax, duplicate tables, and legacy provider options. Configuration was not changed.' }
    } finally {
        if ($null -ne $process) { $process.Dispose() }
        if ([IO.Directory]::Exists($temporary)) {
            $resolved = [IO.Path]::GetFullPath($temporary)
            $base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
            if ($resolved.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('codex-switcher-validate-')) {
                Remove-Item -LiteralPath $resolved -Recurse -Force
            }
        }
    }
}

function Get-OfficialProviderSettings {
    param([string]$Mode, [string]$Text)
    $id = Resolve-ProviderId -Text $Text -PreferredId $(if ($Mode -eq 'glm') { 'ZAI' } else { 'deepseek' })
    return ,([ordered]@{
        name = ConvertTo-TomlString $id
        base_url = ConvertTo-TomlString $(if ($Mode -eq 'glm') { 'https://open.bigmodel.cn/api/v1' } else { 'https://api.deepseek.com/' })
        wire_api = '"responses"'
        supports_websockets = $null
        requires_openai_auth = $null
    })
}

function Get-SwitcherStatus {
    param([string]$ConfigPath)
    $root = Get-RootSettings -Text ([IO.File]::ReadAllText($ConfigPath))
    $provider = if ($root.Contains('model_provider')) { ConvertFrom-TomlScalar $root['model_provider'] } else { 'openai' }
    $model = if ($root.Contains('model')) { ConvertFrom-TomlScalar $root['model'] } else { '(default)' }
    $mode = switch ($provider.ToLowerInvariant()) { 'openai' { 'native' }; 'zai' { 'glm' }; 'deepseek' { 'deepseek' }; default { 'other' } }
    return [pscustomobject]@{ Mode = $mode; Model = $model; Provider = $provider }
}

function Test-ProviderConfigured {
    param([string]$Text, [string]$ProviderId)
    $provider = Get-ProviderSettings -Text $Text -ProviderId $ProviderId
    if ($provider.Contains('experimental_bearer_token')) {
        $token = ConvertFrom-TomlScalar $provider['experimental_bearer_token']
        if (-not [string]::IsNullOrWhiteSpace($token) -and $token -notmatch '^<|YOUR[_ ]|^API[_ ]?KEY$') { return $true }
    }
    if ($provider.Contains('env_key')) {
        $variable = ConvertFrom-TomlScalar $provider['env_key']
        foreach ($scope in @('Process', 'User', 'Machine')) {
            if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($variable, $scope))) { return $true }
        }
    }
    return $false
}

function Write-CodexConfigSafely {
    param([string]$ConfigPath, [string]$ExpectedText, [string]$NewText)
    if ($NewText -ceq $ExpectedText) { return $null }
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ConfigPath))
    $backupDirectory = Join-Path $directory 'config-switcher-backups'
    [IO.Directory]::CreateDirectory($backupDirectory) | Out-Null
    $suffix = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $backup = Join-Path $backupDirectory ('config-' + $suffix + '.toml')
    $temporary = Join-Path $directory ('config.toml.switcher-' + $suffix + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $NewText, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::ReadAllText($ConfigPath) -cne $ExpectedText) { throw 'Codex changed the configuration during switching. Retry the operation.' }
        [IO.File]::Replace($temporary, $ConfigPath, $backup)
        return $backup
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Get-SwitcherMutex {
    param([string]$ConfigPath)
    $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($hashAlgorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($ConfigPath).ToLowerInvariant()))).Replace('-', '') } finally { $hashAlgorithm.Dispose() }
    return (New-Object Threading.Mutex($false, ('Local\CodexConfigSwitcher-' + $hash.Substring(0, 24))))
}

function Switch-CodexProfile {
    param([ValidateSet('native', 'glm', 'deepseek')][string]$Mode, [string]$ConfigPath, [string]$AppDirectory)
    $mutex = Get-SwitcherMutex -ConfigPath $ConfigPath
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Another switch is in progress.' }
        $state = Initialize-Switcher -ConfigPath $ConfigPath -AppDirectory $AppDirectory
        $original = [IO.File]::ReadAllText($ConfigPath)
        $status = Get-SwitcherStatus -ConfigPath $ConfigPath
        if ($status.Mode -eq 'native') {
            $state.Native = Get-RootSettings -Text $original
            $state.NativeDesktop = Get-DesktopSettings -Text $original
            $state.NativeDesktopExists = (@(Get-TomlLineMap $original | Where-Object { $_.IsHeader -and $_.Section -ceq 'desktop' }).Count -gt 0)
        }
        if ($Mode -eq 'native') {
            $settings = Get-SettingsMap -Object $state.Native
            $desktop = Get-SettingsMap -Object $state.NativeDesktop
        } else {
            $providerId = if ($Mode -eq 'glm') { 'ZAI' } else { 'deepseek' }
            $providerId = Resolve-ProviderId -Text $original -PreferredId $providerId
            if (-not (Test-ProviderConfigured -Text $original -ProviderId $providerId)) { throw ('API_KEY_REQUIRED:' + $Mode) }
            $profile = if ($Mode -eq 'glm') { $state.Glm } else { $state.Deepseek }
            $catalogPath = Join-Path $AppDirectory ('catalogs\' + $Mode + '.json')
            if (-not [IO.File]::Exists($catalogPath)) { throw ('Model catalog not found: ' + $catalogPath) }
            $catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath $catalogPath | ConvertFrom-Json
            if (@($catalog.models | Where-Object { $_.slug -eq $profile.Model }).Count -ne 1) { throw 'The selected model is missing from its catalog.' }
            $selected = @($catalog.models | Where-Object { $_.slug -eq $profile.Model })[0]
            if (@($selected.supported_reasoning_levels | Where-Object { $_.effort -eq $profile.Effort }).Count -eq 0) { throw 'This model does not support the selected reasoning effort.' }
            $settings = [ordered]@{
                model_provider = ConvertTo-TomlString $providerId
                model = ConvertTo-TomlString $profile.Model
                model_reasoning_effort = ConvertTo-TomlString $profile.Effort
                model_catalog_json = ConvertTo-TomlString ($catalogPath.Replace('\', '/'))
                web_search = '"disabled"'
            }
            $desktop = Get-SettingsMap -Object $state.NativeDesktop
            if ($Mode -eq 'deepseek') {
                $settings['preferred_auth_method'] = '"apikey"'
                $settings['show_raw_agent_reasoning'] = 'true'
                # Deliberate, user-selected exception to DeepSeek's recipe: do not force
                # API login, which can log out the user's stored ChatGPT session.
                $desktop['enabled-reasoning-efforts'] = $script:DesktopEfforts
            }
        }
        $candidate = Set-RootSettings -Text $original -Settings $settings
        $preserveDesktop = if ($Mode -eq 'deepseek') { $true } else { [bool]$state.NativeDesktopExists }
        $candidate = Set-DesktopSettings -Text $candidate -Settings $desktop -PreserveEmptyTable $preserveDesktop
        if ($Mode -ne 'native') { $candidate = Set-ProviderSettings -Text $candidate -ProviderId $providerId -Settings (Get-OfficialProviderSettings -Mode $Mode -Text $candidate) }
        $verifiedRoot = Get-RootSettings -Text $candidate
        if (-not $verifiedRoot.Contains('model')) { throw 'The target configuration is missing a model.' }
        Test-CodexConfiguration -Text $candidate
        # Persist the native checkpoint before editing config, so a failed state write
        # cannot leave the user in a third-party profile without a return path.
        Write-SwitcherState -AppDirectory $AppDirectory -State $state
        $backup = Write-CodexConfigSafely -ConfigPath $ConfigPath -ExpectedText $original -NewText $candidate
        $result = Get-SwitcherStatus -ConfigPath $ConfigPath
        return [pscustomobject]@{ Mode = $result.Mode; Model = $result.Model; Changed = ($null -ne $backup); BackupPath = $backup }
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Save-ProviderConfiguration {
    param([ValidateSet('glm', 'deepseek')][string]$Mode, [string]$ApiKey, [string]$Model, [string]$Effort, [string]$ConfigPath, [string]$AppDirectory)
    $providerId = if ($Mode -eq 'glm') { 'ZAI' } else { 'deepseek' }
    if ($ApiKey -match '[\r\n]') { throw 'An API key cannot contain line breaks.' }
    $catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $AppDirectory ('catalogs\' + $Mode + '.json')) | ConvertFrom-Json
    $modelEntry = @($catalog.models | Where-Object { $_.slug -eq $Model })
    if ($modelEntry.Count -ne 1) { throw 'Select a model listed in the catalog.' }
    if (@($modelEntry[0].supported_reasoning_levels | Where-Object { $_.effort -eq $Effort }).Count -eq 0) { throw 'This model does not support the selected reasoning effort.' }
    $mutex = Get-SwitcherMutex -ConfigPath $ConfigPath
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Another switch is in progress.' }
        $original = [IO.File]::ReadAllText($ConfigPath)
        $state = Initialize-Switcher -ConfigPath $ConfigPath -AppDirectory $AppDirectory
        $settings = Get-OfficialProviderSettings -Mode $Mode -Text $original
        if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
            $settings['experimental_bearer_token'] = ConvertTo-TomlString $ApiKey.Trim()
            $settings['env_key'] = $null
        } elseif (-not (Test-ProviderConfigured -Text $original -ProviderId $providerId)) { throw 'An API key is required for first-time setup.' }
        $candidate = Set-ProviderSettings -Text $original -ProviderId $providerId -Settings $settings
        $profile = if ($Mode -eq 'glm') { $state.Glm } else { $state.Deepseek }
        $profile.Model = $Model
        $profile.Effort = $Effort
        Test-CodexConfiguration -Text $candidate
        Write-SwitcherState -AppDirectory $AppDirectory -State $state
        $backup = Write-CodexConfigSafely -ConfigPath $ConfigPath -ExpectedText $original -NewText $candidate
        return [pscustomobject]@{ Saved = $true; BackupPath = $backup }
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
