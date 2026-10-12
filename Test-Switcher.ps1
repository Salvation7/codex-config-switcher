[CmdletBinding()]
param(
    [string]$EnginePath = '',
    [switch]$KeepFixtures
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($EnginePath)) { $EnginePath = Join-Path $PSScriptRoot 'Engine.ps1' }
$script:Passed = 0
$script:Failures = New-Object 'System.Collections.Generic.List[string]'
$script:SecretValues = @('TEST_GLM_SECRET_7d156ee4', 'TEST_DEEPSEEK_SECRET_907db226')
$script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-switcher-tests-' + [guid]::NewGuid().ToString('N'))
$script:FixtureNumber = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -cne $Actual) { throw $Message }
}

function Assert-Contains {
    param([string]$Text, [string]$Expected, [string]$Message)
    Assert-True ($Text.Contains($Expected)) $Message
}

function Assert-NoSecret {
    param($Value, [string]$Message)
    $serialized = $Value | ConvertTo-Json -Depth 30 -Compress
    foreach ($secret in $script:SecretValues) {
        Assert-True (-not $serialized.Contains($secret)) $Message
    }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed += 1
        Write-Host ('PASS ' + $Name)
    }
    catch {
        # Only print the test label and a sanitized message; config contents and tokens stay private.
        $message = $_.Exception.Message
        foreach ($secret in $script:SecretValues) { $message = $message.Replace($secret, '[redacted]') }
        $script:Failures.Add($Name + ': ' + $message)
        Write-Host ('FAIL ' + $Name + ': ' + $message)
        if ($KeepFixtures) { Write-Host $_.ScriptStackTrace }
    }
}

function Remove-FixtureMultilineStrings {
    param([string]$Text)
    # Independent, fixture-only scanner: quoted TOML text must not count as assignments or tables.
    foreach ($delimiter in @(('"' * 3), ("'" * 3))) {
        $pattern = '(?s)' + [regex]::Escape($delimiter) + '.*?' + [regex]::Escape($delimiter)
        $Text = [regex]::Replace($Text, $pattern, '""')
    }
    return $Text
}

function Get-FixtureSection {
    param([string]$Text, [string]$Section = '')
    $plain = Remove-FixtureMultilineStrings $Text
    $current = ''
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in ($plain -split '\r?\n')) {
        if ($line -match '^\s*\[([^\]\r\n]+)\]\s*(?:#.*)?$') {
            $current = $Matches[1]
            continue
        }
        if ($current -ceq $Section) { $lines.Add($line) }
    }
    return ($lines -join "`n")
}

function Get-FixtureAssignmentCount {
    param([string]$Text, [string]$Section, [string]$Key)
    $body = Get-FixtureSection -Text $Text -Section $Section
    return [regex]::Matches($body, ('(?m)^\s*' + [regex]::Escape($Key) + '\s*=')).Count
}

function Assert-PreservedContent {
    param([string]$Text)
    foreach ($block in $script:PreservedBlocks) {
        Assert-Contains $Text $block 'An unrelated comment, plugin, MCP, memories setting, or multiline string changed.'
    }
}

function New-Fixture {
    $script:FixtureNumber += 1
    $directory = Join-Path $script:TempRoot ('fixture-' + $script:FixtureNumber)
    $appDirectory = Join-Path $directory 'app'
    $catalogDirectory = Join-Path $appDirectory 'catalogs'
    $null = New-Item -ItemType Directory -Path $catalogDirectory -Force
    foreach ($catalogName in @('glm.json', 'deepseek.json')) {
        $source = Join-Path (Join-Path $PSScriptRoot 'catalogs') $catalogName
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw ('Production catalog is missing: ' + $catalogName)
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $catalogDirectory $catalogName)
    }
    $configPath = Join-Path $directory 'config.toml'
    [System.IO.File]::WriteAllText($configPath, $script:FixtureText, (New-Object System.Text.UTF8Encoding($false)))
    return [pscustomobject]@{
        Directory = $directory
        ConfigPath = $configPath
        AppDirectory = $appDirectory
        CatalogDirectory = $catalogDirectory
        Original = $script:FixtureText
    }
}

$script:LiteralBlock = @'
literal_description = '''
model = "literal text must remain"
[memories]
model_provider = "also literal text"
'''
'@
$script:BasicBlock = @'
basic_description = """
model_catalog_json = "not a setting"
[model_providers.ZAI]
model = "still text"
"""
'@
$script:McpBlock = @'
[mcp_servers.keep]
command = "example-command"
args = ["one", "two"] # Keep this comment.
'@
$script:PluginBlock = @'
[plugins."example@openai"]
enabled = true
'@
$script:MemoriesBlock = @'
# The memories flags belong to this table and must remain.
generate_memories = true
use_memories = false
'@
$script:OtherProviderBlock = @'
[model_providers.Unrelated]
name = "Unrelated"
base_url = "https://untouched.invalid/v1"
env_key = "UNRELATED_TEST_ENV"
'@
$script:PreservedBlocks = @(
    '# Original header comment.',
    $script:LiteralBlock,
    $script:BasicBlock,
    $script:McpBlock,
    $script:PluginBlock,
    $script:MemoriesBlock,
    $script:OtherProviderBlock
)

