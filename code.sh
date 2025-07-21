#!/bin/bash

# chattr2 - simple secure chat using openssl s_server and s_client
# Usage:
#   chattr2 server [port] [--nosudo]
#   chattr2 client <server_ip> [port] [--nosudo]
#   chattr2 --help

DEFAULT_PORT=12345
PORT=$DEFAULT_PORT

# --- Sudo Check ---
# Check for --nosudo flag
nosudo_flag=false
new_args=()
for arg in "$@"; do
    if [[ "$arg" == "--nosudo" ]]; then
        nosudo_flag=true
    else
        new_args+=("$arg")
    fi
done

# If --nosudo was found, update the script's arguments to remove it
if [[ "$nosudo_flag" == true ]]; then
    set -- "${new_args[@]}"
# If --nosudo was not found, check for root privileges
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
    # Generate cert in /tmp to avoid permission issues and clutter
    local cert_path="/tmp/chattr2_server.pem"
    if [[ ! -f "$cert_path" ]]; then
        # THIS IS THE FIX: Status messages go to stderr (>&2)
        echo "Generating self-signed cert in $cert_path..." >&2
        local key_path="/tmp/chattr2_key.pem"
        # Hide openssl command output
        openssl req -newkey rsa:2048 -nodes -keyout "$key_path" -x509 -days 365 -out "$cert_path" \
            -subj "/CN=chattr2-server" &>/dev/null
        cat "$key_path" >> "$cert_path"
        rm "$key_path"
    fi
    # This is the ONLY thing sent to stdout, so it's all that gets captured
    echo "$cert_path"
}

# This function cleans up background processes on exit
function cleanup() {
    # The >/dev/null check suppresses "kill: no such process" errors
    if [[ -n "$COPROC_PID" ]]; then kill "$COPROC_PID" &>/dev/null; fi
    if [[ -n "$receiver_pid" ]]; then kill "$receiver_pid" &>/dev/null; fi
    # Restore cursor visibility on exit
    tput cnorm
    echo -e "\nConnection closed. Exiting."
}

# Set a trap to call the cleanup function on script exit (e.g., Ctrl+C)
trap cleanup EXIT

function server_mode() {
    local port_arg=$1
    if [[ -n $port_arg && $port_arg =~ ^[0-9]+$ ]]; then
        PORT=$port_arg
    fi

    local cert_file
    # This now correctly captures ONLY the path
    cert_file=$(generate_cert)
    
    echo "Starting chattr2 server on port $PORT..."
    echo "Waiting for a client to connect..."

    # Create a coprocess for the OpenSSL server
    coproc COPROC_SERVER { openssl s_server -accept "$PORT" -cert "$cert_file" -quiet; }

    echo "Client connected. You can start chatting. (Press Ctrl+D or type 'exit' to end)"
    # Hide cursor while typing for cleaner look
    tput civis

    # Receiver loop (runs in the background to listen for messages)
    (while read -r -u "${COPROC_SERVER[0]}" line; do
        # \r\033[K clears the current terminal line before printing the message
        echo -e "\r\033[KClient: $line"
        echo -n "You: "
    done) &
    receiver_pid=$!

    # Sender loop (runs in the foreground to send messages)
    echo -n "You: "
    while read -r -e msg; do
        if [[ "$msg" == "exit" ]]; then break; fi
        echo "$msg" >&"${COPROC_SERVER[1]}"
        echo -n "You: "
    done
}

function client_mode() {
    local server_ip=$1
    local port_arg=$2

    if [[ -n $port_arg && $port_arg =~ ^[0-9]+$ ]]; then
        PORT=$port_arg
    fi

    echo "Connecting to $server_ip:$PORT ..."
    # Create a coprocess for the OpenSSL client
    coproc COPROC_CLIENT { openssl s_client -connect "$server_ip:$PORT" -quiet -crlf 2>/dev/null; }

    # Check if the coprocess started successfully (i.e., connection was made)
    # A small sleep gives the process a moment to fail if it's going to
    sleep 0.2
    if ! ps -p $COPROC_CLIENT_PID > /dev/null; then
       echo "Connection failed. Is the server running at that IP/port?" >&2
       exit 1
    fi

    echo "Connected. You can start chatting. (Press Ctrl+D or type 'exit' to end)"
    tput civis

    # Receiver loop (runs in the background)
    (while read -r -u "${COPROC_CLIENT[0]}" line; do
        echo -e "\r\033[KServer: $line"
        echo -n "You: "
    done) &
    receiver_pid=$!

    # Sender loop (runs in the foreground)
    echo -n "You: "
    while read -r -e msg; do
        if [[ "$msg" == "exit" ]]; then break; fi
        echo "$msg" >&"${COPROC_CLIENT[1]}"
        echo -n "You: "
    done
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
    ""|*) # Handle empty input and invalid commands
        if [[ -n "$1" ]]; then
             echo "Error: Invalid command '$1'." >&2
        fi
        show_help
        exit 1
        ;;
esac
