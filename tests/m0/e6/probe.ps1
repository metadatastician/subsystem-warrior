# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# probe.ps1 — E6, Windows CI feasibility (docs/plan/m0/E6-windows-ci.adoc).
#
# Records one verdict per required step, `yes` or `no`, each with evidence,
# into a results file. It never decides on its own that E6 passed: the judge
# (tests/m0/e6/judge.sh) does, from the results file.
#
# The harness proves its own inputs first. If any input check fails, every
# step is `not-run: harness incomplete` and the script exits 1. A broken input
# is never reported as "the runner lacks the capability".
#
# wsl.exe may print in UTF-16 and may exit 0 after an error, so every step
# reads its output as well as its exit code.
#
# Usage: probe.ps1 -InputsDir DIR -OutFile FILE [-Mutation NAME]
# Mutations (card E6, "Mutations"): none, bad-path, corrupt-fixture,
# drop-verdict, not-run.
param(
  [Parameter(Mandatory = $true)][string]$InputsDir,
  [Parameter(Mandatory = $true)][string]$OutFile,
  [ValidateSet('none', 'bad-path', 'corrupt-fixture', 'drop-verdict', 'not-run')]
  [string]$Mutation = 'none'
)

$ErrorActionPreference = 'Continue'
$env:WSL_UTF8 = '1'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$Distro2 = 'sw-e6-probe-v2'
$Distro1 = 'sw-e6-probe-v1'
$MaxEvidence = 4000

# Required steps, in order. tests/m0/e6/judge.sh holds the same list, and
# tests/m0/e6/judge_test.sh checks that the two agree.
$RequiredSteps = @(
  'virtualisation', 'wsl-present', 'wsl-install', 'import-v2', 'run-v2',
  'bare-mount', 'e2fsck', 'import-v1', 'zig-exe'
)

$R = [ordered]@{
  experiment = 'E6'
  runner     = [ordered]@{
    image_os      = "$env:ImageOS"
    image_version = "$env:ImageVersion"
    runner_os     = "$env:RUNNER_OS"
  }
  mutation   = $Mutation
  harness    = [ordered]@{ status = 'ok'; checks = @() }
  steps      = [ordered]@{}
}

function Limit([string]$s) {
  if ($null -eq $s) { return '' }
  $s = $s -replace "`0", ''
  if ($s.Length -gt $MaxEvidence) { return $s.Substring(0, $MaxEvidence) + ' [truncated]' }
  return $s.Trim()
}

function Invoke-Native([string]$Exe, [string[]]$ArgList) {
  # "$_" turns a stderr ErrorRecord into its plain text, so evidence and
  # output checks read the program's own words, not PowerShell's formatting.
  $out = & $Exe @ArgList 2>&1 | ForEach-Object { "$_" } | Out-String
  return [ordered]@{ command = (@($Exe) + $ArgList) -join ' '; rc = $LASTEXITCODE; output = (Limit $out) }
}

function Set-Verdict([string]$Id, [string]$Verdict, $Evidence) {
  if ($Mutation -eq 'drop-verdict' -and $Id -eq 'zig-exe') { return }
  if ($Mutation -eq 'not-run' -and $Id -eq 'virtualisation') {
    $Verdict = 'not-run: mutation'
  }
  $R.steps[$Id] = [ordered]@{ verdict = $Verdict; evidence = $Evidence }
}

function Add-Check([string]$Name, [bool]$Ok, [string]$Detail) {
  $R.harness.checks += [ordered]@{ check = $Name; ok = $Ok; detail = $Detail }
  if (-not $Ok) { $R.harness.status = 'incomplete' }
}

function Save-Results {
  $json = $R | ConvertTo-Json -Depth 20 -Compress
  [IO.File]::WriteAllText($OutFile, $json, [Text.UTF8Encoding]::new($false))
}

