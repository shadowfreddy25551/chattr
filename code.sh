#!/bin/bash

# chattr2 - simple secure chat using openssl s_server and s_client
# This version adds permission-based file transfer and remote command execution,
# with robust error handling, sequential multi-client support, and local/remote
# path shortcuts ($/ for local home, ~/ for remote home).

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
chattr2 - Simple secure chat with file transfer and remote command execution.

Usage:
  chattr2 server [port] [--nosudo]     Start chat server on [port] (default: $DEFAULT_PORT)
  chattr2 client <ip> [port] [--nosudo] Connect to server at <ip> on [port] (default: $DEFAULT_PORT)
  chattr2 --help                       Show this help message and exit

In-chat commands:
  /copy <local_file> [remote_path]   Request to send a file.
  /exec <command...>                 Request to execute a command on the remote side.
  /help                              Show this list of commands.

Path Shortcuts:
  $/   Expands to YOUR home directory (e.g., /copy $/file.txt)
  ~/   Expands to the PEER's home directory (e.g., /exec ls ~/)

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
    # Ensure file descriptor 3 is closed if it was opened
    exec 3>&- &>/dev/null
    if [[ -n "$openssl_pid" ]]; then kill "$openssl_pid" &>/dev/null; fi
    if [[ -n "$receiver_pid" ]]; then kill "$receiver_pid" &>/dev/null; fi
    rm -f "$PIPE_IN" "$PIPE_OUT" /tmp/chattr2_req_$$*
    tput cnorm # Ensure cursor is visible
    echo -e "\nExiting."
}
trap cleanup EXIT

# --- Core Logic ---

