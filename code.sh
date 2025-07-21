#!/bin/bash

# chattr2 - simple secure chat using openssl s_server and s_client
# Usage:
#   chattr2 server [port] [--nosudo]
#   chattr2 client <server_ip> [port] [--nosudo]
#   chattr2 --help

DEFAULT_PORT=12345
PORT=$DEFAULT_PORT

# --- Sudo Check ---
nosudo_flag=false
new_args=()
for arg in "$@"; do
    if [[ "$arg" == "--nosudo" ]]; then
        nosudo_flag=true
    else
        new_args+=("$arg")
    fi
done

if [[ "$nosudo_flag" == true ]]; then
    set -- "${new_args[@]}"
elif [[ "$EUID" -ne 0 ]]; then
    echo "Error: This script must be run with root privileges." >&2
    echo "Please use 'sudo chattr2 ...' or add the '--nosudo' flag to run without root." >&2
    exit 1
fi
# --- End Sudo Check ---

function show_help() {
    cat <<EOF
chattr2 - Simple secure chat between two PCs

Usage:
  chattr2 server [port] [--nosudo]     Start chat server on [port] (default: $DEFAULT_PORT)
  chattr2 client <ip> [port] [--nosudo] Connect to server at <ip> on [port] (default: $DEFAULT_PORT)
  chattr2 --help                       Show this help message and exit

The --nosudo flag allows running without root privileges.
EOF
}

function generate_cert() {
    local cert_path="/tmp/chattr2_server.pem"
    if [[ ! -f "$cert_path" ]]; then
        echo "Generating self-signed cert in $cert_path..." >&2
        local key_path="/tmp/chattr2_key.pem"
        openssl req -newkey rsa:2048 -nodes -keyout "$key_path" -x509 -days 365 -out "$cert_path" \
            -subj "/CN=chattr2-server" &>/dev/null
        cat "$key_path" >> "$cert_path"
        rm "$key_path"
    fi
    echo "$cert_path"
}

# This global cleanup function is called when the script is force-closed (Ctrl+C)
function cleanup() {
    # Kill any running background processes
    if [[ -n "$coproc_pid" ]]; then kill "$coproc_pid" &>/dev/null; fi
    if [[ -n "$receiver_pid" ]]; then kill "$receiver_pid" &>/dev/null; fi
    tput cnorm # Ensure cursor is visible
    echo -e "\nExiting."
}
trap cleanup EXIT

function server_mode() {
    local port_arg=$1
    if [[ -n $port_arg && $port_arg =~ ^[0-9]+$ ]]; then
        PORT=$port_arg
    fi

    local cert_file
    cert_file=$(generate_cert)

    # This is the main server loop. It allows the server to accept new clients after one disconnects.
    while true; do
        echo "Starting chattr2 server on port $PORT..."
        echo "Waiting for a client to connect... (Ctrl+C to stop server)"

        # Start OpenSSL server in a coprocess. It will wait here until a client connects.
        coproc COPROC_SERVER { openssl s_server -accept "$PORT" -cert "$cert_file" -quiet; }
        coproc_pid=$COPROC_SERVER_PID

        # Give the process a moment to start and fail if the port is busy
        sleep 0.2
        if ! ps -p $coproc_pid > /dev/null; then
           echo "Error: Server failed to start. Is port $PORT already in use?" >&2
           exit 1
        fi

        echo "Client connected. You can start chatting. (Type 'exit' or Ctrl+D to disconnect)"
        tput civis # Hide cursor for cleaner chat

        # Receiver loop (runs in background to listen for messages)
        # When the client disconnects, 'read' fails, the loop ends, and a message is printed.
        (while read -r -u "${COPROC_SERVER[0]}" line; do
            echo -e "\r\033[KClient: $line"
            echo -n "You: "
        done; echo -e "\nClient disconnected. Waiting for new connection...") &
        receiver_pid=$!

        # Sender loop (reads your input and sends it to the client)
        echo -n "You: "
        while read -r -e msg; do
            # If the receiver process has died, it means the client disconnected. Break the loop.
            if ! ps -p $receiver_pid > /dev/null; then break; fi
            if [[ "$msg" == "exit" ]]; then break; fi

            echo "$msg" >&"${COPROC_SERVER[1]}"
            echo -n "You: "
        done

        # The loop has ended, so the client is disconnected. Kill all related processes for this session.
        kill "$coproc_pid" &>/dev/null
        kill "$receiver_pid" &>/dev/null
        tput cnorm # Restore cursor
    done
}

function client_mode() {
    local server_ip=$1
    local port_arg=$2

    if [[ -n $port_arg && $port_arg =~ ^[0-9]+$ ]]; then
        PORT=$port_arg
    fi

    echo "Connecting to $server_ip:$PORT ..."
    coproc COPROC_CLIENT { openssl s_client -connect "$server_ip:$PORT" -quiet -crlf 2>/dev/null; }
    coproc_pid=$COPROC_CLIENT_PID

    sleep 0.2
    if ! ps -p $coproc_pid > /dev/null; then
       echo "Connection failed. Is the server running at that IP/port?" >&2
       exit 1
    fi

    echo "Connected. You can start chatting. (Type 'exit' or Ctrl+D to disconnect)"
    tput civis

    (while read -r -u "${COPROC_CLIENT[0]}" line; do
        echo -e "\r\033[KServer: $line"
        echo -n "You: "
    done; echo -e "\nServer disconnected.") &
    receiver_pid=$!

    echo -n "You: "
    while read -r -e msg; do
        if ! ps -p $receiver_pid > /dev/null; then break; fi
        if [[ "$msg" == "exit" ]]; then break; fi
        echo "$msg" >&"${COPROC_CLIENT[1]}"
        echo -n "You: "
    done
    
    # Client is exiting, clean up its processes
    kill "$coproc_pid" &>/dev/null
    kill "$receiver_pid" &>/dev/null
}

# --- Argument Parsing ---
case "$1" in
    server)
        server_mode "${@:2}"
        ;;
    client)
        if [[ -z "$2" ]]; then
            echo "Error: Missing server IP address." >&2
            show_help
            exit 1
        fi
        client_mode "${@:2}"
        ;;
    --help|-h)
        show_help
        ;;
    ""|*)
        if [[ -n "$1" ]]; then
             echo "Error: Invalid command '$1'." >&2
        fi
        show_help
        exit 1
        ;;
esac
