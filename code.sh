#!/bin/bash

DEFAULT_PORT=12345

# Check for core dependencies: openssl, ss, and socat.
for cmd in openssl ss socat; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Core dependency '$cmd' not installed. Please install it." >&2
        echo "e.g., sudo apt-get install openssl iproute2 socat" >&2
        exit 1
    fi
done

SUDO_CMD=""
# Determine home directory for certificate storage, even when run with sudo.
if [[ "$EUID" -eq 0 ]]; then
    SUDO_CMD="sudo"
    if [[ -n "$SUDO_USER" ]]; then
        LOCAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        LOCAL_HOME=$HOME
    fi
else
    LOCAL_HOME=$HOME
fi

# Function to display help information.
function show_help() {
    cat <<EOF
Usage:
  chattr2 server [port]
  chattr2 client <ip> [port]
  chattr2 --help

Commands:
/copy <local_file> [remote_path] - Send file (disabled, auto-denied)
/exec <command...>               - Execute command on peer (disabled, auto-denied)
/help                           - Show this help
exit                           - Quit the chat session

Note: The /live command is disabled in this version.
EOF
}

# Function to generate a self-signed SSL certificate for the server.
function generate_cert() {
    local cert_dir="$LOCAL_HOME/.chattr2/certs"
    mkdir -p "$cert_dir"
    local cert_path="$cert_dir/chattr2_server.pem"
    # Generate the certificate only if it doesn't already exist.
    if [[ ! -f "$cert_path" ]]; then
        echo "Generating a new self-signed certificate..."
        openssl req -newkey rsa:2048 -nodes -keyout "$cert_path" -x509 -days 365 -out "$cert_path" -subj "/CN=chattr2.local" &>/dev/null
    fi
    echo "$cert_path"
}

# General cleanup trap for Ctrl+C interruptions.
trap 'tput cnorm; echo -e "\nInterrupted. Exiting."; exit 1' INT

# The core chat function, rewritten using `coproc` for stability.
# It takes the peer's name and the socat command as arguments.
function start_chat() {
    local peer_name=$1
    shift
    local socat_cmd=("$@")

    # Start socat as a coprocess. Bash handles the pipes.
    # NET[0] is for reading from socat, NET[1] is for writing to socat.
    coproc NET "${socat_cmd[@]}"

    # Ensure all child processes are killed on function exit.
    local receiver_pid
    trap 'kill "${NET_PID}" "$receiver_pid" 2>/dev/null; tput cnorm' RETURN

    # Make the cursor invisible for a cleaner UI.
    tput civis

    # Asynchronous receiver loop: reads from socat and prints to screen.
    (
        while IFS= read -r line; do
            # Clear the current line before printing the received message.
            echo -ne "\r\033[K"
            case "$line" in
                # For security, all incoming requests are automatically denied.
                REQ_COPY:*)
                    echo "--> Peer tried to send a file. Request automatically denied."
                    echo "RESP_NO" >&"${NET[1]}"
                    ;;
                REQ_EXEC:*)
                    echo "--> Peer tried to execute a command. Request automatically denied."
                    echo "RESP_NO" >&"${NET[1]}"
                    ;;
                RESP_OK) echo "--> Peer accepted your request." ;;
                RESP_NO) echo "--> Peer denied your request." ;;
                CMD_OUT:*) echo "[Remote]: ${line#CMD_OUT:}" ;;
                INFO:*) echo "[Info]: ${line#INFO:}" ;;
                *) echo "[$peer_name]: $line" ;;
            esac
            # Re-display the user's prompt.
            echo -n "You: "
        done <&"${NET[0]}"

        # If the loop ends, the connection was closed by the peer.
        # We kill the main script process to exit cleanly.
        echo -e "\r\033[K[Info]: Connection closed by peer. Exiting."
        kill $$
    ) &
    receiver_pid=$!

    # Main input loop: reads from user and writes to socat.
    while read -e -p "You: " msg; do
        if [[ "$msg" == "/live"* ]]; then
            echo "Error: /live command is disabled in this version."
            continue
        fi

        if [[ "$msg" == /copy* || "$msg" == /exec* ]]; then
            echo "REQ_$(echo "$msg" | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]'):$(echo -n "${msg#* }" | base64 -w0)" >&"${NET[1]}"
            echo "--> Sent request: $msg"
            continue
        fi

        if [[ "$msg" == "exit" ]]; then
            break
        fi

        echo "$msg" >&"${NET[1]}"
    done

    # User typed 'exit' or pressed Ctrl+D, loop is broken.
    echo "Disconnecting..."
    # The trap will handle killing the coproc and receiver.
}


# Function to run the script in server mode.
function server_mode() {
    local port_arg=$1
    PORT=${port_arg:-$DEFAULT_PORT}
    local cert_file
    cert_file=$(generate_cert)

    # Main server loop to handle one client at a time.
    while true; do
        echo "Starting server on port $PORT... (Ctrl+C to stop)"
        # Use socat to listen for a single connection.
        # The `start_chat` function is now passed the command to run.
        start_chat "Client" $SUDO_CMD socat OPENSSL-LISTEN:"$PORT",cert="$cert_file",key="$cert_file",verify=0,reuseaddr

        echo "Session ended. Waiting for new connection."
        sleep 1
    done
}

# Function to run the script in client mode.
function client_mode() {
    local server_ip=$1
    local port_arg=$2
    PORT=${port_arg:-$DEFAULT_PORT}

    echo "Connecting to $server_ip:$PORT..."

    # Check if we can connect.
    if ! (</dev/null >/dev/null 2>/dev/null) | socat - OPENSSL-CONNECT:"$server_ip:$PORT",verify=0,connect-timeout=5; then
        echo "Connection failed. Is the server running at $server_ip:$PORT?" >&2
        exit 1
    fi

    echo "Connected. Type 'exit' or press Ctrl+D to disconnect."
    start_chat "Server" socat OPENSSL-CONNECT:"$server_ip:$PORT",verify=0
}

# Main script logic to parse command-line arguments.
case "$1" in
    server) server_mode "${@:2}" ;;
    client)
        if [[ -z "$2" ]]; then
            echo "Error: Missing server IP address for client mode." >&2
            show_help
            exit 1
        fi
        client_mode "${@:2}"
        ;;
    --help|-h) show_help ;;
    *)
        if [[ -n "$1" ]]; then
            echo "Error: Invalid command '$1'."
        fi
        show_help
        exit 1
        ;;
esac
