#!/usr/bin/env python3
"""
usbmuxd Tunnel for iPhone USB Connection
Creates TCP tunnels from localhost ports to iPhone via USB
Usage: python usbmuxd_tunnel.py <local_port> <device_port>
Example: python usbmuxd_tunnel.py 8080 8080
"""

import sys
import asyncio
import logging
import argparse

try:
    import usbmuxd
except ImportError:
    print("Installing usbmuxd...")
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "usbmuxd"])
    import usbmuxd

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
log = logging.getLogger(__name__)


async def forward(local_port: int, device_port: int, device_udid: str = None):
    """Forward local TCP port to iPhone device port via USB"""
    # Find device
    devices = usbmuxd.list_devices()
    if not devices:
        log.error("No iOS devices found via USB. Make sure iPhone is connected and trusted.")
        return

    if device_udid:
        device = next((d for d in devices if d.serial == device_udid), None)
        if not device:
            log.error(f"Device {device_udid} not found")
            return
    else:
        device = devices[0]
        log.info(f"Using device: {device.serial}")

    log.info(f"Starting tunnel: localhost:{local_port} -> iPhone:{device_port}")

    # Create tunnel using usbmuxd's built-in TCP forwarding
    # usbmuxd.connect creates a connection to the device's TCP port
    async def handle_client(reader, writer):
        try:
            # Connect to device port
            device_conn = usbmuxd.connect(device_port, device.serial)
            device_reader = asyncio.StreamReader()
            device_protocol = asyncio.StreamReaderProtocol(device_reader)
            await asyncio.get_event_loop().connect_read_pipe(lambda: device_protocol, device_conn)
            device_writer = asyncio.StreamWriter(device_conn, {}, None, asyncio.get_event_loop())

            async def pipe(src_reader, dst_writer, name):
                try:
                    while True:
                        data = await src_reader.read(4096)
                        if not data:
                            break
                        dst_writer.write(data)
                        await dst_writer.drain()
                except Exception as e:
                    log.debug(f"{name} pipe error: {e}")
                finally:
                    dst_writer.close()

            await asyncio.gather(
                pipe(reader, device_writer, "client->device"),
                pipe(device_reader, writer, "device->client"),
            )
        except Exception as e:
            log.error(f"Connection error: {e}")
        finally:
            writer.close()
            await writer.wait_closed()

    server = await asyncio.start_server(handle_client, '127.0.0.1', local_port)
    log.info(f"Tunnel active on http://localhost:{local_port}")

    async with server:
        await server.serve_forever()


def main():
    parser = argparse.ArgumentParser(description='usbmuxd TCP tunnel for iPhone')
    parser.add_argument('local_port', type=int, help='Local port to listen on')
    parser.add_argument('device_port', type=int, nargs='?', default=None, help='Port on iPhone (default: same as local)')
    parser.add_argument('--udid', help='Specific device UDID (optional)')
    args = parser.parse_args()

    device_port = args.device_port or args.local_port

    try:
        asyncio.run(forward(args.local_port, device_port, args.udid))
    except KeyboardInterrupt:
        log.info("Tunnel stopped")


if __name__ == '__main__':
    main()