function start_chat() {
    local peer_name=$1
    tput civis # Hide cursor

    # NEW: Determine the correct local home directory, even when using sudo
    local LOCAL_HOME
    if [[ -n "$SUDO_USER" ]]; then
        LOCAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        LOCAL_HOME=$HOME
    fi

    # Receiver: Reads and processes incoming messages from the pipe.
    (
        local in_file_transfer=false
        local transfer_path=""

        while read -r line; do
            echo -ne "\r\033[K" # Clear the current line
            
            # Protocol parsing
            local prefix="${line%%:*}"
            local data="${line#*:}"

            case "$prefix" in
                REQ_COPY)
                    local src_b64="${data%%:*}"
                    local dest_b64="${data#*:}"
                    local src_file=$(echo "$src_b64" | base64 -d)
                    local dest_file=$(echo "$dest_b64" | base64 -d)
                    # Expand remote home path on the receiving end. This is correct as is.
                    dest_file="${dest_file/#\~/$HOME}"
                    echo "Incoming file request: '$src_file' to '$dest_file'. Allow? (yes/no)"
                    echo "REQ_COPY:$src_b64:$(echo -n "$dest_file" | base64 -w0)" > "/tmp/chattr2_req_$$"
                    ;;
                REQ_EXEC)
                    local cmd_b64="$data"
                    local cmd
                    cmd=$(echo "$cmd_b64" | base64 -d)
                    echo "Incoming exec request: '$cmd'. Allow? (yes/no)"
                    echo "REQ_EXEC:$cmd_b64" > "/tmp/chattr2_req_$$"
                    ;;
                CMD_ERR)
                    local err_b64="$data"
                    local err_msg
                    err_msg=$(echo "$err_b64" | base64 -d)
                    echo -e "Remote command failed:\n---"
                    echo -e "$err_msg\n---"
                    ;;
                RESP_OK)
                    echo "Peer accepted the request. Starting action..."
                    local request_file="/tmp/chattr2_req_$$_ack"
                    if [[ -f "$request_file" ]]; then
                        local request_line=$(cat "$request_file")
                        local req_prefix="${request_line%%:*}"
                        local req_data="${request_line#*:}"

                        if [[ "$req_prefix" == "REQ_COPY" ]]; then
                            local src_b64="${req_data%%:*}"
                            local src_file=$(echo "$src_b64" | base64 -d)
                            echo "INFO:Sending file $src_file..." >&3
                            base64 -w 0 "$src_file" | while read -r chunk; do
                                echo "FILE_DATA:$chunk" >&3
                            done
                            echo "FILE_END" >&3
                        fi
                        rm -f "$request_file"
                    fi
                    ;;
                RESP_NO)
                    echo "Peer denied the request."
                    rm -f "/tmp/chattr2_req_$$_ack"
                    ;;
                FILE_DATA)
                    if [[ "$in_file_transfer" == true ]]; then
                        echo "$data" | base64 -d >> "$transfer_path"
                    fi
                    ;;
                FILE_BEGIN)
                    in_file_transfer=true
                    transfer_path="$data"
                    echo "Receiving file to '$transfer_path'..."
                    > "$transfer_path"
                    ;;
                FILE_END)
                    in_file_transfer=false
                    echo "File transfer to '$transfer_path' complete."
                    transfer_path=""
                    ;;
                CMD_OUT)
                    echo "Remote: $data"
                    ;;
                INFO)
                    echo "Peer Info: $data"
                    ;;
                *)
                    echo "$peer_name: $line"
                    ;;
            esac
            echo -n "You: "
        done < "$PIPE_OUT"
        echo -e "\n$peer_name disconnected."
        kill $$ # Exit parent script if connection drops
    ) &
    receiver_pid=$!

    # Sender: Reads user input and sends it or processes local commands.
    exec 3>"$PIPE_IN"
    echo -n "You: "
    while read -r -e msg; do
        if [[ "$msg" == "exit" ]]; then break; fi
        
        local pending_req="/tmp/chattr2_req_$$"
        if [[ -f "$pending_req" ]]; then
            local req_line=$(cat "$pending_req")
            local req_prefix="${req_line%%:*}"
            local req_data="${req_line#*:}"

            if [[ "$msg" =~ ^[yY]([eE][sS])?$ ]]; then
                echo "RESP_OK" >&3
                if [[ "$req_prefix" == "REQ_COPY" ]]; then
                    local dest_b64="${req_data#*:}"
                    local dest_file
                    dest_file=$(echo "$dest_b64" | base64 -d)
                    echo "FILE_BEGIN:$dest_file" >&3
                elif [[ "$req_prefix" == "REQ_EXEC" ]]; then
                    local cmd_b64="$req_data"
                    local cmd_to_run
                    cmd_to_run=$(echo "$cmd_b64" | base64 -d)
                    echo "INFO:Executing '$cmd_to_run'..." >&3
                    
                    local output
                    output=$(eval "$cmd_to_run" 2>&1)
                    local status=$?
                    
                    if [[ $status -ne 0 ]]; then
                        echo "Local command failed with status $status. Notifying peer."
                        echo "--- ERROR ---"
                        echo "$output"
                        echo "--- END ERROR ---"
                        local out_b64
                        out_b64=$(echo -n "$output" | base64 -w 0)
                        echo "CMD_ERR:$out_b64" >&3
                    else
                        while IFS= read -r output_line; do
                           echo "CMD_OUT:$output_line" >&3
                        done <<< "$output"
                    fi
                    echo "INFO:Execution finished." >&3
                fi
            else
                echo "RESP_NO" >&3
                echo "Denied request."
            fi
            rm -f "$pending_req"

        elif [[ "$msg" == /* ]]; then # It's a command
            # MODIFIED: Use the intelligent LOCAL_HOME variable for expansion.
            msg="${msg//\$'/'/$LOCAL_HOME}"

            read -r -a cmd_parts <<< "$msg"
            case "${cmd_parts[0]}" in
                "/copy")
                    local local_file="${cmd_parts[1]}"
                    local remote_file="${cmd_parts[2]}"
                    if [[ -z "$local_file" ]]; then echo "Usage: /copy <local_file> [remote_path]"; continue; fi
                    if [[ ! -f "$local_file" ]]; then echo "Error: File '$local_file' not found."; continue; fi
                    if [[ -z "$remote_file" ]]; then remote_file=$(basename -- "$local_file"); fi
                    
                    local src_b64 dest_b64
                    src_b64=$(echo -n "$local_file" | base64 -w0)
                    dest_b64=$(echo -n "$remote_file" | base64 -w0)
                    
                    echo "REQ_COPY:$src_b64:$dest_b64" > "/tmp/chattr2_req_$$_ack"
                    echo "REQ_COPY:$src_b64:$dest_b64" >&3
                    echo "Requesting to send '$local_file' to peer as '$remote_file'. Waiting for response..."
                    ;;
                "/exec")
                    local cmd_to_req="${msg#*/exec }"
                    if [[ -z "$cmd_to_req" ]]; then echo "Usage: /exec <command...>"; continue; fi
                    
                    local cmd_b64
                    cmd_b64=$(echo -n "$cmd_to_req" | base64 -w0)
                    
                    echo "REQ_EXEC:$cmd_b64" > "/tmp/chattr2_req_$$_ack"
                    echo "REQ_EXEC:$cmd_b64" >&3
                    echo "Requesting to execute '$cmd_to_req' on peer. Waiting for response..."
                    ;;
                "/help")
                    echo "Commands: /copy, /exec, /help"
                    echo "Path Shortcuts: \$/ (your home), ~/ (peer's home)"
                    ;;
                *)
                    echo "Unknown command: ${cmd_parts[0]}. Type /help for a list of commands."
                    ;;
            esac
        else # It's a regular message
            if ! ps -p $openssl_pid > /dev/null; then break; fi
            echo "$msg" >&3
        fi
        echo -n "You: "
    done
    exec 3>&- # Close the file descriptor
}

