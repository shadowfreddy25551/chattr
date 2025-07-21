#!/bin/bash

DEFAULT_PORT=12345

# Added 'socat' to the list of required dependencies
for cmd in openssl ss socat; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Core dependency '$cmd' not installed. Please install it." >&2
        echo "e.g., sudo apt-get install socat" >&2
        exit 1
    fi
done

SUDO_CMD=""
# Logic to handle sudo and home directory remains the same
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
/copy <local_file> [remote_path] - send file
/exec <command...>               - execute command on peer
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

TMP_DIR=""
NET_PID="" # Renamed from OPENSSL_PID
RECEIVER_PID=""

function cleanup() {
    tput cnorm
    # Kill the network process (now socat) and the receiver
    [[ -n $NET_PID ]] && kill "$NET_PID" 2>/dev/null
    [[ -n $RECEIVER_PID ]] && kill "$RECEIVER_PID" 2>/dev/null
    [[ -n $TMP_DIR && -d $TMP_DIR ]] && rm -rf "$TMP_DIR"
    echo -e "\nExiting."
}
trap cleanup EXIT INT TERM

function start_chat() {
    local peer_name=$1
    local net_pid=$2
    # Use clearer pipe names passed from the parent function
    local PIPE_TO_NET=$3
    local PIPE_FROM_NET=$4

    tput civis

    # Receiver reads messages from the network via PIPE_FROM_NET
    (
        while read -r line; do
            echo -ne "\r\033[K"
            case "$line" in
                REQ_COPY:*)
                    echo "--> Incoming file request. Auto-denied."
                    echo "RESP_NO" >&3
                    ;;
                REQ_EXEC:*)
                    echo "--> Incoming exec request. Auto-denied."
                    echo "RESP_NO" >&3
                    ;;
                RESP_OK) echo "--> Peer accepted your request." ;;
                RESP_NO) echo "--> Peer denied your request." ;;
                CMD_OUT:*)
                    echo "[Remote]: ${line#CMD_OUT:}"
                    ;;
                INFO:*)
                    echo "[Info]: ${line#INFO:}"
                    ;;
                *)
                    echo "[$peer_name]: $line"
                    ;;
            esac
            echo -n "You: "
        done < "$PIPE_FROM_NET"
    ) &
    RECEIVER_PID=$!

    # Open PIPE_TO_NET on file descriptor 3. This is crucial as it keeps the pipe open.
    exec 3>"$PIPE_TO_NET"

    while true; do
        read -e -p "You: " msg || break

        if [[ "$msg" == "/live"* ]]; then
            echo "Error: /live command disabled in this version."
            continue
        fi

        if [[ "$msg" == /copy* || "$msg" == /exec* ]]; then
            echo "REQ_$(echo "$msg" | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]'):$(echo -n "${msg#* }" | base64 -w0)" >&3
            echo "--> Sent request: $msg"
            continue
        fi

        if [[ "$msg" == "exit" ]]; then
            break
        fi

        # Send plain messages directly to the network pipe
        echo "$msg" >&3
    done

    exec 3>&- # Close the file descriptor
    kill "$RECEIVER_PID" 2>/dev/null
    wait "$RECEIVER_PID" 2>/dev/null
    tput cnorm
}

function server_mode() {
    local port_arg=$1
    PORT=${port_arg:-$DEFAULT_PORT}

    local cert_file
    cert_file=$(generate_cert)

    while true; do
        TMP_DIR=$(mktemp -d "/tmp/chattr2.server.$$.XXXXXX")
        # Clearer pipe names
        local PIPE_FROM_NET="$TMP_DIR/from_net"
        local PIPE_TO_NET="$TMP_DIR/to_net"
        mkfifo "$PIPE_FROM_NET" "$PIPE_TO_NET"

        echo "Starting server on port $PORT using socat... (Ctrl+C to stop)"

        # Use socat for a robust, bidirectional SSL server.
        # It reads from PIPE_TO_NET and writes to PIPE_FROM_NET.
        $SUDO_CMD socat OPENSSL-LISTEN:"$PORT",cert="$cert_file",key="$cert_file",verify=0,fork,reuseaddr \
            < "$PIPE_TO_NET" > "$PIPE_FROM_NET" 2>/dev/null &
        NET_PID=$!

        echo "Waiting for client..."
        until ss -tnp | grep -q "$NET_PID.*ESTAB"; do
            if ! ps -p $NET_PID > /dev/null; then
                echo "Socat server process exited unexpectedly. Is port $PORT in use?" >&2
                break 2
            fi
            sleep 0.5
        done

        echo "Client connected. Type /help or exit."

        start_chat "Client" "$NET_PID" "$PIPE_TO_NET" "$PIPE_FROM_NET"

        kill "$NET_PID" 2>/dev/null
        wait "$NET_PID" 2>/dev/null
        rm -rf "$TMP_DIR"
        echo "Session ended. Waiting for new connection."
        sleep 1
    done
}

function client_mode() {
    local server_ip=$1
    local port_arg=$2
    PORT=${port_arg:-$DEFAULT_PORT}

    TMP_DIR=$(mktemp -d "/tmp/chattr2.client.$$.XXXXXX")
    local PIPE_FROM_NET="$TMP_DIR/from_net"
    local PIPE_TO_NET="$TMP_DIR/to_net"
    mkfifo "$PIPE_FROM_NET" "$PIPE_TO_NET"

    echo "Connecting to $server_ip:$PORT using socat..."

    # Use socat for a robust client connection.
    # It reads from PIPE_TO_NET and writes to PIPE_FROM_NET.
    socat OPENSSL-CONNECT:"$server_ip:$PORT",verify=0 \
        < "$PIPE_TO_NET" > "$PIPE_FROM_NET" 2>/dev/null &
    NET_PID=$!

    # Allow time for connection to establish or fail
    sleep 1
    if ! ps -p "$NET_PID" > /dev/null; then
        echo "Connection failed. Is the server running at $server_ip:$PORT?" >&2
        rm -rf "$TMP_DIR"
        exit 1
    fi

    echo "Connected. Type /help or exit."
    start_chat "Server" "$NET_PID" "$PIPE_TO_NET" "$PIPE_FROM_NET"

    kill "$NET_PID" 2>/dev/null
    wait "$NET_PID" 2>/dev/null
    rm -rf "$TMP_DIR"
}

# Main script logic remains the same
case "$1" in
    server) server_mode "${@:2}" ;;
    client)
        if [[ -z "$2" ]]; then
            echo "Error: Missing server IP." >&2
            show_help
            exit 1
        fi
        client_mode "${@:2}"
        ;;
    --help|-h) show_help ;;
    *)
        echo "Error: Invalid command '$1'."
        show_help
        exit 1
        ;;
esac
