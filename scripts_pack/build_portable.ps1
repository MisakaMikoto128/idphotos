# 木照 Windows 便携单文件版 — 一键重建脚本
# 用法: powershell -ExecutionPolicy Bypass -File scripts_pack\build_portable.ps1
# 前提: 已跑过 flutter build windows --release
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot   # 项目根
$rel  = Join-Path $root "build\windows\x64\runner\Release"
$evb  = Join-Path $root "scripts_pack\muzhao.evb"
$out  = Join-Path $root "dist\muzhao-portable.exe"
$console = Join-Path $root "scripts_pack\enigma\portable\app\enigmavbconsole.exe"

# 1) 由 Release 目录重新生成 .evb 工程（目录结构变化后需重建）
python (Join-Path $root "scripts_pack\make_evb.py") $rel muzhao.exe $out $evb

# 2) Enigma Virtual Box 打包
& $console $evb

# 3) 产物校验和
if (Test-Path $out) {
  $h = (Get-FileHash $out -Algorithm SHA256).Hash
  Set-Content (Join-Path $root "dist\SHA256SUMS.txt") "$h  muzhao-portable.exe"
  Write-Output "OK: $out ($([math]::Round((Get-Item $out).Length/1MB,1)) MB) sha256=$h"
} else { Write-Error "打包失败" }