$script:FixtureText = @'
# Original header comment.
model_provider = "openai" # Original native provider.
model = "gpt-6.1-sol"
model_reasoning_effort = "max"
service_tier = "fast" # Native-only preference.
web_search = "live" # Native browsing preference.
approval_policy = "on-request"

literal_description = '''
model = "literal text must remain"
[memories]
model_provider = "also literal text"
'''
basic_description = """
model_catalog_json = "not a setting"
[model_providers.ZAI]
model = "still text"
"""

[mcp_servers.keep]
command = "example-command"
args = ["one", "two"] # Keep this comment.

[plugins."example@openai"]
enabled = true

[model_providers.ZAI]
name = "ZAI" # Keep provider comment.
base_url = "https://old-glm.invalid/v1"
experimental_bearer_token = "TEST_GLM_SECRET_7d156ee4"
wire_api = "responses"
http_headers = { "X-Keep" = "preserved" }

[model_providers.ZAI.query_params]
version = "keep-this-value"

[model_providers.DeepSeek]
name = "DeepSeek"
base_url = "https://api.deepseek.com"
experimental_bearer_token = "TEST_DEEPSEEK_SECRET_907db226"
wire_api = "responses"

[model_providers.Unrelated]
name = "Unrelated"
base_url = "https://untouched.invalid/v1"
env_key = "UNRELATED_TEST_ENV"

[memories]
# The memories flags belong to this table and must remain.
generate_memories = true
use_memories = false
model_provider = "ZAI"
model = "glm-5.3"
model_reasoning_effort = "max"
model_catalog_json = "C:/missing/models.json"

[features]
example_flag = true
'@

