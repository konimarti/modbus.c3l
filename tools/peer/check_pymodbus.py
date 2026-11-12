import sys

try:
    import pymodbus
    sys.exit(0)
except ImportError:
    sys.exit(1)
