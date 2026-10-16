<# : batch launcher
@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText('%~f0', [Text.Encoding]::UTF8))"
echo.
pause
exit /b
#>

# WordCraft / GridCraft / DeckCraft: install from official GitHub releases and
# register each CLI's MCP server with Claude Code and Codex.
# Steps: 1) architecture + existing installs  2) download + install (one UAC prompt)
#        3) locate CLIs  4) register MCP (existing entries preserved, backups made)
#        5) verify MCP handshake + create test docx/xlsx/pptx

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$WorkDir = Join-Path $env:TEMP "craft-setup-$Stamp"
$TestDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Craft-MCP-Test'
$LogFile = Join-Path ([Environment]::GetFolderPath('Desktop')) "craft-setup-log-$Stamp.txt"
New-Item -ItemType Directory -Force -Path $WorkDir, $TestDir | Out-Null

$Results = [ordered]@{}
function Log([string]$msg, [string]$color = 'Gray') {
    Write-Host $msg -ForegroundColor $color
    Add-Content -LiteralPath $LogFile -Value $msg -Encoding UTF8
}
function Section([string]$t) { Log ''; Log "==== $t ====" 'Cyan' }
function Result([string]$key, [bool]$ok, [string]$detail = '') {
    $Results[$key] = @{ ok = $ok; detail = $detail }
    if ($ok) { Log "  [OK]   $key $detail" 'Green' } else { Log "  [FAIL] $key $detail" 'Red' }
}

# Quote one argument for CreateProcess (Windows PowerShell 5.1 mangles embedded quotes otherwise).
function Quote-Arg([string]$s) {
    if ($s -notmatch '[\s"]' -and $s -ne '') { return $s }
    $s = $s -replace '(\\*)"', '$1$1\"'
    $s = $s -replace '(\\+)$', '$1$1'
    return '"' + $s + '"'
}
# Run a native exe, capture UTF-8 stdout+stderr, return @{code; out}.
function Invoke-Exe([string]$exe, [string[]]$argv, [int]$timeoutMs = 120000) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ($argv | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($timeoutMs)) { try { $p.Kill() } catch {}; return @{ code = -1; out = 'timeout' } }
    return @{ code = $p.ExitCode; out = ($o.Result + $e.Result).Trim() }
}
# `claude` / `codex` are often .cmd/.ps1 shims: run them through PowerShell's call operator.
function Invoke-Tool([string]$tool, [string[]]$argv) {
    $ErrorActionPreference = 'Continue'   # native stderr must not become a terminating error
    $out = & $tool @argv 2>&1 | ForEach-Object { "$_" } | Out-String
    return @{ code = $LASTEXITCODE; out = $out.Trim() }
}

$Apps = @(
    @{ id = 'wordcraft'; name = 'WordCraft' },
    @{ id = 'gridcraft'; name = 'GridCraft' },
    @{ id = 'deckcraft'; name = 'DeckCraft' }
)

Log "로그 파일: $LogFile" 'Yellow'

# ---------------------------------------------------------------- 1. architecture + existing installs
Section '1. PC 아키텍처와 기존 설치 확인'
$cpuArch = (Get-CimInstance Win32_Processor | Select-Object -First 1).Architecture   # 9=x64, 12=ARM64, 0=x86
$osArch  = (Get-CimInstance Win32_OperatingSystem).OSArchitecture
$Arch = switch ($cpuArch) { 12 { 'arm64' } 9 { 'x64' } 0 { 'x86' } default { $null } }
if (-not [Environment]::Is64BitOperatingSystem) { $Arch = 'x86' }
if (-not $Arch) { Log "알 수 없는 CPU 아키텍처 코드: $cpuArch" 'Red'; return }
Log "  CPU 코드=$cpuArch, OS=$osArch, Windows $([Environment]::OSVersion.Version) -> 설치 빌드: windows-$Arch"

