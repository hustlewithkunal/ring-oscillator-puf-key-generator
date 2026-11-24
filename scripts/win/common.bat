@echo off
rem ===========================================================================
rem Shared part of the double-click launchers (called by the .bat files in the
rem project root, never run on its own).
rem   call scripts\win\common.bat setup      find Vivado and Python, make folders
rem   call scripts\win\common.bat bitstream  make sure build\top_soc.bit/.ltx exist,
rem                                          build them (about 15-20 min) if missing
rem   call scripts\win\common.bat checkdemo ^<demo_x.txt^> ^<vivado log^> ^<N^>
rem                                          PASS/FAIL summary of a soc_demo.tcl run
rem Sets ROOT, VIVADO, PY, TS (time stamp) and LOGDIR. Returns errorlevel 1 on error.
rem ===========================================================================
if /i "%~1"=="setup" goto :setup
if /i "%~1"=="bitstream" goto :bitstream
if /i "%~1"=="checkdemo" goto :checkdemo
if /i "%~1"=="hwerror" goto :hwerror
echo common.bat: unknown action "%~1"
exit /b 1

:setup
for %%I in ("%~dp0..\..") do set "ROOT=%%~fI"
cd /d "%ROOT%"
for /f "usebackq delims=" %%t in (`powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"`) do set "TS=%%t"
set "LOGDIR=%ROOT%\build\logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"

rem ---- Vivado: VIVADO_BIN, then XILINX_VIVADO, then PATH, then the default install
set "VIVADO="
if defined VIVADO_BIN if exist "%VIVADO_BIN%\vivado.bat" set "VIVADO=%VIVADO_BIN%\vivado.bat"
if not defined VIVADO if defined XILINX_VIVADO if exist "%XILINX_VIVADO%\bin\vivado.bat" set "VIVADO=%XILINX_VIVADO%\bin\vivado.bat"
if not defined VIVADO for /f "delims=" %%v in ('where vivado.bat 2^>nul') do if not defined VIVADO set "VIVADO=%%v"
if not defined VIVADO if exist "C:\Xilinx\Vivado\2024.2\bin\vivado.bat" set "VIVADO=C:\Xilinx\Vivado\2024.2\bin\vivado.bat"
if not defined VIVADO (
    echo [ERROR] Vivado not found. Install Vivado 2024.2, or set VIVADO_BIN to the
    echo         folder that contains vivado.bat, e.g. C:\Xilinx\Vivado\2024.2\bin
    exit /b 1
)

rem ---- Python 3 (only needed to assemble the firmware and to show the key)
set "PY="
for /f "delims=" %%p in ('where python 2^>nul') do if not defined PY (
    "%%p" -c "import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)" >nul 2>&1 && set PY="%%p"
)
if not defined PY (
    py -3 -c "import sys" >nul 2>&1 && set "PY=py -3"
)

echo Project folder : %ROOT%
echo Vivado         : %VIVADO%
if defined PY echo Python         : %PY%
if not defined PY echo Python         : not found
echo.
exit /b 0

:bitstream
if exist "%ROOT%\build\top_soc.bit" if exist "%ROOT%\build\top_soc.ltx" (
    for %%f in ("%ROOT%\build\top_soc.bit") do echo [OK] Bitstream found: build\top_soc.bit  ^(%%~tf^)
    exit /b 0
)
echo [..] build\top_soc.bit / .ltx not found: building the SoC bitstream now.
echo      This runs synthesis, place and route and takes about 15-20 minutes.
echo      (A reference bitstream is in prebuilt\ if this folder has one; this
echo       launcher always builds your own so the result matches your sources.)
echo.
if not exist "%ROOT%\sw\firmware.mem" (
    if not defined PY (
        echo [ERROR] sw\firmware.mem is missing and Python is not available to assemble it.
        exit /b 1
    )
    echo [..] Assembling the firmware: sw\firmware.S -^> sw\firmware.mem
    %PY% "%ROOT%\sw\rvasm.py" "%ROOT%\sw\firmware.S" "%ROOT%\sw\firmware.mem"
    if errorlevel 1 (
        echo [ERROR] Firmware assembly failed.
        exit /b 1
    )
)
set "BUILDLOG=%LOGDIR%\build_soc_%TS%.log"
echo [..] Vivado build, full log: %BUILDLOG%
rem Vivado cannot insert the debug hub (needed by our VIO) when its temporary folder
rem path exceeds 146 characters, which happens when the project sits in a deep folder
rem (e.g. Downloads\...-main\...-main). Then build through a temporary drive letter.
set "BROOT=%ROOT%"
set "SUBST_DRV="
set "ROOT_LEN=0"
for /f %%n in ('powershell -NoProfile -Command "$env:ROOT.Length"') do set "ROOT_LEN=%%n"
if %ROOT_LEN% GTR 40 call :map_short_drive
pushd "%BROOT%\"
call "%VIVADO%" -mode batch -nojournal -log "%BUILDLOG%" -source "%BROOT%\scripts\build_soc.tcl"
popd
if defined SUBST_DRV (
    subst %SUBST_DRV% /d >nul 2>&1
    echo [..] Temporary drive %SUBST_DRV% removed.
)
if not exist "%ROOT%\build\top_soc.bit" goto :build_failed
findstr /b /l /c:"BUILD_OK" "%BUILDLOG%" >nul || goto :build_failed
echo.
for /f "delims=" %%l in ('findstr /b /l /c:"BUILD_OK" "%BUILDLOG%"') do echo [OK] %%l
exit /b 0

