@echo off
setlocal EnableExtensions
chcp 65001 >nul
cd /d "%~dp0"

rem ---- 需要管理员权限（操作 IIS / 证书 / 计划任务）----
fltmc >nul 2>&1
if errorlevel 1 (
    echo [run] 需要管理员权限，正在申请提升...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -Verb RunAs -FilePath '%~f0' -ArgumentList '%*'"
    exit /b
)

echo [run] 启动证书续期 Web 控制台...
echo [run] 停止请按 Ctrl+C；如需开机自启请运行：run.bat -Install
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-AcmeWeb.ps1" %*

echo.
echo [run] 服务已退出，按任意键关闭窗口...
pause >nul