$UninstallKeys = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
function Get-Installed([string]$name) {
    Get-ItemProperty $UninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq $name -or $_.DisplayName -like "$name *" } | Select-Object -First 1
}
function Find-Cli([string]$id, [string]$name) {
    $c = @("$env:ProgramFiles\$name\$id-cli.exe")
    if (${env:ProgramFiles(x86)}) { $c += "${env:ProgramFiles(x86)}\$name\$id-cli.exe" }
    if ($env:ProgramW6432) { $c += "$env:ProgramW6432\$name\$id-cli.exe" }
    $appPath = (Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\$id.exe" -ErrorAction SilentlyContinue).'(default)'
    if ($appPath) { $c += (Join-Path (Split-Path $appPath) "$id-cli.exe") }
    $cmd = Get-Command "$id-cli" -ErrorAction SilentlyContinue
    if ($cmd) { $c += $cmd.Source }
    foreach ($p in $c) { if ($p -and (Test-Path -LiteralPath $p)) { return (Resolve-Path -LiteralPath $p).Path } }
    return $null
}
foreach ($a in $Apps) {
    $inst = Get-Installed $a.name
    $a.installedVersion = if ($inst) { $inst.DisplayVersion } else { $null }
    $cli = Find-Cli $a.id $a.name
    Log ("  {0}: 설치={1}, CLI={2}" -f $a.name, ($(if ($inst) { "$($inst.DisplayName) $($inst.DisplayVersion)" } else { '없음' })), ($(if ($cli) { $cli } else { '없음' })))
}

# ---------------------------------------------------------------- 2. download + install
Section '2. 공식 최신 Release 다운로드 및 설치'
$headers = @{ 'User-Agent' = 'craft-setup'; 'Accept' = 'application/vnd.github+json' }
$toInstall = @()
foreach ($a in $Apps) {
    try {
        $rel = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/storytold/$($a.id)/releases/latest"
    } catch { Result "$($a.name) 릴리스 조회" $false $_.Exception.Message; continue }
    $a.tag = $rel.tag_name
    $ver = $rel.tag_name.TrimStart('v')
    $msi = $rel.assets | Where-Object { $_.name -like "$($a.id)-*-windows-$Arch.msi" } | Select-Object -First 1
    $sums = $rel.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1
    if (-not $msi) { Result "$($a.name) 설치 파일" $false "windows-$Arch.msi 가 릴리스 $($rel.tag_name)에 없음"; continue }
    Log "  $($a.name) 최신 릴리스 $($rel.tag_name): $($msi.name)"
    if ($a.installedVersion -and ($a.installedVersion -eq $ver) -and (Find-Cli $a.id $a.name)) {
        Log "  $($a.name) $ver 이미 설치됨 -> 설치 건너뜀" 'Green'; continue
    }
    $dest = Join-Path $WorkDir $msi.name
    Invoke-WebRequest -UseBasicParsing -Headers @{ 'User-Agent' = 'craft-setup' } -Uri $msi.browser_download_url -OutFile $dest
    # Integrity: SHA256SUMS.txt from the same release, then Authenticode signature.
    if ($sums) {
        $sumText = (Invoke-WebRequest -UseBasicParsing -Headers @{ 'User-Agent' = 'craft-setup' } -Uri $sums.browser_download_url).Content
        if ($sumText -is [byte[]]) { $sumText = [Text.Encoding]::UTF8.GetString($sumText) }
        $line = ($sumText -split "`n") | Where-Object { $_ -match [regex]::Escape($msi.name) } | Select-Object -First 1
        $expected = if ($line) { ($line.Trim() -split '\s+')[0].ToLower() } else { $null }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $dest).Hash.ToLower()
        if (-not $expected -or $expected -ne $actual) { Result "$($a.name) SHA256" $false "기대=$expected 실제=$actual"; continue }
        Log "  SHA256 일치" 'Green'
    } else { Log '  SHA256SUMS.txt 없음 -> 서명만 확인' 'Yellow' }
    $sig = Get-AuthenticodeSignature -LiteralPath $dest
    Log "  코드 서명: $($sig.Status) ($($sig.SignerCertificate.Subject))"
    if ($sig.Status -ne 'Valid') { Result "$($a.name) 서명" $false "서명 상태 $($sig.Status)"; continue }
    $a.msi = $dest
    $toInstall += $a
}

