#!/bin/bash

# chattr - simple secure chat using openssl s_server and s_client
# Usage:
#   chattr server [port]
#   chattr client <server_ip> [port]
#   chattr --help

DEFAULT_PORT=12345
PORT=$DEFAULT_PORT

function show_help() {
    cat <<EOF
chattr - Simple secure chat between two PCs

Usage:
  chattr server [port]              Start chat server on [port] (default: $DEFAULT_PORT)
  chattr client <server_ip> [port] Connect to server at <server_ip> on [port] (default: $DEFAULT_PORT)
  chattr --help                    Show this help message and exit
EOF
}

function generate_cert() {
    if [[ ! -f server.pem ]]; then
        echo "Generating self-signed cert (server.pem)..."
        openssl req -newkey rsa:2048 -nodes -keyout key.pem -x509 -days 365 -out server.pem \
            -subj "/CN=chattr-server"
        cat key.pem >> server.pem
        rm key.pem
    fi
}

function server_mode() {
    # Use second argument as port or default
    local port_arg=$2
    if [[ -n $port_arg && $port_arg =~ ^[0-9]+$ ]]; then
        PORT=$port_arg
    fi

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
    local server_ip=$1
    local port_arg=$2

    if [[ -n $port_arg && $port_arg =~ ^[0-9]+$ ]]; then
        PORT=$port_arg
    fi

    echo "Connecting to $server_ip:$PORT ..."
    openssl s_client -connect "$server_ip:$PORT" -quiet 2>/dev/null | while read -r line; do
        echo "Server: $line"
        echo -n "You: "
        read -r msg
        echo "$msg"
    done
}

case "$1" in
    server)
        server_mode "$@"
        ;;
    client)
        if [[ -z "$2" ]]; then
            echo "Error: Missing server IP."
            show_help
            exit 1
        fi
        client_mode "${@:2}"
        ;;
    --help|-h)
        show_help
        ;;
    *)
        echo "Invalid or missing command."
        show_help
        exit 1
        ;;
esac
