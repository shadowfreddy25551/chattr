sudo bash chattr2 client 192.168.0.39 0123```

By adding `bash` after `sudo`, you ensure that the script is interpreted by the correct shell, and the `coproc`-based script I provided previously will work as intended.

---

### Solution 2: A More Resilient Script (No `coproc`)

If you cannot or prefer not to change the way you execute the script, I have rewritten it to avoid `coproc`. This version goes back to using manual pipes (`mkfifo`) but includes critical fixes to the process and I/O management to prevent the original instability and disconnection bugs.

This version is more complex internally but should be more robust across different shell environments.

Here is the new, more resilient script:

```bash
#!/bin/bash

DEFAULT_PORT=12345

# Check for core dependencies.
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
    if [[ ! -f "$cert_path" ]]; then
        echo "Generating a new self-signed certificate..."
        openssl req -newkey rsa:2048 -nodes -keyout "$cert_path" -x509 -days 365 -out "$cert_path" -subj "/CN=chattr2.local" &>/dev/null
    fi
    echo "$cert_path"
}

# Global variables for process management.
TMP_DIR=""
NET_PID=""
RECEIVER_PID=""

# Master cleanup function called on script exit.
function cleanup() {
    tput cnorm # Ensure cursor is visible.
    # Kill background processes quietly.
    if [[ -n "$RECEIVER_PID" ]]; then kill "$RECEIVER_PID" 2>/dev/null; fi
    if [[ -n "$NET_PID" ]]; then kill "$NET_PID" 2>/dev/null; fi
    # Clean up the temporary directory.
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then rm -rf "$TMP_DIR"; fi
    echo -e "\nExiting."
}
trap cleanup EXIT INT TERM

# Core chat function, rebuilt for stability with named pipes.
function start_chat() {
    local peer_name=$1
    local PIPE_TO_NET=$2
    local PIPE_FROM_NET=$3

    tput civis # Hide cursor for cleaner UI.

    # Receiver loop runs in the background. It reads from socat's output pipe.
    (
        while IFS= read -r line; do
            # Clear the current line, print the message, and redraw the input prompt.
            echo -ne "\r\033[K"
            case "$line" in
                REQ_COPY:*)
                    echo "--> Peer tried to send a file. Request automatically denied."
                    echo "RESP_NO" > "$PIPE_TO_NET"
                    ;;
                REQ_EXEC:*)
                    echo "--> Peer tried to execute a command. Request automatically denied."
                    echo "RESP_NO" > "$PIPE_TO_NET"
                    ;;
                RESP_OK) echo "--> Peer accepted your request." ;;
                RESP_NO) echo "--> Peer denied your request." ;;
                *) echo "[$peer_name]: $line" ;;
            esac
            echo -n "You: "
        done < "$PIPE_FROM_NET"

        # If this loop ends, the pipe was closed (peer disconnected).
        # Signal the main process to break its read loop and exit.
        echo -e "\r\033[K[Info]: Connection lost. Press [Enter] to exit."
        kill -s USR1 $$
    ) &
    RECEIVER_PID=$!

    # Trap the custom signal to break the input loop gracefully.
    trap 'break' USR1

    # Main input loop reads from the user terminal and writes to socat's input pipe.
    while read -e -p "You: " msg; do
        if [[ "$msg" == "exit" ]]; then
            break
        fi
        if [[ "$msg" == "/live"* || "$msg" == "/copy"* || "$msg" == "/exec"* ]]; then
            echo "Error: Special commands are disabled in this version for stability."
            continue
        fi
        echo "$msg" > "$PIPE_TO_NET"
    done

    # Loop exited. Reset the trap and let the main cleanup handler take over.
    trap - USR1
    tput cnorm
    echo -e "\nDisconnecting..."
}

# Function to run the script in server mode.
function server_mode() {
    local port_arg=$1
    PORT=${port_arg:-$DEFAULT_PORT}
    local cert_file=$(generate_cert)

    while true; do
        TMP_DIR=$(mktemp -d "/tmp/chattr2.server.$$.XXXXXX")
        local PIPE_FROM_NET="$TMP_DIR/from_net"
        local PIPE_TO_NET="$TMP_DIR/to_net"
        mkfifo "$PIPE_FROM_NET" "$PIPE_TO_NET"

        echo "Starting server on port $PORT... (Ctrl+C to stop)"

        # Launch socat in a fully detached subshell.
        ( "$SUDO_CMD" socat OPENSSL-LISTEN:"$PORT",cert="$cert_file",key="$cert_file",verify=0,reuseaddr > "$PIPE_FROM_NET" < "$PIPE_TO_NET" 2>/dev/null ) &
        NET_PID=$!

        echo "Waiting for a client to connect..."
        until ss -tnl "( sport = :$PORT )" | grep -q "LISTEN"; do sleep 1; done
        until ss -tnp | grep -q "$NET_PID.*ESTAB"; do
            if ! ps -p $NET_PID > /dev/null; then
                echo "Server process failed. Is port $PORT already in use?" >&2
                break 2
            fi
            sleep 0.5
        done

        if ! ps -p $NET_PID > /dev/null; then continue; fi

        echo "Client connected. Type 'exit' or press Ctrl+D to end session."
        start_chat "Client" "$PIPE_TO_NET" "$PIPE_FROM_NET"

        # End of session cleanup for the next loop iteration.
        kill "$NET_PID" 2>/dev/null; wait "$NET_PID" 2>/dev/null
        kill "$RECEIVER_PID" 2>/dev/null
        rm -rf "$TMP_DIR"
        echo "Session ended. Waiting for new connection."
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

    echo "Connecting to $server_ip:$PORT..."
    ( socat OPENSSL-CONNECT:"$server_ip:$PORT",verify=0 > "$PIPE_FROM_NET" < "$PIPE_TO_NET" 2>/dev/null ) &
    NET_PID=$!

    sleep 2
    if ! ps -p "$NET_PID" > /dev/null; then
        echo "Connection failed. Is the server running at $server_ip:$PORT?" >&2
        exit 1
    fi

    echo "Connected. Type 'exit' or press Ctrl+D to disconnect."
    start_chat "Server" "$PIPE_TO_NET" "$PIPE_FROM_NET"
}

# Main script logic to parse command-line arguments.
case "$1" in
    server) server_mode "${@:2}" ;;
    client)
        if [[ -z "$2" ]]; then
            echo "Error: Missing server IP address for client mode." >&2
            show_help; exit 1
        fi
        client_mode "${@:2}"
        ;;
    --help|-h) show_help ;;
    *)
        if [[ -n "$1" ]]; then echo "Error: Invalid command '$1'."; fi
        show_help; exit 1
        ;;
esac