try {
    if (-not (Test-Path -LiteralPath $EnginePath -PathType Leaf)) { throw 'Engine.ps1 is missing.' }
    . $EnginePath
    $null = New-Item -ItemType Directory -Path $script:TempRoot -Force

    Invoke-Test 'Read root settings without confusing table keys or multiline strings' {
        $settings = Get-RootSettings -Text $script:FixtureText
        Assert-Equal '"openai" # Original native provider.' $settings['model_provider'] 'The root provider was not read correctly.'
        Assert-Equal '"gpt-6.1-sol"' $settings['model'] 'The root model was not read correctly.'
        Assert-Equal '"max"' $settings['model_reasoning_effort'] 'The root reasoning value was not read correctly.'
        Assert-Equal '"fast" # Native-only preference.' $settings['service_tier'] 'The service tier or its comment was lost.'
        Assert-Equal '"live" # Native browsing preference.' $settings['web_search'] 'The native web-search preference was not read correctly.'
        Assert-True (-not $settings.Contains('model_catalog_json')) 'A memories or multiline-text catalog was read as a root key.'
    }

    Invoke-Test 'Replace root settings, remove misplaced memories keys, preserve unrelated TOML' {
        $newSettings = [ordered]@{
            model_provider = '"ZAI"'
            model = '"glm-5.3"'
            model_reasoning_effort = '"max"'
            model_catalog_json = '"C:/catalogs/glm.json"'
            web_search = '"disabled"'
        }
        $text = Set-RootSettings -Text $script:FixtureText -Settings $newSettings
        Assert-PreservedContent $text
        foreach ($key in $newSettings.Keys) {
            Assert-Equal 1 (Get-FixtureAssignmentCount $text '' $key) ('Duplicate or missing root key: ' + $key)
            if ($key -ne 'web_search') { Assert-Equal 0 (Get-FixtureAssignmentCount $text 'memories' $key) ('Misplaced memories key remains: ' + $key) }
        }
        Assert-Equal 0 (Get-FixtureAssignmentCount $text '' 'service_tier') 'A native-only service tier remains in a third-party configuration.'
        $readBack = Get-RootSettings -Text $text
        foreach ($key in $newSettings.Keys) { Assert-Equal $newSettings[$key] $readBack[$key] ('Root value did not round-trip: ' + $key) }
        Assert-Equal $text (Set-RootSettings -Text $text -Settings $newSettings) 'Applying identical settings is not idempotent.'
    }

    Invoke-Test 'Update only the selected provider keys' {
        $text = Set-ProviderSettings -Text $script:FixtureText -ProviderId 'ZAI' -Settings ([ordered]@{
            base_url = '"https://open.bigmodel.cn/api/v1"'
            wire_api = '"responses"'
        })
        Assert-PreservedContent $text
        Assert-Contains $text 'name = "ZAI" # Keep provider comment.' 'An unchanged provider field was modified.'
        Assert-Contains $text 'experimental_bearer_token = "TEST_GLM_SECRET_7d156ee4"' 'The GLM credential was changed.'
        Assert-Contains $text 'experimental_bearer_token = "TEST_DEEPSEEK_SECRET_907db226"' 'The DeepSeek credential was changed.'
        Assert-Contains $text 'http_headers = { "X-Keep" = "preserved" }' 'Provider headers were modified.'
        Assert-Contains $text "[model_providers.ZAI.query_params]`nversion = `"keep-this-value`"" 'A nested provider table was modified.'
        foreach ($key in @('base_url', 'wire_api')) {
            Assert-Equal 1 (Get-FixtureAssignmentCount $text 'model_providers.ZAI' $key) ('Duplicate provider key: ' + $key)
        }
        Assert-Contains (Get-FixtureSection $text 'model_providers.ZAI') 'base_url = "https://open.bigmodel.cn/api/v1"' 'The provider URL was not updated.'
    }

    Invoke-Test 'Create a missing provider without changing existing tables' {
        $text = Set-ProviderSettings -Text $script:FixtureText -ProviderId 'NewProvider' -Settings ([ordered]@{
            name = '"NewProvider"'
            base_url = '"https://new.invalid/v1"'
            env_key = '"NEW_PROVIDER_KEY"'
            wire_api = '"responses"'
        })
        Assert-PreservedContent $text
        Assert-Contains (Get-FixtureSection $text 'model_providers.NewProvider') 'env_key = "NEW_PROVIDER_KEY"' 'The new provider was not created.'
        Assert-Equal 1 (Get-FixtureAssignmentCount $text 'model_providers.NewProvider' 'base_url') 'The new provider has duplicate URL keys.'
    }

    Invoke-Test 'Initialize in an isolated directory without changing the user config' {
        $fixture = New-Fixture
        $null = Initialize-Switcher -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        Assert-Equal $fixture.Original ([System.IO.File]::ReadAllText($fixture.ConfigPath)) 'Initialization modified config.toml.'
        $statePath = Join-Path $fixture.AppDirectory 'state.json'
        Assert-True (Test-Path -LiteralPath $statePath -PathType Leaf) 'Initialization did not create state.json.'
        $stateText = [System.IO.File]::ReadAllText($statePath)
        $null = $stateText | ConvertFrom-Json
        Assert-NoSecret $stateText 'The public state file contains an API credential.'
    }

    Invoke-Test 'Switch repeatedly among native, GLM, and DeepSeek; preserve backups and credentials' {
        $fixture = New-Fixture
        $null = Initialize-Switcher -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        $nativeSettings = Get-RootSettings -Text $fixture.Original
        $backups = @{}
        foreach ($mode in @('glm', 'deepseek', 'native', 'deepseek', 'glm', 'native')) {
            $before = [System.IO.File]::ReadAllText($fixture.ConfigPath)
            $result = Switch-CodexProfile -Mode $mode -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
            $after = [System.IO.File]::ReadAllText($fixture.ConfigPath)
            Assert-Equal $mode $result.Mode 'The switch result has the wrong mode.'
            Assert-True ([bool]$result.Changed) 'A switch to a different mode did not report a change.'
            Assert-NoSecret $result 'A switch result exposed an API credential.'
            Assert-True (-not [string]::IsNullOrWhiteSpace([string]$result.BackupPath)) 'The switch did not return a backup path.'
            Assert-True (Test-Path -LiteralPath $result.BackupPath -PathType Leaf) 'The backup file does not exist.'
            Assert-Equal $before ([System.IO.File]::ReadAllText($result.BackupPath)) 'The backup is not an exact copy of the pre-switch config.'
            Assert-True (-not $backups.ContainsKey($result.BackupPath)) 'A previous backup path was reused.'
            $backups[$result.BackupPath] = $before
            Assert-PreservedContent $after
            foreach ($key in @('model_provider', 'model', 'model_reasoning_effort', 'model_catalog_json', 'service_tier', 'web_search')) {
                Assert-True ((Get-FixtureAssignmentCount $after '' $key) -le 1) ('Duplicate root key after switching: ' + $key)
            }
            foreach ($key in @('model_provider', 'model', 'model_reasoning_effort', 'model_catalog_json')) {
                Assert-Equal 0 (Get-FixtureAssignmentCount $after 'memories' $key) ('Misplaced memories key survived: ' + $key)
            }
            foreach ($secret in $script:SecretValues) { Assert-Contains $after $secret 'Switching changed or removed an existing provider credential.' }
            $settings = Get-RootSettings -Text $after
            if ($mode -ceq 'native') {
                foreach ($key in $nativeSettings.Keys) { Assert-Equal $nativeSettings[$key] $settings[$key] ('Native setting was not restored: ' + $key) }
                Assert-True (-not $settings.Contains('model_catalog_json')) 'Native mode retained a third-party model catalog.'
            }
            else {
                $expectedProvider = if ($mode -ceq 'glm') { '"ZAI"' } else { '"DeepSeek"' }
                Assert-Equal $expectedProvider $settings['model_provider'] 'The selected provider is incorrect.'
                Assert-Equal 0 (Get-FixtureAssignmentCount $after '' 'service_tier') 'Third-party mode retained service_tier.'
                Assert-Equal 1 (Get-FixtureAssignmentCount $after '' 'model_catalog_json') 'Third-party mode has no model catalog.'
                Assert-Equal '"disabled"' $settings['web_search'] 'Third-party mode did not disable unsupported web search.'
                if ($mode -ceq 'glm') { Assert-Equal '"glm-5.3"' $settings['model'] 'GLM mode did not select glm-5.3.' }
            }
            $status = Get-SwitcherStatus -ConfigPath $fixture.ConfigPath
            Assert-Equal $mode $status.Mode 'The displayed status disagrees with the selected mode.'
            Assert-NoSecret $status 'The public switcher status exposed an API credential.'
            Assert-True (-not [string]::IsNullOrWhiteSpace([string]$status.Model)) 'The public status has no model name.'
        }
        foreach ($backupPath in $backups.Keys) {
            Assert-Equal $backups[$backupPath] ([System.IO.File]::ReadAllText($backupPath)) 'An earlier backup was overwritten by a later switch.'
        }
        Assert-NoSecret ([System.IO.File]::ReadAllText((Join-Path $fixture.AppDirectory 'state.json'))) 'state.json exposed a provider credential after switching.'
    }

    Invoke-Test 'Repeatedly selecting the current mode does not rewrite config or create a backup' {
        $fixture = New-Fixture
        $null = Switch-CodexProfile -Mode 'deepseek' -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        $before = [System.IO.File]::ReadAllBytes($fixture.ConfigPath)
        $result = Switch-CodexProfile -Mode 'deepseek' -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        Assert-True (-not [bool]$result.Changed) 'Selecting the current mode unexpectedly rewrote the config.'
        Assert-True ([string]::IsNullOrWhiteSpace([string]$result.BackupPath)) 'An unchanged config unexpectedly produced a backup.'
        Assert-Equal ([Convert]::ToBase64String($before)) ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($fixture.ConfigPath))) 'Selecting the current mode modified config bytes.'
        Assert-NoSecret $result 'The no-change result exposed an API credential.'
    }

    Invoke-Test 'First-time key setup saves privately and enables later switching' {
        $fixture = New-Fixture
        $withoutKey = $fixture.Original.Replace('experimental_bearer_token = "TEST_DEEPSEEK_SECRET_907db226"', '# DeepSeek API key has not been configured.')
        [System.IO.File]::WriteAllText($fixture.ConfigPath, $withoutKey, (New-Object System.Text.UTF8Encoding($false)))
        $failed = $false
        try { $null = Switch-CodexProfile -Mode 'deepseek' -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory }
        catch { $failed = $true }
        Assert-True $failed 'Switching was allowed before first-time key setup.'
        Assert-Equal $withoutKey ([System.IO.File]::ReadAllText($fixture.ConfigPath)) 'A missing-key failure changed config.toml.'
        $saved = Save-ProviderConfiguration -Mode 'deepseek' -ApiKey 'TEST_DEEPSEEK_SECRET_907db226' -Model 'deepseek-flash' -Effort 'high' -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        Assert-True ([bool]$saved.Saved) 'First-time key setup did not report success.'
        Assert-NoSecret $saved 'Key setup exposed an API credential in its return value.'
        Assert-Equal $withoutKey ([System.IO.File]::ReadAllText($saved.BackupPath)) 'The key setup backup is incorrect.'
        $after = [System.IO.File]::ReadAllText($fixture.ConfigPath)
        Assert-PreservedContent $after
        Assert-Contains $after 'experimental_bearer_token = "TEST_DEEPSEEK_SECRET_907db226"' 'The new API credential was not saved.'
        Assert-Equal 'native' (Get-SwitcherStatus -ConfigPath $fixture.ConfigPath).Mode 'Saving a key unexpectedly changed the active model.'
        Assert-NoSecret ([System.IO.File]::ReadAllText((Join-Path $fixture.AppDirectory 'state.json'))) 'Key setup leaked the API credential into public state.'
        $savedAgain = Save-ProviderConfiguration -Mode 'deepseek' -ApiKey '' -Model 'deepseek-flash' -Effort 'high' -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        Assert-NoSecret $savedAgain 'Saving profile options exposed an API credential.'
        Assert-Contains ([System.IO.File]::ReadAllText($fixture.ConfigPath)) 'experimental_bearer_token = "TEST_DEEPSEEK_SECRET_907db226"' 'Leaving the API-key field empty erased an existing credential.'
        $selected = Switch-CodexProfile -Mode 'deepseek' -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        Assert-Equal 'deepseek' $selected.Mode 'Switching still failed after first-time key setup.'
        Assert-NoSecret $selected 'The post-setup switch exposed an API credential.'
    }

    Invoke-Test 'Invalid API-key input or unsupported model options fail without writing' {
        $fixture = New-Fixture
        foreach ($inputCase in @(
            @{ ApiKey = "bad`nkey"; Model = 'deepseek-flash'; Effort = 'high' },
            @{ ApiKey = 'TEST_DEEPSEEK_SECRET_907db226'; Model = 'not-in-catalog'; Effort = 'high' },
            @{ ApiKey = 'TEST_DEEPSEEK_SECRET_907db226'; Model = 'deepseek-flash'; Effort = 'unsupported-effort' }
        )) {
            $before = [System.IO.File]::ReadAllBytes($fixture.ConfigPath)
            $failed = $false
            try { $null = Save-ProviderConfiguration -Mode 'deepseek' -ApiKey $inputCase.ApiKey -Model $inputCase.Model -Effort $inputCase.Effort -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory }
            catch { $failed = $true }
            Assert-True $failed 'Invalid provider input was accepted.'
            Assert-Equal ([Convert]::ToBase64String($before)) ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($fixture.ConfigPath))) 'Rejected provider input changed config.toml.'
        }
    }

    Invoke-Test 'Backup preserves original bytes even when the original has a UTF-8 BOM' {
        $fixture = New-Fixture
        [System.IO.File]::WriteAllText($fixture.ConfigPath, $fixture.Original, (New-Object System.Text.UTF8Encoding($true)))
        $before = [System.IO.File]::ReadAllBytes($fixture.ConfigPath)
        $result = Switch-CodexProfile -Mode 'deepseek' -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        Assert-Equal ([Convert]::ToBase64String($before)) ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($result.BackupPath))) 'The backup did not preserve the original BOM and bytes.'
    }

    Invoke-Test 'An existing lowercase deepseek provider stays lowercase during setup and switching' {
        $fixture = New-Fixture
        $lowercaseText = $fixture.Original.Replace('[model_providers.DeepSeek]', '[model_providers.deepseek]')
        [System.IO.File]::WriteAllText($fixture.ConfigPath, $lowercaseText, (New-Object System.Text.UTF8Encoding($false)))
        $null = Initialize-Switcher -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        $saved = Save-ProviderConfiguration -Mode 'deepseek' -ApiKey '' -Model 'deepseek-flash' -Effort 'high' -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        Assert-NoSecret $saved 'Saving an existing lowercase provider exposed a credential.'
        $result = Switch-CodexProfile -Mode 'deepseek' -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        $text = [System.IO.File]::ReadAllText($fixture.ConfigPath)
        $root = Get-RootSettings -Text $text
        Assert-Equal '"deepseek"' $root['model_provider'] 'The root provider does not match the existing lowercase TOML table.'
        Assert-Equal 1 ([regex]::Matches($text, '(?m)^\[model_providers\.deepseek\]\s*$').Count) 'The lowercase provider was duplicated or lost.'
        Assert-Equal 0 ([regex]::Matches($text, '(?m)^\[model_providers\.DeepSeek\]\s*$').Count) 'An incompatible uppercase provider table was created.'
        Assert-Contains $text 'experimental_bearer_token = "TEST_DEEPSEEK_SECRET_907db226"' 'The lowercase provider lost its credential.'
        Assert-Equal 'deepseek' $result.Mode 'The lowercase provider was not recognized as DeepSeek mode.'
        Assert-Equal 'deepseek' (Get-SwitcherStatus -ConfigPath $fixture.ConfigPath).Provider 'The displayed provider does not match the table ID.'
    }

    Invoke-Test 'CRLF line endings survive root and provider edits' {
        $windowsText = [regex]::Replace($script:FixtureText, '\r\n|\r|\n', "`r`n")
        $rootText = Set-RootSettings -Text $windowsText -Settings ([ordered]@{ model_provider = '"ZAI"'; model = '"glm-5.3"'; model_reasoning_effort = '"max"'; model_catalog_json = '"C:/catalogs/glm.json"'; web_search = '"disabled"' })
        $providerText = Set-ProviderSettings -Text $rootText -ProviderId 'ZAI' -Settings ([ordered]@{ base_url = '"https://open.bigmodel.cn/api/v1"' })
        Assert-True (-not [regex]::IsMatch($providerText, '(?<!\r)\n')) 'An edit introduced LF-only lines into a CRLF config.'
        foreach ($block in $script:PreservedBlocks) {
            $windowsBlock = [regex]::Replace($block, '\r\n|\r|\n', "`r`n")
            Assert-Contains $providerText $windowsBlock 'An edit changed unrelated CRLF content.'
        }
    }

    Invoke-Test 'Duplicate root keys and unterminated multiline strings fail without writing' {
        foreach ($badText in @(
            $script:FixtureText.Replace('model = "gpt-6.1-sol"', "model = `"gpt-6.1-sol`"`nmodel = `"duplicate-model`""),
            ($script:FixtureText + "`nunterminated = " + ('"' * 3))
        )) {
            $fixture = New-Fixture
            [System.IO.File]::WriteAllText($fixture.ConfigPath, $badText, (New-Object System.Text.UTF8Encoding($false)))
            $before = [System.IO.File]::ReadAllBytes($fixture.ConfigPath)
            $failed = $false
            try { $null = Switch-CodexProfile -Mode 'deepseek' -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory }
            catch { $failed = $true }
            Assert-True $failed 'Malformed or ambiguous root TOML was accepted.'
            Assert-Equal ([Convert]::ToBase64String($before)) ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($fixture.ConfigPath))) 'Malformed TOML changed config.toml.'
        }
    }

    Invoke-Test 'Invalid mode fails without changing config.toml' {
        $fixture = New-Fixture
        $before = [System.IO.File]::ReadAllBytes($fixture.ConfigPath)
        $failed = $false
        try { $null = Switch-CodexProfile -Mode 'invalid-mode' -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory }
        catch { $failed = $true }
        Assert-True $failed 'An invalid mode was accepted.'
        Assert-Equal ([Convert]::ToBase64String($before)) ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($fixture.ConfigPath))) 'An invalid mode changed config.toml.'
    }

    Invoke-Test 'Missing model catalog fails without changing config.toml' {
        $fixture = New-Fixture
        $null = Initialize-Switcher -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        Remove-Item -LiteralPath (Join-Path $fixture.CatalogDirectory 'glm.json')
        $before = [System.IO.File]::ReadAllBytes($fixture.ConfigPath)
        $failed = $false
        try { $null = Switch-CodexProfile -Mode 'glm' -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory }
        catch { $failed = $true }
        Assert-True $failed 'A missing model catalog was accepted.'
        Assert-Equal ([Convert]::ToBase64String($before)) ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($fixture.ConfigPath))) 'A failed catalog check changed config.toml.'
    }

    Invoke-Test 'Invalid model catalog JSON fails without changing config.toml' {
        $fixture = New-Fixture
        $null = Initialize-Switcher -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        [System.IO.File]::WriteAllText((Join-Path $fixture.CatalogDirectory 'glm.json'), '{ invalid json')
        $before = [System.IO.File]::ReadAllBytes($fixture.ConfigPath)
        $failed = $false
        try { $null = Switch-CodexProfile -Mode 'glm' -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory }
        catch { $failed = $true }
        Assert-True $failed 'An invalid model catalog was accepted.'
        Assert-Equal ([Convert]::ToBase64String($before)) ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($fixture.ConfigPath))) 'An invalid catalog changed config.toml.'
    }

    Invoke-Test 'Missing config path fails without creating a new user config' {
        $fixture = New-Fixture
        $missingPath = Join-Path $fixture.Directory 'missing-config.toml'
        $failed = $false
        try { $null = Switch-CodexProfile -Mode 'glm' -ConfigPath $missingPath -AppDirectory $fixture.AppDirectory }
        catch { $failed = $true }
        Assert-True $failed 'A nonexistent config was silently accepted.'
        Assert-True (-not (Test-Path -LiteralPath $missingPath)) 'A nonexistent config was created by a failed switch.'
    }

    Invoke-Test 'DeepSeek uses official settings while preserving native authentication' {
        $fixture = New-Fixture
        $null = Switch-CodexProfile -Mode deepseek -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        $text = [IO.File]::ReadAllText($fixture.ConfigPath)
        $root = Get-RootSettings $text
        Assert-Equal '"apikey"' $root['preferred_auth_method'] 'The official preferred authentication setting is missing.'
        Assert-True (-not $root.Contains('forced_login_method')) 'DeepSeek must not force an API login and log out ChatGPT.'
        Assert-Equal 'true' $root['show_raw_agent_reasoning'] 'The official reasoning display setting is missing.'
        $provider = Get-ProviderSettings $text 'DeepSeek'
        Assert-Equal '"https://api.deepseek.com/"' $provider['base_url'] 'DeepSeek must use the exact official endpoint.'
        Assert-Equal '"responses"' $provider['wire_api'] 'DeepSeek must use Responses.'
        Assert-True (-not $provider.Contains('requires_openai_auth')) 'A custom provider retained OpenAI authentication.'
        Assert-Equal '["low", "medium", "high", "xhigh", "ultra", "max"]' (Get-DesktopSettings $text)['enabled-reasoning-efforts'] 'The official desktop effort levels are missing.'
        $null = Switch-CodexProfile -Mode native -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        $after = [IO.File]::ReadAllText($fixture.ConfigPath)
        $root = Get-RootSettings $after
        foreach ($key in @('preferred_auth_method', 'forced_login_method', 'show_raw_agent_reasoning', 'model_catalog_json')) {
            Assert-True (-not $root.Contains($key)) ('A third-party setting leaked into native mode: ' + $key)
        }
        Assert-Equal 0 (@(Get-TomlLineMap $after | Where-Object { $_.IsHeader -and $_.Section -ceq 'desktop' }).Count) 'A newly introduced empty desktop table was not removed.'
    }

    Invoke-Test 'Native model overrides, login preferences, prompts, and multiline desktop arrays round-trip' {
        $fixture = New-Fixture
        $extra = @'
preferred_auth_method = "chatgpt"
forced_login_method = "chatgpt"
show_raw_agent_reasoning = false
model_context_window = 1200000
model_auto_compact_token_limit = 1000000
model_verbosity = "high"
model_reasoning_summary = "auto"
plan_mode_reasoning_effort = "xhigh"
openai_base_url = "https://api.openai.com/v1"
base_instructions = '''
model = "prompt text must not become a setting"
[desktop]
enabled-reasoning-efforts = ["fake"]
'''

'@
        $desktop = @'

[desktop]
appearanceTheme = "dark"
enabled-reasoning-efforts = [
  "low",
  "xhigh", # Keep the native comment.
]
[profiles.work]
model = "gpt-6.1-sol"
'@
        $original = $extra + $fixture.Original + $desktop
        [IO.File]::WriteAllText($fixture.ConfigPath, $original)
        $native = Get-RootSettings $original
        $nativeDesktop = Get-DesktopSettings $original
        $null = Switch-CodexProfile -Mode deepseek -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        $ds = [IO.File]::ReadAllText($fixture.ConfigPath)
        foreach ($key in @('profile','openai_base_url','model_context_window','model_auto_compact_token_limit','base_instructions','model_verbosity','model_reasoning_summary','plan_mode_reasoning_effort','forced_login_method')) {
            Assert-True (-not (Get-RootSettings $ds).Contains($key)) ('A conflicting native override remained in DeepSeek: ' + $key)
        }
        Assert-Contains $ds '[profiles.work]' 'An inactive profile definition was deleted.'
        $null = Switch-CodexProfile -Mode glm -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        $glm = [IO.File]::ReadAllText($fixture.ConfigPath)
        Assert-True (-not (Get-RootSettings $glm).Contains('preferred_auth_method')) 'DeepSeek authentication preferences leaked into GLM.'
        Assert-Equal $nativeDesktop['enabled-reasoning-efforts'] (Get-DesktopSettings $glm)['enabled-reasoning-efforts'] 'GLM retained DeepSeek desktop effort overrides.'
        $null = Switch-CodexProfile -Mode native -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        $restored = [IO.File]::ReadAllText($fixture.ConfigPath)
        $restoredRoot = Get-RootSettings $restored
        foreach ($key in $native.Keys) { Assert-Equal $native[$key] $restoredRoot[$key] ('Native override was not restored: ' + $key) }
        Assert-Equal $nativeDesktop['enabled-reasoning-efforts'] (Get-DesktopSettings $restored)['enabled-reasoning-efforts'] 'The native multiline desktop array changed.'
        Assert-Contains $restored 'appearanceTheme = "dark"' 'An unrelated desktop preference changed.'
    }

    Invoke-Test 'MCP, notification, and plugin changes made while away from native remain intact' {
        $fixture = New-Fixture
        $null = Switch-CodexProfile -Mode deepseek -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        $text = [IO.File]::ReadAllText($fixture.ConfigPath)
        $addition = @'

[mcp_servers.new_server]
command = "new-command"
[plugins."new-plugin@official"]
enabled = true
js_repl = false
memories = true
'@
        $text = $text.Replace('example_flag = true', "example_flag = true`njs_repl = false`nmemories = true")
        $addition = $addition.Replace("js_repl = false`nmemories = true", '').Replace("js_repl = false`r`nmemories = true", '')
        $text = 'notify = ["new-notification-command"]' + "`n" + $text + $addition
        $text = $text.Replace('enabled = true', 'enabled = false')
        [IO.File]::WriteAllText($fixture.ConfigPath, $text)
        $null = Switch-CodexProfile -Mode native -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        $after = [IO.File]::ReadAllText($fixture.ConfigPath)
        Assert-Contains $after 'command = "new-command"' 'A newly added MCP server was lost.'
        Assert-Contains $after 'notify = ["new-notification-command"]' 'A new notification configuration was lost.'
        Assert-Contains $after 'enabled = false' 'A user plugin preference was reverted.'
        Assert-Contains $after 'js_repl = false' 'The retired js_repl flag was forced on.'
        Assert-Contains $after 'memories = true' 'A shared feature flag was changed.'
    }

    Invoke-Test 'Actual Codex parser rejects duplicate tables and multiline arrays without changing config' {
        foreach ($broken in @("`n[desktop]`n[desktop]`n", "`n[desktop]`nenabled-reasoning-efforts = [`n", "`n[windows]`nsandbox = `"invalid-value`"`n")) {
            $fixture = New-Fixture
            [IO.File]::WriteAllText($fixture.ConfigPath, $fixture.Original + $broken)
            $before = [IO.File]::ReadAllBytes($fixture.ConfigPath)
            $failed = $false
            try { $null = Switch-CodexProfile -Mode deepseek -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory } catch { $failed = $true }
            Assert-True $failed 'Invalid TOML or configuration semantics were accepted.'
            Assert-Equal ([Convert]::ToBase64String($before)) ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.ConfigPath))) 'Rejected configuration was modified.'
        }
    }

    Invoke-Test 'State write failure leaves the active config untouched' {
        $fixture = New-Fixture
        $null = Initialize-Switcher -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        $statePath = Join-Path $fixture.AppDirectory 'state.json'
        [IO.File]::SetAttributes($statePath, [IO.FileAttributes]::ReadOnly)
        try {
            $before = [IO.File]::ReadAllBytes($fixture.ConfigPath)
            $failed = $false
            try { $null = Switch-CodexProfile -Mode deepseek -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory } catch { $failed = $true }
            Assert-True $failed 'A protected state file did not abort the switch.'
            Assert-Equal ([Convert]::ToBase64String($before)) ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.ConfigPath))) 'A failed state checkpoint changed active config.'
        } finally { [IO.File]::SetAttributes($statePath, [IO.FileAttributes]::Normal) }
    }

    Invoke-Test 'A switcher cannot restore another CODEX_HOME native settings' {
        $fixture = New-Fixture
        $null = Initialize-Switcher -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        $otherPath = Join-Path $fixture.Directory 'different-config.toml'
        [IO.File]::WriteAllText($otherPath, $fixture.Original)
        $failed = $false
        try { $null = Switch-CodexProfile -Mode deepseek -ConfigPath $otherPath -AppDirectory $fixture.AppDirectory } catch { $failed = $true }
        Assert-True $failed 'A state checkpoint was applied to an unrelated Codex home.'
        Assert-Equal $fixture.Original ([IO.File]::ReadAllText($otherPath)) 'An unrelated Codex home was modified.'
    }

    Invoke-Test 'Concurrent config edits are preserved by the final compare' {
        $fixture = New-Fixture
        $expected = $fixture.Original
        $newer = $expected + "`n# another writer`n"
        [IO.File]::WriteAllText($fixture.ConfigPath, $newer)
        $failed = $false
        try { $null = Write-CodexConfigSafely -ConfigPath $fixture.ConfigPath -ExpectedText $expected -NewText 'model = "replacement"' } catch { $failed = $true }
        Assert-True $failed 'A concurrent change was overwritten.'
        Assert-Equal $newer ([IO.File]::ReadAllText($fixture.ConfigPath)) 'The concurrent edit was not preserved.'
    }

    Invoke-Test 'New native preferences are captured and repeated switching does not accumulate whitespace' {
        $fixture = New-Fixture
        $null = Switch-CodexProfile -Mode glm -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        $null = Switch-CodexProfile -Mode deepseek -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        $null = Switch-CodexProfile -Mode native -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        $text = [IO.File]::ReadAllText($fixture.ConfigPath).Replace('model_reasoning_effort = "max"', 'model_reasoning_effort = "low"')
        [IO.File]::WriteAllText($fixture.ConfigPath, $text)
        foreach ($mode in @('deepseek','glm','native','deepseek','glm','native')) {
            $null = Switch-CodexProfile -Mode $mode -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        }
        $after = [IO.File]::ReadAllText($fixture.ConfigPath)
        Assert-Equal '"low"' (Get-RootSettings $after)['model_reasoning_effort'] 'A newly selected native effort was forgotten.'
        Assert-Equal $text $after 'Repeated switching changed native config formatting or accumulated whitespace.'
    }

    Invoke-Test 'Version one state migrates without leaking secrets or losing the native snapshot' {
        $fixture = New-Fixture
        $old = [pscustomobject]@{ Version = 1; Native = Get-RootSettings $fixture.Original; Glm = @{ Model='glm-5.3'; Effort='max' }; Deepseek = @{ Model='deepseek-v4-pro'; Effort='high' } }
        [IO.File]::WriteAllText((Join-Path $fixture.AppDirectory 'state.json'), ($old | ConvertTo-Json -Depth 8))
        $null = Switch-CodexProfile -Mode deepseek -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        $state = Get-Content -Raw -LiteralPath (Join-Path $fixture.AppDirectory 'state.json') | ConvertFrom-Json
        Assert-Equal 2 $state.Version 'The legacy state did not migrate.'
        Assert-Equal 'deepseek-v4-pro' $state.Deepseek.Model 'A saved user model choice was lost.'
        Assert-NoSecret $state 'The migrated state contains a credential.'
        $null = Switch-CodexProfile -Mode native -ConfigPath $fixture.ConfigPath -AppDirectory $fixture.AppDirectory
        Assert-Equal '"gpt-6.1-sol"' (Get-RootSettings ([IO.File]::ReadAllText($fixture.ConfigPath)))['model'] 'The original native model was not restored after migration.'
    }

    Invoke-Test 'Complete official DeepSeek catalog retains prompts, tools, and image capability' {
        $catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot 'catalogs\deepseek.json') | ConvertFrom-Json
        $flash = @($catalog.models | Where-Object slug -eq 'deepseek-flash')[0]
        Assert-True ($flash.base_instructions.Length -gt 10000) 'The official full prompt was replaced by a short handwritten prompt.'
        Assert-True ($flash.model_messages.instructions_template.Length -gt 10000) 'The official instruction template is missing.'
        Assert-True ($flash.input_modalities -contains 'image') 'Official Flash image support is missing.'
        Assert-Equal 'v2' $flash.multi_agent_version 'The official multi-agent metadata is missing.'
        Assert-Equal 'freeform' $flash.apply_patch_tool_type 'The official patch-tool type changed.'
        Assert-True ([bool]$flash.supports_image_detail_original) 'The official original-resolution image capability is missing.'
    }

    Invoke-Test 'Desktop launcher finds bundled Codex even when it is not on PATH' {
        $oldPath = $env:PATH
        try {
            $env:PATH = Join-Path $env:WINDIR 'System32'
            Assert-True ([IO.File]::Exists((Get-CodexExecutable))) 'The desktop launcher cannot locate the installed Codex executable.'
            Test-CodexConfiguration -Text $script:FixtureText
        } finally { $env:PATH = $oldPath }
    }

    Write-Host ('Results: ' + $script:Passed + ' passed, ' + $script:Failures.Count + ' failed.')
    if ($script:Failures.Count -gt 0) { exit 1 }
    exit 0
}
finally {
    if ($KeepFixtures) { Write-Host ('FIXTURES=' + $script:TempRoot) }
    elseif (Test-Path -LiteralPath $script:TempRoot) {
        $resolvedTempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        $resolvedTarget = [System.IO.Path]::GetFullPath($script:TempRoot)
        if ($resolvedTarget.StartsWith($resolvedTempBase, [System.StringComparison]::OrdinalIgnoreCase) -and
            ([System.IO.Path]::GetFileName($resolvedTarget)).StartsWith('codex-switcher-tests-')) {
            Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
        }
    }
}
