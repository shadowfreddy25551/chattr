#!/bin/bash

DEFAULT_PORT=12345

# Check dependencies
for cmd in openssl socat ss; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Core dependency '$cmd' not installed. Please install it." >&2
        echo "e.g., sudo apt-get install socat openssl iproute2" >&2
        exit 1
    fi
done

SUDO_CMD=""
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

function show_help() {
    cat <<EOF
Usage:
  chattr2 server [port]
  chattr2 client <ip> [port]
  chattr2 --help

Commands:
/copy <local_file> [remote_path] - send file (disabled)
/exec <command...>               - execute command on peer (disabled)
/help                           - show this help
exit                           - quit chat

Note: /live command disabled in this version.
EOF
}

function generate_cert() {
    local cert_dir="/tmp/chattr2_certs"
    mkdir -p "$cert_dir"
    local cert_path="$cert_dir/chattr2_server.pem"
    if [[ ! -f "$cert_path" ]]; then
        echo "Generating self-signed certificate..."
        openssl req -newkey rsa:2048 -nodes -keyout "$cert_path" -x509 -days 365 -out "$cert_path" -subj "/CN=chattr2.local" &>/dev/null
    fi
    echo "$cert_path"
}

NET_PID=""
READER_PID=""

function cleanup() {
    tput cnorm
    [[ -n $NET_PID ]] && kill "$NET_PID" 2>/dev/null
    [[ -n $READER_PID ]] && kill "$READER_PID" 2>/dev/null
    echo -e "\nExiting."
}
trap cleanup EXIT INT TERM

# Start interactive chat over given socat fifo
# Arguments: $1 = socat stdio file descriptor (named pipe or pty)
# $2 = peer label for display
function start_chat() {
    local socat_fd=$1
    local peer=$2

    tput civis
    echo "Type /help for commands, 'exit' to quit."

    # Read from socat_fd in background and display incoming messages
    {
        while IFS= read -r line <&"$socat_fd"; do
            echo -ne "\r\033[K" # Clear input line
            case "$line" in
                REQ_COPY:*)
                    echo "--> Incoming file request. Auto-denied."
                    # No response mechanism here; ignoring
                    ;;
                REQ_EXEC:*)
                    echo "--> Incoming exec request. Auto-denied."
                    ;;
                RESP_OK)
                    echo "--> Peer accepted your request."
                    ;;
                RESP_NO)
                    echo "--> Peer denied your request."
                    ;;
                CMD_OUT:*)
                    echo "[Remote]: ${line#CMD_OUT:}"
                    ;;
                INFO:*)
                    echo "[Info]: ${line#INFO:}"
                    ;;
                *)
                    echo "[$peer]: $line"
                    ;;
            esac
            echo -n "You: "
        done
    } &
    READER_PID=$!

    # Main input loop to send messages to socat
    while true; do
        echo -n "You: "
        if ! IFS= read -r msg; then
            break
        fi

        # Commands handling
        if [[ "$msg" == "/live"* ]]; then
            echo "Error: /live command disabled in this version."
            continue
        fi

        if [[ "$msg" == /copy* || "$msg" == /exec* ]]; then
            # Disabled in this version, but keeping protocol
            echo "REQ_$(echo "$msg" | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]'):$(echo -n "${msg#* }" | base64 -w0)" >&"$socat_fd"
            echo "--> Sent request: $msg"
            continue
        fi

        if [[ "$msg" == "exit" ]]; then
            break
        fi

        # Send plain message
        echo "$msg" >&"$socat_fd"
    done

    kill "$READER_PID" 2>/dev/null
    wait "$READER_PID" 2>/dev/null
    tput cnorm
}

function server_mode() {
    local port=${1:-$DEFAULT_PORT}
    local cert_file
    cert_file=$(generate_cert)

    echo "Starting server on port $port..."

    # To allow only one client at a time, run socat without fork
    # It will listen on TCP, use SSL, and output to a pty (virtual tty)
    TMP_DIR=$(mktemp -d "/tmp/chattr2_server.$$.XXXXXX")
    local socat_pty="$TMP_DIR/pty"

    # Start socat to listen on SSL port and bind its I/O to a pty
    $SUDO_CMD socat OPENSSL-LISTEN:"$port",cert="$cert_file",key="$cert_file",verify=0,reuseaddr,bind=0 \
        PTY,link="$socat_pty",raw,echo=0 &

    NET_PID=$!

    # Wait for pty file to exist (means client connected)
    echo "Waiting for client to connect..."
    while [[ ! -e "$socat_pty" ]]; do
        if ! kill -0 "$NET_PID" 2>/dev/null; then
            echo "Socat server process exited unexpectedly." >&2
            rm -rf "$TMP_DIR"
            exit 1
        fi
        sleep 0.2
    done

    echo "Client connected. Starting chat."

    # Open the pty for both reading and writing using exec and file descriptors
    exec 3<> "$socat_pty"

    start_chat 3 "Client"

    # Clean up after client disconnects or exit
    kill "$NET_PID" 2>/dev/null
    wait "$NET_PID" 2>/dev/null
    exec 3>&-
    exec 3<&-
    rm -rf "$TMP_DIR"

    echo "Client disconnected. Server stopping."
}

function client_mode() {
    local server_ip=$1
    local port=${2:-$DEFAULT_PORT}

    echo "Connecting to $server_ip:$port..."

    TMP_DIR=$(mktemp -d "/tmp/chattr2_client.$$.XXXXXX")
    local socat_pty="$TMP_DIR/pty"

    # Start socat to connect to server SSL port and bind to a pty
    socat OPENSSL-CONNECT:"$server_ip:$port",verify=0 \
        PTY,link="$socat_pty",raw,echo=0 &

    NET_PID=$!

    # Wait for pty to appear (means connected)
    local wait_count=0
    while [[ ! -e "$socat_pty" ]]; do
        if ! kill -0 "$NET_PID" 2>/dev/null; then
            echo "Connection failed or server unreachable." >&2
            rm -rf "$TMP_DIR"
            exit 1
        fi
        sleep 0.2
        ((wait_count++))
        if ((wait_count > 50)); then
            echo "Timeout waiting for connection." >&2
            kill "$NET_PID" 2>/dev/null
            rm -rf "$TMP_DIR"
            exit 1
        fi
    done

    echo "Connected. Starting chat."

    # Open the pty for reading and writing
    exec 3<> "$socat_pty"

    start_chat 3 "Server"

    kill "$NET_PID" 2>/dev/null
    wait "$NET_PID" 2>/dev/null
    exec 3>&-
    exec 3<&-
    rm -rf "$TMP_DIR"

    echo "Disconnected from server."
}

case "$1" in
    server)
        server_mode "${2:-$DEFAULT_PORT}"
        ;;
    client)
        if [[ -z "$2" ]]; then
            echo "Error: Missing server IP." >&2
            show_help
            exit 1
        fi
        client_mode "$2" "${3:-$DEFAULT_PORT}"
        ;;
    --help|-h)
        show_help
        ;;
    *)
        echo "Error: Invalid command '$1'."
        show_help
        exit 1
        ;;
esac
