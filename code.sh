#!/bin/bash

# chattr - simple secure chat using openssl s_server and s_client
# Usage:
#   Server mode: ./code.sh server [port]
#   Client mode: ./code.sh client <server_ip> [port]

PORT=${2:-12345}

function generate_cert() {
    # Create self-signed cert/key if missing
    if [[ ! -f server.pem ]]; then
        echo "Generating self-signed cert (server.pem)..."
        openssl req -newkey rsa:2048 -nodes -keyout key.pem -x509 -days 365 -out server.pem \
            -subj "/CN=chattr-server"
        cat key.pem >> server.pem
        rm key.pem
    fi
}

function server_mode() {
    generate_cert
    echo "Starting chattr server on port $PORT..."
    openssl s_server -accept "$PORT" -cert server.pem -quiet | while read -r line; do
        echo "Client: $line"
        echo -n "You: "
        read -r msg
        echo "$msg"
    done
}

function client_mode() {
    SERVER="$1"
    echo "Connecting to $SERVER:$PORT ..."
    openssl s_client -connect "$SERVER:$PORT" -quiet 2>/dev/null | while read -r line; do
        echo "Server: $line"
        echo -n "You: "
        read -r msg
        echo "$msg"
    done
}

if [[ "$1" == "server" ]]; then
    server_mode
elif [[ "$1" == "client" && -n "$2" ]]; then
    client_mode "$2"
else
    echo "Usage:"
    echo "  $0 server [port]"
    echo "  $0 client <server_ip> [port]"
    exit 1
fi
