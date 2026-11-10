# Windows probes. Usage: windows.ps1 -OutDir DIR -Probe meta|appcontainer|jobnesting|docker
# Each probe writes a JSON fragment and exits non-zero when it fails.
param(
  [Parameter(Mandatory = $true)][string]$OutDir,
  [Parameter(Mandatory = $true)][string]$Probe
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Save($name, $obj) {
  $obj | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 (Join-Path $OutDir "$name.json")
}

$native = @'
using System;
using System.Runtime.InteropServices;
public static class S69Native {
  [DllImport("userenv.dll", CharSet = CharSet.Unicode)]
  public static extern int CreateAppContainerProfile(string name, string display, string desc,
    IntPtr caps, uint capCount, out IntPtr sid);
  [DllImport("userenv.dll", CharSet = CharSet.Unicode)]
  public static extern int DeleteAppContainerProfile(string name);
  [DllImport("advapi32.dll", SetLastError = true)]
  public static extern IntPtr FreeSid(IntPtr sid);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern IntPtr CreateJobObject(IntPtr attrs, string name);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool CloseHandle(IntPtr handle);
}
'@
if (-not ('S69Native' -as [type])) { Add-Type -TypeDefinition $native }

switch ($Probe) {
  'meta' {
    Save 'meta' @{
      os_version    = [Environment]::OSVersion.VersionString
      caption       = (Get-CimInstance Win32_OperatingSystem).Caption
      image_version = $env:ImageVersion
    }
  }

  'appcontainer' {
    $name = 's69.probe.' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    $sid = [IntPtr]::Zero
    $hr = [S69Native]::CreateAppContainerProfile($name, 's69 probe', 's69 probe', [IntPtr]::Zero, 0, [ref]$sid)
    $created = ($hr -eq 0)
    $sidText = $null
    if ($created) {
      $sidText = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Value
      [void][S69Native]::FreeSid($sid)
      [void][S69Native]::DeleteAppContainerProfile($name)
    }
    Save 'appcontainer' @{ created = $created; hresult = ('0x{0:X8}' -f $hr); sid = $sidText }
    if (-not $created) { exit 1 }
  }

  'jobnesting' {
    $self = [System.Diagnostics.Process]::GetCurrentProcess().Handle
    $inJob = $false
    [void][S69Native]::IsProcessInJob($self, [IntPtr]::Zero, [ref]$inJob)
    # Start a child, assign it to a fresh job; nesting works if the runner
    # already put the child in an outer job and the assignment still succeeds.
    $child = Start-Process -FilePath ping.exe -ArgumentList '-n', '6', '127.0.0.1' -PassThru -WindowStyle Hidden
    $childInOuter = $false
    [void][S69Native]::IsProcessInJob($child.Handle, [IntPtr]::Zero, [ref]$childInOuter)
    $job = [S69Native]::CreateJobObject([IntPtr]::Zero, $null)
    $assigned = [S69Native]::AssignProcessToJobObject($job, $child.Handle)
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if (-not $child.HasExited) { $child.Kill() }
    [void][S69Native]::CloseHandle($job)
    Save 'jobnesting' @{
      probe_process_in_job = $inJob
      child_in_outer_job   = $childInOuter
      nested_assign_ok     = $assigned
      win32_error          = $(if ($assigned) { 0 } else { $err })
    }
    if (-not $assigned) { exit 1 }
  }

  'docker' {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $docker) { Save 'docker' @{ installed = $false }; exit 1 }
    $raw = & docker info --format '{{json .}}' 2>&1 | Out-String
    $rc = $LASTEXITCODE
    $rec = @{ installed = $true; rc = $rc }
    if ($rc -eq 0) {
      $info = $raw | ConvertFrom-Json
      foreach ($k in 'OSType', 'Architecture', 'ServerVersion', 'Isolation', 'Runtimes', 'DefaultRuntime') {
        $rec[$k] = $info.$k
      }
    } else {
      $rec['error'] = $raw
    }
    Save 'docker' $rec
    exit $rc
  }

  default { Write-Error "unknown probe: $Probe"; exit 2 }
}
