@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo   WorkBuddy 实时状态监控
echo   关闭此窗口即可停止服务
echo.
node monitor-server.mjs --open
if errorlevel 1 (
  echo.
  echo   [!] 启动失败：请确认已安装 Node.js
  pause
)
