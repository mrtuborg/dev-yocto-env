#!/bin/bash

LOCKFILE="/tmp/socat.lock"

# Check for sudo permissions
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo."
    exit 1
fi

# Check if lock file exists
if [ ! -e "$LOCKFILE" ]; then
    echo "No running instance of socat found."
    exit 1
fi

# Get the PID of the running socat process
SOCAT_PID=$(sudo pgrep socat)

# Kill the socat process
if [ -n "$SOCAT_PID" ]; then
    kill "$SOCAT_PID"
else
    echo "No socat process found."
    exit 1
fi

# Remove lock file
rm -f "$LOCKFILE"

# Check the return value
echo -n $(date "+%d-%m-%Y %H:%M:%S")": Enable RPC Bind for NFSv3 server -- result: "
if [ $? -eq 0 ]; then
    echo "stopped successfully. --"
else
    echo "could not be stopped. --"
fi