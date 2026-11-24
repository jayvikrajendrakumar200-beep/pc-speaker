#!/usr/bin/env python3
"""
PC Audio Server for iPhone Speaker App
- Captures system audio (WASAPI loopback) → streams via HTTP (Opus/Ogg)
- Receives microphone audio from iPhone via WebSocket → plays / virtual mic
- Supports USB tethering via usbmuxd tunnel
"""

import asyncio
import threading
import queue
import struct
import base64
import json
import logging
import sys
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
import websockets
import numpy as np

# Audio dependencies
try:
    import sounddevice as sd
    import soundfile as sf
except ImportError:
    print("Installing audio dependencies...")
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "sounddevice", "soundfile", "websockets", "numpy"])
    import sounddevice as sd
    import soundfile as sf

# Opus encoding (optional, falls back to raw PCM)
try:
    import opuslib
    HAS_OPUS = True
except ImportError:
    HAS_OPUS = False
    print("opuslib not installed - using raw PCM (higher bandwidth). Install with: pip install opuslib")

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
log = logging.getLogger(__name__)

# ==================== CONFIGURATION ====================
HTTP_PORT = 8080
WS_PORT = 8081
SAMPLE_RATE = 48000
CHANNELS = 2  # System audio capture (stereo)
CHUNK_DURATION_MS = 20  # 20ms chunks = 960 frames at 48kHz
CHUNK_SAMPLES = int(SAMPLE_RATE * CHUNK_DURATION_MS / 1000)
OPUS_BITRATE = 96000  # 96 kbps for stereo
MIC_SAMPLE_RATE = 48000
MIC_CHANNELS = 1
# ========================================================

# Global audio queues
system_audio_queue = queue.Queue(maxsize=50)
mic_audio_queue = queue.Queue(maxsize=50)
connected_ws_clients = set()
mic_gain = 1.0


# ==================== SYSTEM AUDIO CAPTURE ====================
def list_loopback_devices():
    """Find WASAPI loopback devices on Windows"""
    devices = sd.query_devices()
    loopback_devices = []
    for i, dev in enumerate(devices):
        if dev['max_input_channels'] > 0:
            # Check for loopback in name (Windows WASAPI)
            name_lower = dev['name'].lower()
            if any(kw in name_lower for kw in ['loopback', 'stereo mix', 'what u hear', 'wave out']):
                loopback_devices.append((i, dev))
    return loopback_devices


def find_default_loopback():
    """Find the default output device's loopback counterpart"""
    devices = sd.query_devices()
    default_out = sd.default.device[1] if isinstance(sd.default.device, (list, tuple)) else None

    if default_out is not None and default_out < len(devices):
        default_dev = devices[default_out]
        # Look for loopback of same device
        for i, dev in enumerate(devices):
            if dev['max_input_channels'] > 0 and default_dev['name'] in dev['name']:
                return i

    # Fallback: first loopback device
    loopbacks = list_loopback_devices()
    return loopbacks[0][0] if loopbacks else None


def audio_callback(indata, frames, time, status):
    """Callback for system audio capture (runs on audio thread)"""
    if status:
        log.warning(f"Audio callback status: {status}")
    try:
        system_audio_queue.put_nowait(indata.copy())
    except queue.Full:
        pass  # Drop frame if queue full


def start_system_capture(device_id=None):
    """Start capturing system audio"""
    if device_id is None:
        device_id = find_default_loopback()

    if device_id is None:
        log.error("No loopback device found! Enable 'Stereo Mix' in Windows Sound settings or use Voicemeeter.")
        return None

    dev_info = sd.query_devices(device_id)
    log.info(f"Capturing from: {dev_info['name']} (device {device_id})")

    stream = sd.InputStream(
        device=device_id,
        samplerate=SAMPLE_RATE,
        channels=CHANNELS,
        dtype='float32',
        blocksize=CHUNK_SAMPLES,
        callback=audio_callback,
    )
    stream.start()
    return stream


