#!/bin/bash
LOCKFILE="/tmp/socat.lock"

# Check for sudo permissions
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo."
    exit 1
fi

# Check if lock file exists
if [ -e "$LOCKFILE" ]; then
    echo "Another instance of socat is already running."
    exit 1
fi

# Create lock file
touch "$LOCKFILE"

# Start socat process
echo -n $(date "+%Y-%m-%d %H:%M:%S")": Enable RPC Bind for NFSv3 server -- result: "
socat -dd UDP-LISTEN:111,fork,reuseaddr,reuseport UDP:127.0.0.1:35111 >>socat.log 2>&1 & 

# Get process ID of socat
SOCAT_PID=$!

# Function to remove lock file on exit
cleanup() {
    rm -f "$LOCKFILE"
}

# Trap exit signals to run cleanup function
trap cleanup EXIT

# Check if socat started successfully
if [ -z "$SOCAT_PID" ]; then
    echo -e "failed to start socat. --"
    exit 1
else
    echo -e "started successfully. --"
fi

# Wait for socat process to complete
# wait "$SOCAT_PID"

