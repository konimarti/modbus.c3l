import socket
import sys
import time

host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 5020

start = time.time()
while time.time() - start < 5.0:
    try:
        with socket.create_connection((host, port), timeout=0.1):
            time.sleep(0.05)
    except Exception:
        sys.exit(0)

sys.exit(0)
