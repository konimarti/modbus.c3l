import socket
import sys
import time

host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 5020

start = time.time()
while time.time() - start < 5.0:
    try:
        with socket.create_connection((host, port), timeout=0.2):
            sys.exit(0)
    except Exception:
        time.sleep(0.05)

sys.exit(1)