function Get-Sha256([string]$Path) {
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

# ---------------------------------------------------------------- preflight
$fixture = $null; $rootfs = $null; $zig = $null
try {
  $fixture = Get-Content -Raw -LiteralPath (Join-Path $InputsDir 'fixture.json') | ConvertFrom-Json
  $rootfs = Get-Content -Raw -LiteralPath (Join-Path $InputsDir 'rootfs.json') | ConvertFrom-Json
  $zig = Get-Content -Raw -LiteralPath (Join-Path $InputsDir 'zig.json') | ConvertFrom-Json
  Add-Check 'input manifests parse' $true 'fixture.json, rootfs.json, zig.json'
} catch {
  Add-Check 'input manifests parse' $false (Limit "$_")
}

$vhdx = $null
if ($fixture) {
  $vhdx = Join-Path $InputsDir $fixture.file
  if ($Mutation -eq 'bad-path') { $vhdx = Join-Path $InputsDir 'does-not-exist.vhdx' }
  if ($Mutation -eq 'corrupt-fixture' -and (Test-Path -LiteralPath $vhdx)) {
    $copy = Join-Path $env:RUNNER_TEMP 'corrupt.vhdx'
    Copy-Item -LiteralPath $vhdx -Destination $copy -Force
    $bytes = [IO.File]::ReadAllBytes($copy)
    $bytes[1048576] = $bytes[1048576] -bxor 0xFF
    [IO.File]::WriteAllBytes($copy, $bytes)
    $vhdx = $copy
  }
  if (Test-Path -LiteralPath $vhdx) {
    $sha = Get-Sha256 $vhdx
    Add-Check 'fixture sha256 matches the producing job' ($sha -eq $fixture.sha256) "expected $($fixture.sha256), got $sha (source: one-off image from the Linux job, E1-L not landed)"
  } else {
    Add-Check 'fixture file exists' $false "missing: $vhdx"
  }
  $xc = $fixture.x_clean
  $proven = ($xc.qemu_img_check.rc -eq 0) -and ($xc.qemu_img_check.clean -eq $true) -and ($xc.e2fsck_fn_on_extracted_raw.rc -eq 0) -and $fixture.virtual_size -and $fixture.fs_uuid
  Add-Check 'fixture proven X-CLEAN by the producing job' $proven "qemu-img check rc $($xc.qemu_img_check.rc), e2fsck -fn on extracted raw rc $($xc.e2fsck_fn_on_extracted_raw.rc), size $($fixture.virtual_size), uuid $($fixture.fs_uuid)"
}

$rootfsTar = $null
if ($rootfs) {
  $rootfsTar = Join-Path $InputsDir $rootfs.file
  if (Test-Path -LiteralPath $rootfsTar) {
    $sha = Get-Sha256 $rootfsTar
    $ok = ($sha -eq $rootfs.sha256) -and ($rootfs.source_sha256_matched -eq $true)
    Add-Check 'rootfs tarball matches its pin' $ok "pin $($rootfs.source_sha256_pin) matched upstream: $($rootfs.source_sha256_matched); tar expected $($rootfs.sha256), got $sha"
  } else {
    Add-Check 'rootfs tarball exists' $false "missing: $rootfsTar"
  }
}

$exe = $null
if ($zig) {
  $exe = Join-Path $InputsDir $zig.file
  if (Test-Path -LiteralPath $exe) {
    $sha = Get-Sha256 $exe
    Add-Check 'cross-compiled executable matches the Linux build' ($sha -eq $zig.sha256) "expected $($zig.sha256), got $sha (zig $($zig.zig_version))"
  } else {
    Add-Check 'cross-compiled executable exists' $false "missing: $exe"
  }
}

# Static command templates: every {placeholder} must be declared. Commands
# whose arguments come from a probe result (e2fsck's device) are rendered only
# just before they run.
$Templates = [ordered]@{
  'import'  = @{ text = 'wsl --import {name} {dir} {tar} --version {ver}'; vars = @('name', 'dir', 'tar', 'ver') }
  'mount'   = @{ text = 'wsl --mount {vhdx} --vhd --bare'; vars = @('vhdx') }
  'lsblk'   = @{ text = 'wsl -d {name} -u root -- lsblk --json --bytes -o NAME,PATH,TYPE,SIZE,UUID'; vars = @('name') }
  'blkid'   = @{ text = 'wsl -d {name} -u root -- blkid -p -o value -s UUID {device}'; vars = @('name', 'device') }
  'e2fsck'  = @{ text = 'wsl -d {name} -u root -- e2fsck -fn {device}'; vars = @('name', 'device') }
  'unmount' = @{ text = 'wsl --unmount {vhdx}'; vars = @('vhdx') }
}
$tplOk = $true; $tplDetail = @()
foreach ($k in $Templates.Keys) {
  $used = [regex]::Matches($Templates[$k].text, '\{([a-z]+)\}') | ForEach-Object { $_.Groups[1].Value }
  foreach ($u in $used) {
    if ($Templates[$k].vars -notcontains $u) { $tplOk = $false; $tplDetail += "$k uses undeclared {$u}" }
  }
}
Add-Check 'static command templates parse with declared placeholders' $tplOk ((@("$($Templates.Count) templates") + $tplDetail) -join '; ')

if ($R.harness.status -ne 'ok') {
  foreach ($s in $RequiredSteps) { Set-Verdict $s 'not-run: harness incomplete' ([ordered]@{ reason = 'an input check failed; see harness.checks' }) }
  Save-Results
  Write-Host 'E6 probe: incomplete: harness'
  exit 1
}

# --------------------------------------------------------------- the probes
# 1. Virtualisation as Windows reports it.
$cs = Get-CimInstance Win32_ComputerSystem
$ci = Get-ComputerInfo -Property 'HyperVisorPresent', 'HyperVRequirement*', 'OsName', 'OsVersion', 'OsBuildNumber' -ErrorAction SilentlyContinue
$ev = [ordered]@{
  hypervisor_present = "$($cs.HypervisorPresent)"
  computer_info      = (Limit ($ci | Out-String))
}
Set-Verdict 'virtualisation' ($(if ($cs.HypervisorPresent) { 'yes' } else { 'no' })) $ev

# 2. Is WSL present, and which kind? The inbox wsl.exe (as on windows-2022,
# first run 2026-11-17) has no --version and no --install --no-distribution,
# but runs WSL1 distros. So --version alone cannot decide presence: an inbox
# wsl.exe that answers --status or prints its usage is present.
$wslCmd = Get-Command 'wsl.exe' -ErrorAction SilentlyContinue
$ver = Invoke-Native 'wsl.exe' @('--version')
$status = Invoke-Native 'wsl.exe' @('--status')
$storeWsl = ($ver.rc -eq 0) -and ($ver.output -match 'WSL version')
$inboxWsl = (-not $storeWsl) -and $wslCmd -and (($status.rc -eq 0) -or ($ver.output -match 'Usage: wsl\.exe'))
$present = $storeWsl -or $inboxWsl
$kind = if ($storeWsl) { 'store' } elseif ($inboxWsl) { 'inbox' } else { 'absent' }
Set-Verdict 'wsl-present' ($(if ($present) { 'yes' } else { 'no' })) ([ordered]@{ kind = $kind; wsl_exe = "$($wslCmd.Source)"; version = $ver; status = $status })

# 3. Get a current WSL without a reboot. A required reboot is a `no` for
# hosted CI. Absent: `wsl --install --no-distribution` (card E6). Inbox:
# that option does not exist there, so use what its own usage text offers,
# `wsl --update --web-download`, which installs the current WSL from the web
# instead of the Store. Either way, success means `wsl --version` then works.
if ($kind -eq 'store') {
  Set-Verdict 'wsl-install' 'yes' ([ordered]@{ note = 'current WSL already present; no install attempted'; version = $ver })
} else {
  $instArgs = if ($kind -eq 'inbox') { @('--update', '--web-download') } else { @('--install', '--no-distribution') }
  $inst = Invoke-Native 'wsl.exe' $instArgs
  $after = Invoke-Native 'wsl.exe' @('--version')
  $reboot = ($inst.output -match '(?i)restart|reboot') -or ($after.output -match '(?i)restart|reboot')
  $ok = ($after.rc -eq 0) -and ($after.output -match 'WSL version') -and -not $reboot
  Set-Verdict 'wsl-install' ($(if ($ok) { 'yes' } else { 'no' })) ([ordered]@{ from = $kind; install = $inst; version_after = $after; reboot_required = $reboot })
}

# 4-5. Import the pinned rootfs as WSL2 and check the kernel.
$dir2 = Join-Path $env:RUNNER_TEMP $Distro2
New-Item -ItemType Directory -Force -Path $dir2 | Out-Null
$imp2 = Invoke-Native 'wsl.exe' @('--import', $Distro2, $dir2, $rootfsTar, '--version', '2')
$list = Invoke-Native 'wsl.exe' @('--list', '--verbose')
$imported2 = ($imp2.rc -eq 0) -and ($list.output -match "$Distro2\s+\S+\s+2")
Set-Verdict 'import-v2' ($(if ($imported2) { 'yes' } else { 'no' })) ([ordered]@{ import = $imp2; list = $list })

$wsl2Works = $false
if ($imported2) {
  $uname = Invoke-Native 'wsl.exe' @('-d', $Distro2, '-u', 'root', '--', 'uname', '-a')
  $procv = Invoke-Native 'wsl.exe' @('-d', $Distro2, '-u', 'root', '--', 'cat', '/proc/version')
  $wsl2Works = ($uname.rc -eq 0) -and ($procv.output -match '(?i)microsoft') -and ($procv.output -match 'WSL2')
  Set-Verdict 'run-v2' ($(if ($wsl2Works) { 'yes' } else { 'no' })) ([ordered]@{ uname = $uname; proc_version = $procv })
} else {
  Set-Verdict 'run-v2' 'no' ([ordered]@{ cause = 'prerequisite import-v2 is no'; import = $imp2 })
}

# 6. Bare-mount the fixture and identify it by the before/after difference.
function Get-Devices {
  $r = Invoke-Native 'wsl.exe' @('-d', $Distro2, '-u', 'root', '--', 'lsblk', '--json', '--bytes', '-o', 'NAME,PATH,TYPE,SIZE,UUID')
  $devs = @()
  if ($r.rc -eq 0) {
    try {
      $j = $r.output | ConvertFrom-Json
      $stack = [Collections.Generic.Stack[object]]::new()
      foreach ($d in $j.blockdevices) { $stack.Push($d) }
      while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        $devs += [ordered]@{ path = "$($d.path)"; type = "$($d.type)"; size = "$($d.size)"; uuid = "$($d.uuid)" }
        foreach ($c in @($d.children)) { if ($c) { $stack.Push($c) } }
      }
    } catch { }
  }
  return [ordered]@{ raw = $r; devices = $devs }
}

