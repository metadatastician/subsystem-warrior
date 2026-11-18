# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# probe-lib.ps1 - the E6 probe's pure decisions, kept apart from wsl.exe so
# they can be tested on any host (tests/m0/e6/probe_test.ps1, run on Linux in
# CI). probe.ps1 dot-sources this file.

# Read one input manifest. Any read or parse error, an empty file, or a
# manifest without `file` and `sha256` throws: a broken input is a harness
# fault, never a capability answer.
function Read-Manifest([string]$Dir, [string]$Name) {
  $path = Join-Path $Dir $Name
  $text = Get-Content -Raw -LiteralPath $path -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace($text)) { throw "$Name is empty" }
  $m = $text | ConvertFrom-Json -ErrorAction Stop
  if ($null -eq $m) { throw "$Name parsed to nothing" }
  if (-not $m.file -or -not $m.sha256) { throw "$Name lacks file or sha256" }
  return $m
}

# Turn one `lsblk --json` observation into a device list. `ok` is false when
# lsblk failed or its output does not have lsblk's shape (`blockdevices` an
# array, every device with a path, `children` an array when present): an
# observation that failed is not an observation of zero devices.
function ConvertFrom-Lsblk($Raw) {
  $devs = @()
  if ($Raw.rc -ne 0) {
    return [ordered]@{ ok = $false; error = "lsblk exited $($Raw.rc)"; devices = $devs }
  }
  try {
    $j = $Raw.output | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $j -or $null -eq $j.blockdevices) { throw 'no blockdevices array' }
    if ($j.blockdevices -isnot [array]) { throw 'blockdevices is not an array' }
    $stack = [Collections.Generic.Stack[object]]::new()
    foreach ($d in $j.blockdevices) { $stack.Push($d) }
    while ($stack.Count -gt 0) {
      $d = $stack.Pop()
      if (-not "$($d.path)") { throw 'a device has no path' }
      if ($null -ne $d.children -and $d.children -isnot [array]) { throw "children of $($d.path) is not an array" }
      $devs += [ordered]@{ path = "$($d.path)"; type = "$($d.type)"; size = "$($d.size)"; uuid = "$($d.uuid)" }
      foreach ($c in @($d.children)) { if ($c) { $stack.Push($c) } }
    }
  } catch {
    return [ordered]@{ ok = $false; error = "lsblk output did not parse: $_"; devices = @() }
  }
  return [ordered]@{ ok = $true; error = ''; devices = $devs }
}

# Decide bare-mount from what was observed. Order matters:
#   1. the mount itself reported failure          -> no (observed)
#   2. either device observation failed           -> harness fault
#   3. no new block device appeared               -> no (observed)
#   4. exactly one new device has the size and UUID -> yes
#   5. otherwise                                  -> harness fault (ambiguous)
# Returns verdict, the harness fault (or ''), and a one-line reading.
function Resolve-BareMount([bool]$MountFailed, [bool]$BeforeOk, [bool]$AfterOk, [int]$NewCount, [int]$MatchCount) {
  if ($MountFailed) {
    return [ordered]@{ verdict = 'no'; fault = ''; reading = 'capability no: the mount returned an error' }
  }
  if (-not ($BeforeOk -and $AfterOk)) {
    $f = 'device observation failed (lsblk ' + $(if (-not $BeforeOk) { 'before' } else { 'after' }) + ' the mount)'
    return [ordered]@{ verdict = 'not-run: harness device observation failed'; fault = $f; reading = "incomplete: harness: $f" }
  }
  if ($NewCount -eq 0) {
    return [ordered]@{ verdict = 'no'; fault = ''; reading = 'capability no: the mount reported success but no new block device appeared' }
  }
  if ($MatchCount -eq 1) {
    return [ordered]@{ verdict = 'yes'; fault = ''; reading = 'one new device matches the expected size and UUID' }
  }
  $f = "$MatchCount of $NewCount new devices match the expected size and UUID"
  return [ordered]@{ verdict = 'not-run: harness ambiguous device match'; fault = $f; reading = "incomplete: harness: $f" }
}