:build_failed
echo.
echo [ERROR] The build did not produce build\top_soc.bit. See %BUILDLOG%
findstr /l /c:"Chipscope 16-302" "%BUILDLOG%" >nul && (
    echo         Vivado reports the folder path is too long. Move this folder to a short
    echo         path such as C:\RO_PUF and run the launcher again.
)
exit /b 1

:map_short_drive
rem first free drive letter from P: upwards, mapped to the project folder
for %%d in (P Q R S T U V W X Y) do if not defined SUBST_DRV if not exist %%d:\ set "SUBST_DRV=%%d:"
if not defined SUBST_DRV (
    echo [!!] Long folder path ^(%ROOT_LEN% characters^) and no free drive letter: the build may fail.
    exit /b 0
)
subst %SUBST_DRV% "%ROOT%"
if errorlevel 1 (
    echo [!!] subst failed; building from the long path ^(%ROOT_LEN% characters^), which may fail.
    set "SUBST_DRV="
    exit /b 0
)
set "BROOT=%SUBST_DRV%"
echo [..] Folder path is %ROOT_LEN% characters long: building through temporary drive %SUBST_DRV%
exit /b 0

:checkdemo
rem %2 = demo text file, %3 = Vivado log, %4 = number of reliability reconstructions
set "FAILS=0"
if not exist "%~2" goto :demo_not_run
findstr /l /c:"LINK:" "%~2" >nul || goto :demo_not_run
echo.
echo ============================== DEMO OUTPUT ==============================
type "%~2"
echo =========================================================================
echo.
call :expect "%~2" "REFUSED (locked)"            "second enrolment refused (one-time lock)"
call :expect "%~2" "-> AUTHENTICATED"            "device 0 authenticated with restored helper data"
call :expect "%~2" "IMPOSTOR device 1: reconstruct key_valid=0" "device 1 cannot rebuild the key"
call :expect "%~2" "IMPOSTOR device 2: reconstruct key_valid=0" "device 2 cannot rebuild the key"
findstr /l /c:"AUTH ACCEPTED" "%~2" >nul && (echo   [FAIL] an impostor was accepted& set /a FAILS+=1)
call :expect "%~2" "RELIABILITY: %~4/%~4 reconstructions gave a valid key, %~4/%~4 answered" "%~4/%~4 reconstructions gave the same key"
findstr /l /c:"ENROL device 0: key_valid=0 locked=1 cmd_err=1" "%~2" >nul && (
    echo.
    echo   Enrolment was locked from reset: switch SW3 ^(emulated one-time fuse^) OFF and run again.
)
echo.
if "%FAILS%"=="0" (echo RESULT: ALL CHECKS PASSED) else (echo RESULT: %FAILS% CHECK^(S^) FAILED)
if "%FAILS%"=="0" exit /b 0
exit /b 1

:demo_not_run
echo.
echo [FAIL] The demo did not start: no answer from the board.
call :hwerror - "%~3"
exit /b 1

:expect
rem no parenthesised blocks here: the label text may itself contain ( and )
findstr /l /c:"%~2" "%~1" >nul
if errorlevel 1 goto :expect_fail
echo   [PASS] %~3
exit /b 0
:expect_fail
echo   [FAIL] %~3
set /a FAILS+=1
exit /b 0

:hwerror
rem %2 = Vivado log: explain the usual hardware problems
if not exist "%~2" exit /b 0
findstr /l /i /c:"No hardware targets" /c:"no hw_target" /c:"Labtoolstcl 44-" "%~2" >nul && (
    echo   The board was not found on JTAG. Check the USB cable ^(PROG/UART port^), that the
    echo   board is powered ^(power switch ON, JP5 on USB^) and that the Digilent cable
    echo   driver is installed ^(it comes with Vivado^). Close the Hardware Manager in any
    echo   open Vivado window, it holds the JTAG cable.
)
findstr /r /b /c:"firmware not responding" /c:"command [0-9]* timed out" "%~2" >nul && (
    echo   The firmware did not answer over the mailbox. Press the board reset or power
    echo   cycle the board and run again.
)
echo   Full Vivado log: %~2
exit /b 0