$device = $null
$harnessFault = $null
if ($wsl2Works) {
  $before = Get-Devices
  $mount = Invoke-Native 'wsl.exe' @('--mount', $vhdx, '--vhd', '--bare')
  Start-Sleep -Seconds 3
  $after = Get-Devices
  $beforePaths = @($before.devices | ForEach-Object { $_.path })
  $new = @($after.devices | Where-Object { $beforePaths -notcontains $_.path })
  # lsblk reads UUIDs from udev's database, and the imported rootfs runs no
  # udev, so lsblk's UUID column is empty there (first run, windows-2025,
  # 2026-11-17). `blkid -p` probes the device itself. Each new device's UUID
  # is read that way, rendered per device just before it runs.
  foreach ($n in $new) {
    $cmd = $Templates['blkid'].text.Replace('{name}', $Distro2).Replace('{device}', $n.path)
    Write-Host "E6 probe: rendered: $cmd"
    $b = Invoke-Native 'wsl.exe' @('-d', $Distro2, '-u', 'root', '--', 'blkid', '-p', '-o', 'value', '-s', 'UUID', $n.path)
    $n.uuid_lsblk = $n.uuid
    $n.uuid = if ($b.rc -eq 0) { $b.output.Trim() } else { '' }
    $n.blkid = $b
  }
  $match = @($new | Where-Object { $_.size -eq "$($fixture.virtual_size)" -and $_.uuid -eq "$($fixture.fs_uuid)" })
  $ev = [ordered]@{
    mount = $mount; before = $before.devices; after = $after.devices; new_devices = $new
    expected = [ordered]@{ size = "$($fixture.virtual_size)"; uuid = "$($fixture.fs_uuid)" }
  }
  $mountFailed = ($mount.rc -ne 0) -or ($mount.output -match '(?i)error|failed|denied')
  if ($mountFailed -or $new.Count -eq 0) {
    $ev.reading = 'capability no: the mount returned an error or no new block device appeared'
    Set-Verdict 'bare-mount' 'no' $ev
  } elseif ($match.Count -eq 1) {
    $device = $match[0].path
    $ev.selected_device = $device
    Set-Verdict 'bare-mount' 'yes' $ev
  } else {
    $harnessFault = "$($match.Count) of $($new.Count) new devices match the expected size and UUID"
    $ev.reading = "incomplete: harness: $harnessFault"
    Add-Check 'device identification' $false $harnessFault
    Set-Verdict 'bare-mount' 'not-run: harness ambiguous device match' $ev
  }
} else {
  Set-Verdict 'bare-mount' 'no' ([ordered]@{ cause = 'prerequisite run-v2 is no: no WSL2 distro to see a block device' })
}