if ($toInstall.Count -gt 0) {
    $elev = Join-Path $WorkDir 'elevated-install.ps1'
    $codes = Join-Path $WorkDir 'msi-exit-codes.txt'
    $lines = @('$ErrorActionPreference = "Continue"')
    foreach ($a in $toInstall) {
        $mlog = Join-Path $WorkDir "$($a.id)-msi.log"
        $a.msiLog = $mlog
        $lines += "`$p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList '/i `"$($a.msi)`" /passive /norestart /l*v `"$mlog`"'"
        $lines += "Add-Content -LiteralPath '$codes' -Value ('$($a.id)=' + `$p.ExitCode)"
    }
    Set-Content -LiteralPath $elev -Value $lines -Encoding UTF8
    Log ''
    Log '  >>> 지금 화면에 뜨는 [사용자 계정 컨트롤] 창에서 "예"를 한 번 눌러 주세요 (3개 프로그램을 한 번에 설치) <<<' 'Yellow'
    try {
        Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$elev`""
    } catch { Log "  관리자 권한 요청이 거부/취소됨: $($_.Exception.Message)" 'Red' }
    $exit = @{}
    if (Test-Path -LiteralPath $codes) { Get-Content -LiteralPath $codes | ForEach-Object { $k, $v = $_ -split '=', 2; $exit[$k] = [int]$v } }
    foreach ($a in $toInstall) {
        $c = $exit[$a.id]
        $ok = ($c -eq 0 -or $c -eq 3010)
        $why = switch ($c) { $null { '설치가 실행되지 않음 (UAC 취소?)' } 1602 { '사용자가 취소' } 1603 { '설치 중 치명적 오류 - MSI 로그 확인' } 1618 { '다른 설치가 진행 중' } 1638 { '다른 버전이 이미 설치됨' } 3010 { '성공 (재부팅 권장)' } default { "msiexec 종료 코드 $c" } }
        Result "$($a.name) 설치" $ok "$why  [MSI 로그: $($a.msiLog)]"
        if (-not $ok -and $a.msiLog -and (Test-Path -LiteralPath $a.msiLog)) {
            Get-Content -LiteralPath $a.msiLog -ErrorAction SilentlyContinue |
                Select-String -Pattern 'Return value 3|Error \d{4}' | Select-Object -First 5 | ForEach-Object { Log "    $($_.Line)" 'Red' }
        }
    }
}

# ---------------------------------------------------------------- 3. CLI paths + MCP launch
Section '3. 설치된 CLI 경로와 MCP 실행 방법 확인'
foreach ($a in $Apps) {
    $a.cli = Find-Cli $a.id $a.name
    if (-not $a.cli) { Result "$($a.name) CLI" $false '설치 폴더에서 *-cli.exe 를 찾지 못함'; continue }
    $v = Invoke-Exe $a.cli @('version') 20000
    if ($v.code -ne 0) { $v = Invoke-Exe $a.cli @('--version') 20000 }
    $h = Invoke-Exe $a.cli @('mcp', '--help') 20000
    $a.mcpArgs = @('mcp')
    Result "$($a.name) CLI" $true "$($a.cli)  ($($v.out -split "`n" | Select-Object -First 1))"
    Log "    MCP 실행: `"$($a.cli)`" mcp   (stdio, 헤드리스)"
    if ($h.out) { ($h.out -split "`n" | Select-Object -First 4) | ForEach-Object { Log "      $_" } }
}

# Raw MCP handshake over stdio: initialize -> initialized -> tools/list.
function Test-Mcp([string]$exe, [string[]]$argv) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ($argv | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $null = $p.StandardError.ReadToEndAsync()
    $read = {
        param($wantId)
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline) {
            $t = $p.StandardOutput.ReadLineAsync()
            if (-not $t.Wait(30000) -or $null -eq $t.Result) { return $null }
            try { $m = $t.Result | ConvertFrom-Json } catch { continue }
            if ($m.id -eq $wantId) { return $m }
        }
        return $null
    }
    try {
        $p.StandardInput.WriteLine('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"craft-setup","version":"1.0"}}}')
        $p.StandardInput.Flush()
        $init = & $read 1
        if (-not $init -or $init.error) { return @{ ok = $false; detail = "initialize 응답 없음/오류: $($init.error.message)" } }
        $p.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
        $p.StandardInput.WriteLine('{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
        $p.StandardInput.Flush()
        $tl = & $read 2
        if (-not $tl -or $tl.error) { return @{ ok = $false; detail = "tools/list 실패: $($tl.error.message)" } }
        $names = @($tl.result.tools | ForEach-Object { $_.name })
        return @{ ok = ($names.Count -gt 0); detail = "server=$($init.result.serverInfo.name) $($init.result.serverInfo.version), 도구 $($names.Count)개 (예: $(($names | Select-Object -First 5) -join ', '))" }
    } finally { try { $p.StandardInput.Close() } catch {}; if (-not $p.WaitForExit(3000)) { try { $p.Kill() } catch {} } }
}

# ---------------------------------------------------------------- 4. register with Claude Code + Codex
Section '4. Claude Code / Codex 에 MCP 등록 (기존 설정 보존)'
function Find-Tool([string]$name, [string[]]$extra) {
    $c = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    foreach ($p in $extra) { if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}
$Claude = Find-Tool 'claude' @("$env:USERPROFILE\.local\bin\claude.exe", "$env:APPDATA\npm\claude.cmd")
$Codex  = Find-Tool 'codex'  @("$env:APPDATA\npm\codex.cmd", "$env:USERPROFILE\.local\bin\codex.exe")
$ClaudeJson = Join-Path $env:USERPROFILE '.claude.json'
$CodexHome  = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$CodexToml  = Join-Path $CodexHome 'config.toml'
foreach ($f in @($ClaudeJson, $CodexToml)) {
    if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination "$f.bak-$Stamp"; Log "  백업: $f.bak-$Stamp" }
}
Log "  Claude Code: $(if ($Claude) { $Claude } else { '찾지 못함' })"
Log "  Codex:       $(if ($Codex) { $Codex } else { '찾지 못함 (config.toml 직접 편집으로 등록)' })"

$ready = $Apps | Where-Object { $_.cli }
# Claude Code: user scope, so every project sees the servers. Only same-named entries are replaced.
if ($Claude) {
    foreach ($a in $ready) {
        $g = Invoke-Tool $Claude @('mcp', 'get', $a.id)
        if ($g.code -eq 0) {
            if ($g.out -like "*$($a.cli)*") { Log "  Claude: $($a.id) 이미 같은 경로로 등록됨 -> 유지" 'Green'; continue }
            Log "  Claude: 기존 '$($a.id)' 항목의 경로가 달라 이 항목만 교체" 'Yellow'
            $null = Invoke-Tool $Claude @('mcp', 'remove', $a.id, '-s', 'user')
        }
        $r = Invoke-Tool $Claude (@('mcp', 'add', '--scope', 'user', $a.id, '--', $a.cli) + $a.mcpArgs)
        Result "Claude 등록 $($a.id)" ($r.code -eq 0) ($r.out -split "`n" | Select-Object -First 1)
    }
} else { foreach ($a in $ready) { Result "Claude 등록 $($a.id)" $false 'claude CLI 를 찾지 못함 (Claude Code 설치 필요)' } }

# Codex: prefer `codex mcp add`; fall back to editing config.toml, touching only our own sections.
function Set-CodexToml($a) {
    New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null
    $text = if (Test-Path -LiteralPath $CodexToml) { [IO.File]::ReadAllText($CodexToml) } else { '' }
    $pattern = '(?ms)^\[mcp_servers\.' + [regex]::Escape($a.id) + '(\.[^\]]+)?\]\s*$.*?(?=^\[|\z)'
    $text = [regex]::Replace($text, $pattern, '')
    $argsToml = ($a.mcpArgs | ForEach-Object { "'$_'" }) -join ', '
    $block = "`r`n[mcp_servers.$($a.id)]`r`ncommand = '$($a.cli)'`r`nargs = [$argsToml]`r`n"
    $text = $text.TrimEnd() + "`r`n" + $block
    [IO.File]::WriteAllText($CodexToml, $text, (New-Object Text.UTF8Encoding $false))
}
foreach ($a in $ready) {
    $done = $false
    if ($Codex) {
        $g = Invoke-Tool $Codex @('mcp', 'get', $a.id)
        if ($g.code -eq 0 -and $g.out -like "*$($a.cli)*") { Log "  Codex: $($a.id) 이미 같은 경로로 등록됨 -> 유지" 'Green'; $done = $true }
        else {
            if ($g.code -eq 0) { Log "  Codex: 기존 '$($a.id)' 항목의 경로가 달라 이 항목만 교체" 'Yellow'; $null = Invoke-Tool $Codex @('mcp', 'remove', $a.id) }
            $r = Invoke-Tool $Codex (@('mcp', 'add', $a.id, '--', $a.cli) + $a.mcpArgs)
            $done = ($r.code -eq 0)
            if (-not $done) { Log "  codex mcp add 실패 -> config.toml 직접 편집: $($r.out)" 'Yellow' }
        }
    }
    if (-not $done) { Set-CodexToml $a; $done = $true }
    $toml = if (Test-Path -LiteralPath $CodexToml) { [IO.File]::ReadAllText($CodexToml) } else { '' }
    Result "Codex 등록 $($a.id)" ($toml -match ('(?m)^\[mcp_servers\.' + [regex]::Escape($a.id) + '\]')) $CodexToml
}

# ---------------------------------------------------------------- 5. verify + test files
Section '5. 연결 검증'
foreach ($a in $ready) {
    $t = Test-Mcp $a.cli $a.mcpArgs
    Result "MCP 핸드셰이크 $($a.id)" $t.ok $t.detail
}
if ($Claude) {
    Log '  claude mcp list (서버마다 실제로 실행해 연결 상태 확인):'
    $l = Invoke-Tool $Claude @('mcp', 'list')
    $l.out -split "`n" | ForEach-Object { Log "    $_" }
    foreach ($a in $ready) {
        $line = ($l.out -split "`n") | Where-Object { $_ -match "^\s*$($a.id):" } | Select-Object -First 1
        Result "Claude 연결 $($a.id)" ($line -match 'Connected') $line
    }
}
if ($Codex) {
    $l = Invoke-Tool $Codex @('mcp', 'list')
    Log '  codex mcp list:'
    $l.out -split "`n" | ForEach-Object { Log "    $_" }
}

Section '5. 테스트 파일 생성 (문서 / 표 / 발표자료)'
$w = $Apps | Where-Object { $_.id -eq 'wordcraft' -and $_.cli }
if ($w) {
    $docx = Join-Path $TestDir 'wordcraft-test.docx'
    $r = Invoke-Exe $w.cli @('run', '--cmd', 'text.insert={"text":"WordCraft MCP 연결 테스트 문서입니다."}', '--save', $docx)
    $chk = if (Test-Path -LiteralPath $docx) { Invoke-Exe $w.cli @('text', $docx) } else { @{ out = $r.out } }
    Result '문서 wordcraft-test.docx' ((Test-Path -LiteralPath $docx) -and $chk.out -match '연결 테스트') "$docx | 내용: $($chk.out)"
}
$g = $Apps | Where-Object { $_.id -eq 'gridcraft' -and $_.cli }
if ($g) {
    $xlsx = Join-Path $TestDir 'gridcraft-test.xlsx'
    $script = Join-Path $WorkDir 'grid-steps.jsonl'
    @(
        '{"command":"cell.set","params":{"cell":"A1","input":"항목"}}',
        '{"command":"cell.set","params":{"cell":"B1","input":"금액"}}',
        '{"command":"cell.set","params":{"cell":"A2","input":"사과"}}',
        '{"command":"cell.set","params":{"cell":"B2","input":"1200"}}',
        '{"command":"cell.set","params":{"cell":"A3","input":"배"}}',
        '{"command":"cell.set","params":{"cell":"B3","input":"3400"}}',
        '{"command":"cell.set","params":{"cell":"A4","input":"합계"}}',
        '{"command":"cell.set","params":{"cell":"B4","input":"=SUM(B2:B3)"}}'
    ) | ForEach-Object -Begin { $jl = @() } -Process { $jl += $_ } -End { [IO.File]::WriteAllLines($script, [string[]]$jl, (New-Object Text.UTF8Encoding $false)) }
    $r = Invoke-Exe $g.cli @('run', '--script', $script, '--out', $xlsx, '--quiet')
    $chk = if (Test-Path -LiteralPath $xlsx) { Invoke-Exe $g.cli @('cat', $xlsx, '--range', 'A1:B4') } else { @{ out = $r.out } }
    Result '표 gridcraft-test.xlsx' ((Test-Path -LiteralPath $xlsx) -and $chk.out -match '4,?600') "$xlsx | B4=SUM 결과 4600 확인`r`n$($chk.out)"
}
$d = $Apps | Where-Object { $_.id -eq 'deckcraft' -and $_.cli }
if ($d) {
    $pptx = Join-Path $TestDir 'deckcraft-test.pptx'
    $r = Invoke-Exe $d.cli @('run', '--cmd', 'slide.new={"layout":"titleOnly","title":"DeckCraft MCP 연결 테스트"}', '--save', $pptx)
    $chk = if (Test-Path -LiteralPath $pptx) { Invoke-Exe $d.cli @('info', $pptx) } else { @{ out = $r.out } }
    Result '발표자료 deckcraft-test.pptx' ((Test-Path -LiteralPath $pptx) -and $chk.out -match '연결 테스트') "$pptx | $(($chk.out -replace '\s+', ' ').Substring(0, [Math]::Min(200, ($chk.out -replace '\s+', ' ').Length)))"
}

# ---------------------------------------------------------------- summary
Section '요약'
$fail = @($Results.Keys | Where-Object { -not $Results[$_].ok })
foreach ($k in $Results.Keys) { Log ("  {0} {1}" -f $(if ($Results[$k].ok) { '[OK]  ' } else { '[FAIL]' }), $k) $(if ($Results[$k].ok) { 'Green' } else { 'Red' }) }
if ($fail.Count -eq 0 -and $Results.Count -gt 0) {
    Log '모든 단계 성공. Claude Code / Codex 를 새로 열면 wordcraft, gridcraft, deckcraft 도구가 보입니다.' 'Green'
} else {
    Log "실패 $($fail.Count)건 - 완료되지 않았습니다. 바탕화면의 로그 파일을 Claude 에게 보여 주세요: $LogFile" 'Red'
}
Log "테스트 파일 폴더: $TestDir"
if (Test-Path -LiteralPath $TestDir) { Start-Process explorer.exe $TestDir }
