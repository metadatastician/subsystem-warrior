# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# probe_test.ps1 - the E6 probe's decisions, tested both ways, on any host
# with pwsh (CI runs it on Linux before any Windows minute is spent).
#
#   * Read-Manifest rejects missing, empty, null and incomplete manifests.
#   * ConvertFrom-Lsblk reports a failed or unparseable lsblk as ok = false,
#     never as an empty device list.
#   * Resolve-BareMount: an observed mount failure is `no`; a failed device
#     observation is a harness fault, not `no`.
#   * probe.ps1 itself, given broken inputs, stops at preflight with every
#     step `not-run`, and the judge rejects that result.
#
# Usage: pwsh -NoProfile -File tests/m0/e6/probe_test.ps1
# Exit: 0 = all checks pass; 1 = a check failed.
# As in probe.ps1: native commands' stderr must not abort the test. Every
# library read that can fail uses -ErrorAction Stop itself.
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'probe-lib.ps1')

$script:fails = 0
function Check([string]$Label, [bool]$Ok) {
  if ($Ok) { Write-Host "ok   $Label" } else { Write-Host "FAIL $Label"; $script:fails++ }
}
function Throws([scriptblock]$Block) {
  try { & $Block | Out-Null; return $false } catch { return $true }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("e6-probe-test-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  # ------------------------------------------------------------ Read-Manifest
  $m = Join-Path $tmp 'manifests'
  New-Item -ItemType Directory -Path $m | Out-Null
  Set-Content -LiteralPath (Join-Path $m 'empty.json') -Value '' -NoNewline
  Set-Content -LiteralPath (Join-Path $m 'null.json') -Value 'null' -NoNewline
  Set-Content -LiteralPath (Join-Path $m 'nosha.json') -Value '{"file":"x.vhdx"}' -NoNewline
  Set-Content -LiteralPath (Join-Path $m 'bad.json') -Value '{"file":' -NoNewline
  Set-Content -LiteralPath (Join-Path $m 'good.json') -Value '{"file":"x.vhdx","sha256":"00"}' -NoNewline
  Check 'Read-Manifest: a missing manifest throws' (Throws { Read-Manifest $m 'absent.json' })
  Check 'Read-Manifest: an empty manifest throws' (Throws { Read-Manifest $m 'empty.json' })
  Check 'Read-Manifest: a null manifest throws' (Throws { Read-Manifest $m 'null.json' })
  Check 'Read-Manifest: a manifest without sha256 throws' (Throws { Read-Manifest $m 'nosha.json' })
  Check 'Read-Manifest: invalid JSON throws' (Throws { Read-Manifest $m 'bad.json' })
  Check 'Read-Manifest: a complete manifest reads' ((Read-Manifest $m 'good.json').file -eq 'x.vhdx')

  # -------------------------------------------------------- ConvertFrom-Lsblk
  $failed = ConvertFrom-Lsblk ([ordered]@{ rc = 1; output = 'lsblk: error' })
  Check 'ConvertFrom-Lsblk: a nonzero exit is not ok' (-not $failed.ok)
  $garbage = ConvertFrom-Lsblk ([ordered]@{ rc = 0; output = 'not json' })
  Check 'ConvertFrom-Lsblk: unparseable output is not ok' (-not $garbage.ok)
  $noArray = ConvertFrom-Lsblk ([ordered]@{ rc = 0; output = '{}' })
  Check 'ConvertFrom-Lsblk: output without blockdevices is not ok' (-not $noArray.ok)
  $objNotArray = ConvertFrom-Lsblk ([ordered]@{ rc = 0; output = '{"blockdevices":{}}' })
  Check 'ConvertFrom-Lsblk: blockdevices that is an object, not an array, is not ok' (-not $objNotArray.ok)
  $noPath = ConvertFrom-Lsblk ([ordered]@{ rc = 0; output = '{"blockdevices":[{"name":"sda","type":"disk","size":1}]}' })
  Check 'ConvertFrom-Lsblk: a device without a path is not ok' (-not $noPath.ok)
  $badChildren = ConvertFrom-Lsblk ([ordered]@{ rc = 0; output = '{"blockdevices":[{"name":"sda","path":"/dev/sda","type":"disk","size":1,"children":{}}]}' })
  Check 'ConvertFrom-Lsblk: children that is an object, not an array, is not ok' (-not $badChildren.ok)
  $one = ConvertFrom-Lsblk ([ordered]@{ rc = 0; output = '{"blockdevices":[{"name":"sda","path":"/dev/sda","type":"disk","size":1}]}' })
  Check 'ConvertFrom-Lsblk: a one-device array is ok' ($one.ok -and (@($one.devices).Count -eq 1))
  $tree = '{"blockdevices":[{"name":"sda","path":"/dev/sda","type":"disk","size":100,"uuid":null,"children":[{"name":"sda1","path":"/dev/sda1","type":"part","size":90,"uuid":"u1"}]},{"name":"sde","path":"/dev/sde","type":"disk","size":67108864,"uuid":null}]}'
  $good = ConvertFrom-Lsblk ([ordered]@{ rc = 0; output = $tree })
  Check 'ConvertFrom-Lsblk: a valid tree is ok' $good.ok
  Check 'ConvertFrom-Lsblk: children are flattened (3 devices)' (@($good.devices).Count -eq 3)

  # -------------------------------------------------------- Resolve-BareMount
  # MountFailed, BeforeOk, AfterOk, NewCount, MatchCount -> verdict, fault?
  $cases = @(
    @{ n = 'observed mount failure'; a = @($true, $true, $true, 0, 0); v = 'no'; f = $false }
    @{ n = 'observed mount failure, observation also failed'; a = @($true, $true, $false, 0, 0); v = 'no'; f = $false }
    @{ n = 'lsblk failed after the mount'; a = @($false, $true, $false, 0, 0); v = 'not-run: harness device observation failed'; f = $true }
    @{ n = 'lsblk failed before the mount'; a = @($false, $false, $true, 1, 1); v = 'not-run: harness device observation failed'; f = $true }
    @{ n = 'observed: no new device'; a = @($false, $true, $true, 0, 0); v = 'no'; f = $false }
    @{ n = 'one matching device'; a = @($false, $true, $true, 1, 1); v = 'yes'; f = $false }
    @{ n = 'no new device matches'; a = @($false, $true, $true, 2, 0); v = 'not-run: harness ambiguous device match'; f = $true }
    @{ n = 'two new devices match'; a = @($false, $true, $true, 2, 2); v = 'not-run: harness ambiguous device match'; f = $true }
  )
  foreach ($c in $cases) {
    $a = $c.a
    $d = Resolve-BareMount $a[0] $a[1] $a[2] $a[3] $a[4]
    Check "Resolve-BareMount: $($c.n) -> $($d.verdict)" (($d.verdict -eq $c.v) -and ([bool]$d.fault -eq $c.f))
  }

  # ------------------------------------------- probe.ps1 preflight, end to end
  # Broken inputs must stop the probe before any wsl.exe call, with every step
  # `not-run`. These cases never reach the Windows-only probes.
  $probe = Join-Path $PSScriptRoot 'probe.ps1'
  $judge = Join-Path $PSScriptRoot 'judge.sh'
  $broken = [ordered]@{
    'no-manifests'    = @{}
    'empty-fixture'   = @{ 'fixture.json' = ''; 'rootfs.json' = '{"file":"rootfs.tar","sha256":"00"}'; 'zig.json' = '{"file":"hello.exe","sha256":"00"}' }
    'missing-files'   = @{ 'fixture.json' = '{"file":"X-CLEAN.vhdx","sha256":"00","virtual_size":"1","fs_uuid":"u","x_clean":{"qemu_img_check":{"rc":0,"clean":true},"e2fsck_fn_on_extracted_raw":{"rc":0}}}'; 'rootfs.json' = '{"file":"rootfs.tar","sha256":"00","source_sha256_matched":true}'; 'zig.json' = '{"file":"hello.exe","sha256":"00"}' }
  }
  foreach ($name in $broken.Keys) {
    $in = Join-Path $tmp "in-$name"
    $outDir = Join-Path $tmp "out-$name/windows-2025"
    New-Item -ItemType Directory -Force -Path $in, $outDir | Out-Null
    foreach ($f in $broken[$name].Keys) { Set-Content -LiteralPath (Join-Path $in $f) -Value $broken[$name][$f] -NoNewline }
    $out = Join-Path $outDir 'results.json'
    & pwsh -NoProfile -File $probe -InputsDir $in -OutFile $out | Out-Null
    $rc = $LASTEXITCODE
    Check "probe.ps1 $name -> exit $rc, expected 1" ($rc -eq 1)
    $r = Get-Content -Raw -LiteralPath $out | ConvertFrom-Json
    Check "probe.ps1 $name -> harness incomplete" ($r.harness.status -eq 'incomplete')
    $steps = @($r.steps.PSObject.Properties)
    $allNotRun = ($steps.Count -eq 9) -and (@($steps | Where-Object { "$($_.Value.verdict)" -notlike 'not-run:*' }).Count -eq 0)
    Check "probe.ps1 $name -> all 9 steps not-run" $allNotRun
    $env:E6_EXPECTED_LEGS = 'windows-2025'
    & bash $judge (Join-Path $tmp "out-$name") 2>&1 | Out-Null
    $jrc = $LASTEXITCODE
    Check "judge on $name -> exit $jrc, expected 1" ($jrc -eq 1)
  }
  $r = Get-Content -Raw -LiteralPath (Join-Path $tmp 'out-no-manifests/windows-2025/results.json') | ConvertFrom-Json
  $parse = @($r.harness.checks | Where-Object { $_.check -eq 'input manifests parse' })
  Check 'probe.ps1 no-manifests -> the manifest parse check is recorded as failed' (($parse.Count -eq 1) -and (-not $parse[0].ok))
} finally {
  Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}

if ($script:fails -ne 0) { Write-Host "FAIL: $script:fails E6 probe check(s)"; exit 1 }
Write-Host 'PASS: E6 probe checks'
exit 0