# 7. e2fsck -fn on the verified device only. Rendered just before it runs.
if ($device) {
  $cmd = $Templates['e2fsck'].text.Replace('{name}', $Distro2).Replace('{device}', $device)
  Write-Host "E6 probe: rendered: $cmd"
  $fsck = Invoke-Native 'wsl.exe' @('-d', $Distro2, '-u', 'root', '--', 'e2fsck', '-fn', $device)
  Set-Verdict 'e2fsck' ($(if ($fsck.rc -eq 0) { 'yes' } else { 'no' })) ([ordered]@{ rendered = $cmd; e2fsck = $fsck })
} elseif ($harnessFault) {
  Set-Verdict 'e2fsck' 'not-run: harness ambiguous device match' ([ordered]@{ reason = $harnessFault })
} else {
  Set-Verdict 'e2fsck' 'no' ([ordered]@{ cause = 'prerequisite bare-mount is no: no verified device, so the command was not rendered' })
}
if ($wsl2Works) { $null = Invoke-Native 'wsl.exe' @('--unmount', $vhdx) }

# 8. Fallback: the same rootfs as WSL1, to bound what is available.
$dir1 = Join-Path $env:RUNNER_TEMP $Distro1
New-Item -ItemType Directory -Force -Path $dir1 | Out-Null
$imp1 = Invoke-Native 'wsl.exe' @('--import', $Distro1, $dir1, $rootfsTar, '--version', '1')
$run1 = $null
$wsl1Works = $false
if ($imp1.rc -eq 0) {
  $run1 = Invoke-Native 'wsl.exe' @('-d', $Distro1, '-u', 'root', '--', 'uname', '-a')
  $wsl1Works = ($run1.rc -eq 0) -and ($run1.output -match '(?i)linux')
}
Set-Verdict 'import-v1' ($(if ($wsl1Works) { 'yes' } else { 'no' })) ([ordered]@{ import = $imp1; uname = $run1 })

# 9. The cross-compiled executable.
$run = Invoke-Native $exe @()
$ok = ($run.rc -eq 0) -and ($run.output.Trim() -eq "$($zig.expected_output)")
Set-Verdict 'zig-exe' ($(if ($ok) { 'yes' } else { 'no' })) ([ordered]@{ run = $run; expected_output = $zig.expected_output })

foreach ($d in @($Distro2, $Distro1)) { $null = Invoke-Native 'wsl.exe' @('--unregister', $d) }
Save-Results
Write-Host "E6 probe: results written to $OutFile"
exit 0
