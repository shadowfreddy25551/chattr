#!/bin/bash

# chattr2 - simple secure chat using openssl s_server and s_client
# This version uses robust named pipes (mkfifo) for IPC instead of coproc.

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

# Define pipe paths using the script's Process ID ($$) to ensure they are unique
PIPE_IN="/tmp/chattr2_in_$$"
PIPE_OUT="/tmp/chattr2_out_$$"

# This global cleanup function is called when the script is force-closed (Ctrl+C)
function cleanup() {
    # Kill any running background processes by their PID
    if [[ -n "$openssl_pid" ]]; then kill "$openssl_pid" &>/dev/null; fi
    if [[ -n "$receiver_pid" ]]; then kill "$receiver_pid" &>/dev/null; fi
    # Remove the named pipes
    rm -f "$PIPE_IN" "$PIPE_OUT"
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

    # Main server loop to allow reconnects
    while true; do
        # Create the named pipes for this session
        mkfifo "$PIPE_IN" "$PIPE_OUT"

        echo "Starting chattr2 server on port $PORT..."
        echo "Waiting for a client to connect... (Ctrl+C to stop server)"

        # Start OpenSSL server in the background.
        # It reads from PIPE_IN and writes to PIPE_OUT.
        # The <"$PIPE_IN" is crucial; it blocks until the 'cat' on the other end starts.
        openssl s_server -accept "$PORT" -cert "$cert_file" -quiet < "$PIPE_IN" > "$PIPE_OUT" &
        openssl_pid=$!

        echo "Client connected. You can start chatting. (Type 'exit' or Ctrl+D to disconnect)"
        tput civis # Hide cursor

        # Receiver: Read from PIPE_OUT and display messages from the client
        (cat "$PIPE_OUT" | while read -r line; do
            echo -e "\r\033[KClient: $line"
            echo -n "You: "
        done; echo -e "\nClient disconnected. Waiting for new connection...") &
        receiver_pid=$!

        # Sender: Read user input and write it to PIPE_IN
        echo -n "You: "
        while read -r -e msg; do
            if [[ "$msg" == "exit" ]]; then break; fi
            # Check if the openssl process is still alive before writing
            if ! ps -p $openssl_pid > /dev/null; then break; fi
            echo "$msg" > "$PIPE_IN"
            echo -n "You: "
        done

        # Client disconnected, kill the processes for this session and clean up pipes
        kill "$openssl_pid" "$receiver_pid" &>/dev/null
        rm -f "$PIPE_IN" "$PIPE_OUT"
        tput cnorm # Restore cursor
    done
}

function client_mode() {
    local server_ip=$1
    local port_arg=$2
    if [[ -n $port_arg && $port_arg =~ ^[0-9]+$ ]]; then
        PORT=$port_arg
    fi

    # Create pipes for the client
    mkfifo "$PIPE_IN" "$PIPE_OUT"

    echo "Connecting to $server_ip:$PORT ..."
    # Start OpenSSL client in the background
    openssl s_client -connect "$server_ip:$PORT" -quiet -crlf < "$PIPE_IN" > "$PIPE_OUT" 2>/dev/null &
    openssl_pid=$!

    sleep 0.5
    if ! ps -p $openssl_pid > /dev/null; then
       echo "Connection failed. Is the server running at that IP/port?" >&2
       exit 1
    fi

    echo "Connected. You can start chatting. (Type 'exit' or Ctrl+D to disconnect)"
    tput civis

    # Receiver: Read from PIPE_OUT and display messages from the server
    (cat "$PIPE_OUT" | while read -r line; do
        echo -e "\r\033[KServer: $line"
        echo -n "You: "
    done; echo -e "\nServer disconnected.") &
    receiver_pid=$!

    # Sender: Read user input and write it to PIPE_IN
    echo -n "You: "
    while read -r -e msg; do
        if [[ "$msg" == "exit" ]]; then break; fi
        if ! ps -p $openssl_pid > /dev/null; then break; fi
        echo "$msg" > "$PIPE_IN"
        echo -n "You: "
    done
    
    # Exiting, cleanup is handled by the main trap
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
