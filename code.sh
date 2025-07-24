#!/bin/bash

DEFAULT_PORT=12345

# Check for core dependencies: openssl, ss, and socat.
for cmd in openssl ss socat; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Core dependency '$cmd' not installed. Please install it." >&2
        # Provide an example for Debian-based systems.
        echo "e.g., sudo apt-get install openssl iproute2 socat" >&2
        exit 1
    fi
done

SUDO_CMD=""
# Check if the script is run as root and set up user home directory correctly.
if [[ "$EUID" -eq 0 ]]; then
    SUDO_CMD="sudo"
    # Find the home directory of the user who invoked sudo.
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
    # Use a secure, user-specific directory for the certificate.
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

# Global variables for process IDs and temporary directories.
TMP_DIR=""
NET_PID=""
RECEIVER_PID=""

# Cleanup function to be called on script exit, interruption, or termination.
function cleanup() {
    tput cnorm # Make cursor visible again.
    # Terminate the networking and receiver background processes.
    [[ -n $NET_PID ]] && kill "$NET_PID" 2>/dev/null
    [[ -n $RECEIVER_PID ]] && kill "$RECEIVER_PID" 2>/dev/null
    # Remove the temporary directory.
    [[ -n $TMP_DIR && -d $TMP_DIR ]] && rm -rf "$TMP_DIR"
    echo -e "\nExiting."
}
# Trap signals to ensure cleanup is always run.
trap cleanup EXIT INT TERM

# Main chat function where user interaction happens.
function start_chat() {
    local peer_name=$1
    local PIPE_TO_NET=$2
    local PIPE_FROM_NET=$3

    tput civis # Make cursor invisible for a cleaner UI.

    # Start a background process (receiver) to read and display incoming messages.
    (
        while read -r line; do
            # Clear the current line before printing the received message.
            echo -ne "\r\033[K"
            case "$line" in
                # For security, all incoming requests are automatically denied.
                REQ_COPY:*)
                    echo "--> Peer tried to send a file. Request automatically denied."
                    echo "RESP_NO" >&3
                    ;;
                REQ_EXEC:*)
                    echo "--> Peer tried to execute a command. Request automatically denied."
                    echo "RESP_NO" >&3
                    ;;
                RESP_OK) echo "--> Peer accepted your request." ;;
                RESP_NO) echo "--> Peer denied your request." ;;
                CMD_OUT:*) echo "[Remote]: ${line#CMD_OUT:}" ;;
                INFO:*) echo "[Info]: ${line#INFO:}" ;;
                *) echo "[$peer_name]: $line" ;;
            esac
            # Re-display the user's prompt.
            echo -n "You: "
        done < "$PIPE_FROM_NET"
    ) &
    RECEIVER_PID=$!

    # Open the outgoing pipe on file descriptor 3.
    # This keeps the pipe open so socat doesn't exit prematurely.
    exec 3>"$PIPE_TO_NET"

    # Main loop to read user input from the terminal.
    while true; do
        read -e -p "You: " msg || break

        # Block the '/live' command as it's disabled.
        if [[ "$msg" == "/live"* ]]; then
            echo "Error: /live command is disabled in this version."
            continue
        fi

        # Handle outgoing special commands.
        if [[ "$msg" == /copy* || "$msg" == /exec* ]]; then
            # Format the request and send it through the pipe.
            echo "REQ_$(echo "$msg" | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]'):$(echo -n "${msg#* }" | base64 -w0)" >&3
            echo "--> Sent request: $msg"
            continue
        fi

        if [[ "$msg" == "exit" ]]; then
            break
        fi

        # Send regular chat messages to the peer.
        echo "$msg" >&3
    done

    # Cleanly close the file descriptor and terminate the receiver process.
    exec 3>&-
    kill "$RECEIVER_PID" 2>/dev/null
    wait "$RECEIVER_PID" 2>/dev/null
    tput cnorm
}

# Function to run the script in server mode.
function server_mode() {
    local port_arg=$1
    PORT=${port_arg:-$DEFAULT_PORT}

    local cert_file
    cert_file=$(generate_cert)

    # Main server loop to handle one client at a time.
    while true; do
        TMP_DIR=$(mktemp -d "/tmp/chattr2.server.$$.XXXXXX")
        local PIPE_FROM_NET="$TMP_DIR/from_net"
        local PIPE_TO_NET="$TMP_DIR/to_net"
        mkfifo "$PIPE_FROM_NET" "$PIPE_TO_NET"

        echo "Starting server on port $PORT using socat... (Ctrl+C to stop)"

        # FIX: Removed 'fork' to ensure only ONE client is handled at a time.
        # This was the main source of instability and bugs.
        $SUDO_CMD socat OPENSSL-LISTEN:"$PORT",cert="$cert_file",key="$cert_file",verify=0,reuseaddr \
            < "$PIPE_TO_NET" > "$PIPE_FROM_NET" 2>/dev/null &
        NET_PID=$!

        echo "Waiting for a client to connect..."
        # Wait until a connection is established before proceeding.
        until ss -tnp | grep -q "$NET_PID.*ESTAB"; do
            # Check if the socat process failed to start (e.g., port in use).
            if ! ps -p $NET_PID > /dev/null; then
                echo "Server process failed. Is port $PORT already in use?" >&2
                break 2 # Break out of both the 'until' and 'while' loops.
            fi
            sleep 0.5
        done

        # Check if the inner loop was broken due to an error.
        if ! ps -p $NET_PID > /dev/null; then
            continue
        fi

        echo "Client connected. Type /help for commands or 'exit' to end session."
        start_chat "Client" "$PIPE_TO_NET" "$PIPE_FROM_NET"

        # Clean up after the session ends.
        kill "$NET_PID" 2>/dev/null
        wait "$NET_PID" 2>/dev/null
        rm -rf "$TMP_DIR"
        echo "Session ended. Waiting for a new connection."
        sleep 1
    done
}

# Function to run the script in client mode.
function client_mode() {
    local server_ip=$1
    local port_arg=$2
    PORT=${port_arg:-$DEFAULT_PORT}

    TMP_DIR=$(mktemp -d "/tmp/chattr2.client.$$.XXXXXX")
    local PIPE_FROM_NET="$TMP_DIR/from_net"
    local PIPE_TO_NET="$TMP_DIR/to_net"
    mkfifo "$PIPE_FROM_NET" "$PIPE_TO_NET"

    echo "Connecting to $server_ip:$PORT using socat..."

    # Use socat to establish an SSL connection to the server.
    socat OPENSSL-CONNECT:"$server_ip:$PORT",verify=0 \
        < "$PIPE_TO_NET" > "$PIPE_FROM_NET" 2>/dev/null &
    NET_PID=$!

    # Wait briefly and check if the connection was successful.
    sleep 2
    if ! ps -p "$NET_PID" > /dev/null; then
        echo "Connection failed. Is the server running at $server_ip:$PORT?" >&2
        rm -rf "$TMP_DIR"
        exit 1
    fi

    echo "Connected to server. Type /help for commands or 'exit' to disconnect."
    start_chat "Server" "$PIPE_TO_NET" "$PIPE_FROM_NET"

    # Cleanup is handled by the trap.
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