# ==================== OPUS ENCODING ====================
class OpusEncoder:
    def __init__(self, sample_rate=48000, channels=2, bitrate=96000):
        self.encoder = None
        if HAS_OPUS:
            self.encoder = opuslib.Encoder(sample_rate, channels, opuslib.APPLICATION_AUDIO)
            self.encoder.bitrate = bitrate
            self.frame_size = sample_rate // 50  # 20ms

    def encode(self, pcm_float32: np.ndarray) -> bytes:
        """Encode float32 PCM to Opus"""
        if self.encoder is None:
            # No opus - return raw PCM with simple header
            return b'PCM' + pcm_float32.astype('<f4').tobytes()

        # Convert float32 [-1,1] to int16
        pcm_int16 = (np.clip(pcm_float32, -1, 1) * 32767).astype('<i2')
        # Opus expects frames of specific size
        if len(pcm_int16) != self.frame_size * self.encoder.channels:
            # Resize/pad
            target = self.frame_size * self.encoder.channels
            if len(pcm_int16) > target:
                pcm_int16 = pcm_int16[:target]
            else:
                pcm_int16 = np.pad(pcm_int16, (0, target - len(pcm_int16)))

        return self.encoder.encode(pcm_int16.tobytes(), self.frame_size)


opus_encoder = OpusEncoder(SAMPLE_RATE, CHANNELS, OPUS_BITRATE)


# ==================== HTTP STREAMING HANDLER ====================
class StreamingHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/stream' or self.path == '/stream.ogg':
            self.stream_audio()
        elif self.path == '/status':
            self.send_json({'status': 'ok', 'clients': len(connected_ws_clients)})
        else:
            self.send_error(404)

    def stream_audio(self):
        """Stream system audio as Ogg/Opus or raw PCM"""
        self.send_response(200)
        if HAS_OPUS:
            self.send_header('Content-Type', 'audio/ogg; codecs=opus')
        else:
            self.send_header('Content-Type', 'audio/pcm; rate=48000; channels=2')
        self.send_header('Transfer-Encoding', 'chunked')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'keep-alive')
        self.end_headers()

        log.info(f"HTTP stream client connected: {self.client_address}")

        # Write Ogg header if using Opus
        if HAS_OPUS:
            ogg_header = self.create_ogg_header()
            self.write_chunk(ogg_header)

        try:
            while True:
                try:
                    chunk = system_audio_queue.get(timeout=5.0)
                    encoded = opus_encoder.encode(chunk[:, 0] if CHANNELS == 1 else chunk.mean(axis=1))
                    self.write_chunk(encoded)
                except queue.Empty:
                    # Send keep-alive
                    self.write_chunk(b'')
        except (ConnectionError, BrokenPipeError, OSError):
            log.info(f"HTTP stream client disconnected: {self.client_address}")
        except Exception as e:
            log.error(f"Stream error: {e}")

    def create_ogg_header(self) -> bytes:
        """Create minimal Ogg/Opus header"""
        # Simplified Ogg header for Opus
        # In production, use pyogg or similar
        return b'OggS' + b'\x00' * 27  # Placeholder

    def write_chunk(self, data: bytes):
        """Write chunked transfer encoding"""
        try:
            self.wfile.write(f"{len(data):X}\r\n".encode())
            self.wfile.write(data)
            self.wfile.write(b"\r\n")
            self.wfile.flush()
        except (ConnectionError, BrokenPipeError, OSError):
            raise

    def send_json(self, data: dict):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def log_message(self, format, *args):
        log.debug(f"HTTP: {format % args}")


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


# ==================== WEBSOCKET HANDLER ====================
async def ws_handler(websocket):
    """Handle WebSocket connection from iPhone for mic/control"""
    connected_ws_clients.add(websocket)
    log.info(f"WS client connected: {websocket.remote_address}, total: {len(connected_ws_clients)}")

    try:
        async for message in websocket:
            try:
                msg = json.loads(message)
                await handle_ws_message(websocket, msg)
            except json.JSONDecodeError:
                pass
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        connected_ws_clients.discard(websocket)
        log.info(f"WS client disconnected, remaining: {len(connected_ws_clients)}")


async def handle_ws_message(ws, msg):
    global mic_gain
    msg_type = msg.get('type')

    if msg_type == 'mic_start':
        config = msg.get('config', {})
        log.info(f"Mic stream started: {config}")

    elif msg_type == 'mic_data':
        # Decode base64 Opus data from iPhone
        try:
            opus_data = base64.b64decode(msg['data'])
            # For now, queue raw opus - in production decode and play
            mic_audio_queue.put_nowait(opus_data)
        except Exception as e:
            log.error(f"Mic data error: {e}")

    elif msg_type == 'mic_stop':
        log.info("Mic stream stopped")

    elif msg_type == 'mic_gain':
        mic_gain = msg.get('gain', 1.0)
        log.info(f"Mic gain set to {mic_gain}")

    # Echo back for confirmation
    try:
        await ws.send(json.dumps({'type': 'ack', 'original': msg_type}))
    except:
        pass