function server_mode() {
    local port_arg=$1
    if [[ -n $port_arg && $port_arg =~ ^[0-9]+$ ]]; then
        PORT=$port_arg
    fi
    local cert_file
    cert_file=$(generate_cert)

    while true; do
        mkfifo "$PIPE_IN" "$PIPE_OUT"
        echo "Starting chattr2 server on port $PORT..."
        echo "Waiting for a client to connect... (Ctrl+C to stop server)"
        
        openssl s_server -brief -accept "$PORT" -cert "$cert_file" -quiet < "$PIPE_IN" > "$PIPE_OUT" &
        openssl_pid=$!

        sleep 1

        echo "Client connected. You can start chatting. (Type 'exit' or /help for commands)"
        start_chat "Client"
        
        kill "$openssl_pid" "$receiver_pid" &>/dev/null
        wait "$openssl_pid" 2>/dev/null
        rm -f "$PIPE_IN" "$PIPE_OUT" /tmp/chattr2_req_$$*
        tput cnorm

        echo "Client session ended. Server is ready for a new connection."
        sleep 1
    done
}

function client_mode() {
    local server_ip=$1
    local port_arg=$2
    if [[ -n $port_arg && $port_arg =~ ^[0-9]+$ ]]; then
        PORT=$port_arg
    fi
    mkfifo "$PIPE_IN" "$PIPE_OUT"

    echo "Connecting to $server_ip:$PORT ..."
    openssl s_client -connect "$server_ip:$PORT" -quiet < "$PIPE_IN" > "$PIPE_OUT" 2>/dev/null &
    openssl_pid=$!

    sleep 0.5
    if ! ps -p $openssl_pid > /dev/null; then
       echo "Connection failed. Is the server running at that IP/port?" >&2
       exit 1
    fi

    echo "Connected. You can start chatting. (Type 'exit' or /help for commands)"
    start_chat "Server"
}

# --- Argument Parsing ---
case "$1" in
    server) server_mode "${@:2}"; ;;
    client)
        if [[ -z "$2" ]]; then echo "Error: Missing server IP address." >&2; show_help; exit 1; fi
        client_mode "${@:2}"
        ;;
    --help|-h) show_help; ;;
    ""|*)
        if [[ -n "$1" ]]; then echo "Error: Invalid command '$1'." >&2; fi
        show_help; exit 1
        ;;
esac
