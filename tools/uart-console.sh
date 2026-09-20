#!/bin/sh
set -eu

# Keep raw RGOS console logs outside the repository: normal Wi-Fi activity can
# print transient key material.  A restrictive umask protects newly made logs.
umask 077

device=${1:-/dev/ttyUSB0}
timestamp=$(date +%Y%m%d-%H%M%S)
log_file=${2:-/tmp/rg-ma2820-uart-$timestamp.log}

if [ ! -c "$device" ]; then
	echo "UART device is not a character device: $device" >&2
	exit 1
fi

echo "UART: $device (115200 8N1, no flow control)"
echo "Log:  $log_file (mode 0600; do not commit raw logs)"
echo "Exit picocom with Ctrl-A, then Ctrl-X."

exec sudo picocom --baud 115200 --flow n --parity n --databits 8 \
	--stopbits 1 --lower-dtr --lower-rts --logfile "$log_file" "$device"