# ==================== MIC PLAYBACK / VIRTUAL MIC ====================
def mic_playback_loop():
    """Play received mic audio on PC speakers (monitoring)"""
    # Create output stream for monitoring
    stream = sd.OutputStream(
        samplerate=MIC_SAMPLE_RATE,
        channels=1,
        dtype='float32',
        blocksize=CHUNK_SAMPLES,
    )
    stream.start()

    log.info("Mic monitoring started (playing iPhone mic on PC speakers)")

    # Simple Opus decoder if available
    decoder = None
    if HAS_OPUS:
        decoder = opuslib.Decoder(MIC_SAMPLE_RATE, 1)

    while True:
        try:
            opus_data = mic_audio_queue.get(timeout=1.0)
            if decoder and len(opus_data) > 0:
                try:
                    pcm = decoder.decode(opus_data, CHUNK_SAMPLES)
                    audio = np.frombuffer(pcm, dtype='<i2').astype('float32') / 32767.0
                    audio = audio * mic_gain
                    stream.write(audio.reshape(-1, 1))
                except Exception as e:
                    log.debug(f"Opus decode error: {e}")
        except queue.Empty:
            continue
        except Exception as e:
            log.error(f"Mic playback error: {e}")


# ==================== MAIN ====================
def print_banner():
    print("""
╔══════════════════════════════════════════════════════════════╗
║                  PC SPEAKER SERVER v1.0                      ║
║         Stream PC audio to iPhone | iPhone mic to PC         ║
╚══════════════════════════════════════════════════════════════╝
""")
    print("Audio Devices:")
    devices = sd.query_devices()
    for i, d in enumerate(devices):
        if d['max_input_channels'] > 0:
            marker = " ← DEFAULT" if i == sd.default.device[0] else ""
            print(f"  [{i}] {d['name']} (in:{d['max_input_channels']} out:{d['max_output_channels']}){marker}")
    print()
    print(f"HTTP Stream: http://<PC_IP>:{HTTP_PORT}/stream")
    print(f"WebSocket:   ws://<PC_IP>:{WS_PORT}/ws")
    print()
    print("USB Mode (no WiFi):")
    print(f"  pip install usbmuxd")
    print(f"  python -m usbmuxd_tunnel {HTTP_PORT} {WS_PORT}")
    print(f"  Then iPhone accesses: http://localhost:{HTTP_PORT}/stream")
    print()
    print("Press Ctrl+C to stop")
    print("=" * 60)


async def run_servers():
    """Run HTTP and WebSocket servers"""
    # HTTP server in thread
    http_server = ThreadingHTTPServer(('0.0.0.0', HTTP_PORT), StreamingHandler)
    http_thread = threading.Thread(target=http_server.serve_forever, daemon=True)
    http_thread.start()
    log.info(f"HTTP server started on port {HTTP_PORT}")

    # WebSocket server
    ws_server = await websockets.serve(ws_handler, '0.0.0.0', WS_PORT)
    log.info(f"WebSocket server started on port {WS_PORT}")

    # Keep running
    await asyncio.Future()  # Run forever


def main():
    print_banner()

    # Start system audio capture
    capture_stream = start_system_capture()
    if capture_stream is None:
        print("\n❌ Failed to start audio capture!")
        print("Fix: Enable 'Stereo Mix' in Windows Sound Control Panel")
        print("     Recording tab → Right-click → Show Disabled Devices → Enable Stereo Mix")
        print("     Or install Voicemeeter Banana (free virtual audio mixer)")
        return 1

    # Start mic playback thread
    mic_thread = threading.Thread(target=mic_playback_loop, daemon=True)
    mic_thread.start()

    # Run async servers
    try:
        asyncio.run(run_servers())
    except KeyboardInterrupt:
        print("\n\nShutting down...")
    finally:
        capture_stream.stop()
        capture_stream.close()

    return 0


if __name__ == '__main__':
    sys.exit(main())