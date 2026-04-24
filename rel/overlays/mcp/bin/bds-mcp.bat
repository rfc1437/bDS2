@echo off
set SCRIPT_DIR=%~dp0
set RELEASE_ROOT=%SCRIPT_DIR%..\..

call "%RELEASE_ROOT%\bin\bds_mcp.bat" eval "Application.ensure_all_started(:bds); BDS.MCP.Stdio.main()"