@echo off
setlocal enabledelayedexpansion

set ROOT_DIR=%~dp0\..\..
pushd "%ROOT_DIR%"

set PLATFORM=%1
if "%PLATFORM%"=="" set PLATFORM=windows

call mix deps.get
if errorlevel 1 goto :error

if not "%BDS_SKIP_TESTS%"=="1" (
  call mix test
  if errorlevel 1 goto :error
)

if not "%BDS_SKIP_DIALYZER%"=="1" (
  call mix dialyzer
  if errorlevel 1 goto :error
)

call set MIX_ENV=prod
call mix release --overwrite bds
if errorlevel 1 goto :error
call mix release --overwrite bds_mcp
if errorlevel 1 goto :error
call mix bds.package %PLATFORM%
if errorlevel 1 goto :error

popd
exit /b 0

:error
popd
exit /b 1