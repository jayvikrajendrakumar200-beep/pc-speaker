@echo off
title PC Speaker Server
color 0A

echo ╔══════════════════════════════════════════════════════════════╗
echo ║                  PC SPEAKER SERVER v1.0                      ║
echo ║         Stream PC audio to iPhone | iPhone mic to PC         ║
echo ╚══════════════════════════════════════════════════════════════╝
echo.

REM Check Python
python --version >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Python not found in PATH
    echo Please install Python 3.9+ from python.org
    echo Make sure to check "Add Python to PATH" during installation
    pause
    exit /b 1
)

echo [OK] Python found

REM Install dependencies
echo.
echo [INFO] Installing/updating dependencies...
pip install -q sounddevice soundfile websockets numpy opuslib usbmuxd 2>&1 | findstr /V "already satisfied"

REM Check for Stereo Mix
echo.
echo [INFO] Checking audio devices...
python -c "
import sounddevice as sd
devices = sd.query_devices()
found = False
for i, d in enumerate(devices):
    if d['max_input_channels'] > 0:
        name = d['name'].lower()
        if any(kw in name for kw in ['loopback', 'stereo mix', 'what u hear', 'wave out']):
            print(f'  [OK] Loopback device found: {d[\"name\"]}')
            found = True
if not found:
    print('  [WARN] No loopback device detected!')
    print('         Enable "Stereo Mix" in Windows Sound Control Panel')
    print('         Recording tab -> Right-click -> Show Disabled Devices -> Enable Stereo Mix')
"

echo.
echo [INFO] Starting server...
echo [INFO] HTTP Stream: http://^<YOUR_PC_IP^>:8080/stream
echo [INFO] WebSocket:   ws://^<YOUR_PC_IP^>:8081/ws
echo.
echo [INFO] For USB mode, run in another terminal:
echo        python usbmuxd_tunnel.py 8080 8080
echo        python usbmuxd_tunnel.py 8081 8081
echo.
echo Press Ctrl+C to stop
echo ================================================================

python pc_audio_server.py

pause