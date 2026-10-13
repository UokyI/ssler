#!/usr/bin/env bash
# 证书续期 Web 控制台启动脚本
# 本项目基于 Windows PowerShell + IIS，请在 Windows 上运行（Git Bash / WSL 亦可，需能调用 PowerShell）。
set -euo pipefail

cd "$(dirname "$0")"

if command -v pwsh >/dev/null 2>&1; then
  PS=pwsh
elif command -v powershell.exe >/dev/null 2>&1; then
  PS=powershell.exe
elif command -v powershell >/dev/null 2>&1; then
  PS=powershell
else
  echo "[run] 未找到 PowerShell（pwsh / powershell.exe）。" >&2
  echo "[run] 本项目基于 Windows PowerShell + IIS，请在 Windows 上运行；" >&2
  echo "[run] 或在 Windows 上直接双击 run.bat。" >&2
  exit 1
fi

echo "[run] 使用 $PS 启动证书续期 Web 控制台 ..."
echo "[run] 停止请按 Ctrl+C；如需开机自启请运行：./run.sh -Install"

exec "$PS" -NoProfile -ExecutionPolicy Bypass -File "./Start-AcmeWeb.ps1" "$@"
