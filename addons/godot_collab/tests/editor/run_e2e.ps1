param(
    [string]$Godot = 'C:\Users\antho\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe',
    [int]$TimeoutSec = 360,
    [int]$Port = 47950,
    [switch]$Keep,
    [switch]$Windowed
)
# Two real Godot editors (headless) with the add-on enabled collaborate on a tiny test project.
# Each runs a script (host_test.gd / client_test.gd) that drives the editor like a user would and
# records PASS/FAIL. Usage:  powershell -File run_e2e.ps1 [-Godot path\to\Godot_console.exe] [-Keep]
$ErrorActionPreference = 'Stop'
$addonSrc = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$root = Join-Path $env:TEMP ('collab_e2e_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
$shared = Join-Path $root 'shared'
New-Item -ItemType Directory -Force -Path $shared | Out-Null

function New-TestProject([string]$dir, [string]$role, [string]$playerText) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $addonDst = Join-Path $dir 'addons\godot_collab'
    New-Item -ItemType Directory -Force -Path $addonDst | Out-Null
    Copy-Item -Path (Join-Path $addonSrc '*') -Destination $addonDst -Recurse -Force -Exclude '*.uid'
    @'
config_version=5

[application]

config/name="CollabE2E"
run/main_scene="res://main.tscn"
config/features=PackedStringArray("4.4")

[editor_plugins]

enabled=PackedStringArray("res://addons/godot_collab/plugin.cfg")
'@ | Set-Content -Path (Join-Path $dir 'project.godot') -Encoding UTF8
    @'
[gd_scene format=3]

[node name="Main" type="Node3D"]

[node name="Block" type="Node3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0)

[node name="Other" type="Node3D" parent="."]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 2, 0)

[node name="Mesh" type="MeshInstance3D" parent="."]
'@ | Set-Content -Path (Join-Path $dir 'main.tscn') -Encoding UTF8
    Set-Content -Path (Join-Path $dir 'player.gd') -Value $playerText -Encoding UTF8
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'src') | Out-Null
    @'
#include <godot_cpp/godot.hpp>

int main() {
	return 0;
}
'@ | Set-Content -Path (Join-Path $dir 'src\native.cpp') -Encoding UTF8
}

$hostDir = Join-Path $root 'host'
$clientDir = Join-Path $root 'client'
New-TestProject $hostDir 'host' "extends Node`n`nvar speed = 5`n"
New-TestProject $clientDir 'client' "extends Node`n# STALE LOCAL COPY`n"

Write-Output "Importing test projects in $root ..."
foreach ($d in @($hostDir, $clientDir)) {
    $role = Split-Path $d -Leaf
    $p = Start-Process -FilePath $Godot -ArgumentList @('--headless', '--editor', '--quit', '--path', $d) -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $root ($role + '_import.log')) -RedirectStandardError (Join-Path $root ($role + '_import.err'))
    if (-not $p.WaitForExit(180000)) { Stop-Process -Id $p.Id -Force; throw "Import timed out for $d" }
}

function Start-Editor([string]$dir, [string]$testScript, [string]$launchJson, [string]$log) {
    $env:GODOT_COLLAB_LAUNCH = $launchJson
    $env:GODOT_COLLAB_TEST = $testScript
    $env:GODOT_COLLAB_SHARED = $shared
    $env:GODOT_COLLAB_VERBOSE = '1'
    $godotArgs = @('--editor', '--path', $dir)
    if (-not $Windowed) { $godotArgs = @('--headless') + $godotArgs }
    return Start-Process -FilePath $Godot -ArgumentList $godotArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError ($log + '.err')
}

Write-Output 'Launching host and client editors ...'
$hostProc = Start-Editor $hostDir 'res://addons/godot_collab/tests/editor/host_test.gd' ('{"mode":"host","port":' + $Port + ',"key":"e2e","name":"Hana"}') (Join-Path $root 'host.log')
Start-Sleep -Seconds 4
$clientProc = Start-Editor $clientDir 'res://addons/godot_collab/tests/editor/client_test.gd' ('{"mode":"join","address":"127.0.0.1","port":' + $Port + ',"key":"e2e","name":"Cole"}') (Join-Path $root 'client.log')

$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline -and (-not $hostProc.HasExited -or -not $clientProc.HasExited)) { Start-Sleep -Seconds 1 }
foreach ($p in @($hostProc, $clientProc)) { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force; Write-Output "killed pid $($p.Id) (timeout)" } }

$failures = 0
foreach ($who in 'host', 'client') {
    $rf = Join-Path $shared "${who}_results.json"
    if (-not (Test-Path $rf)) { Write-Output "${who}: NO RESULTS (see $root\$who.log)"; $failures++; continue }
    $data = Get-Content $rf -Raw | ConvertFrom-Json
    foreach ($prop in $data.results.PSObject.Properties) {
        $ok = [bool]$prop.Value
        Write-Output ("  {0,-6} {1}  {2}" -f $who, $(if ($ok) { 'PASS' } else { 'FAIL' }), $prop.Name)
        if (-not $ok) { $failures++ }
    }
}
Write-Output ""
Write-Output "e2e: $failures failure(s). Logs and projects: $root"
if ($failures -gt 0) {
    foreach ($who in 'host', 'client') {
        $lf = Join-Path (Join-Path $root $who) '.godot\godot_collab\collab.log'
        if (Test-Path $lf) { Write-Output "---- last lines of $who collab.log ----"; Get-Content $lf -Tail 40 }
    }
}
if (-not $Keep -and $failures -eq 0) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
exit $failures
