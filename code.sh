#!/bin/bash

# chattr2 - simple secure chat using openssl s_server and s_client
# This version adds permission-based file/command execution, robust error handling,
# path shortcuts, and a '/live' command for fully interactive TTY sessions using socat.

DEFAULT_PORT=12345
PORT=$DEFAULT_PORT
LIVE_PORT=12346 # Port for the /live command

# --- Dependency Check ---
if ! command -v socat &> /dev/null; then
    echo "Error: 'socat' is not installed. Please install it to use the /live command." >&2
    echo "e.g., sudo apt-get install socat OR sudo yum install socat" >&2
    exit 1
fi

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
chattr2 - Secure chat with file transfer and remote command execution.

Usage:
  chattr2 server [port] [--nosudo]
  chattr2 client <ip> [port] [--nosudo]
  chattr2 --help

In-chat commands:
  /copy <local_file> [remote_path]   Request to send a file.
  /exec <command...>                 Request to execute a simple command.
  /live <command...>                 Request to run a fully interactive command (e.g., nano, vim, ssh).
  /help                              Show this list of commands.

Path Shortcuts:
  $/   Expands to YOUR home directory (e.g., /copy $/file.txt)
  ~/   Expands to the PEER's home directory (e.g., /exec ls ~/)

The --nosudo flag is for running without root privileges.
The /live command requires 'socat' to be installed on both machines.
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

PIPE_IN="/tmp/chattr2_in_$$"
PIPE_OUT="/tmp/chattr2_out_$$"

function cleanup() {
    exec 3>&- &>/dev/null
    if [[ -n "$openssl_pid" ]]; then kill "$openssl_pid" &>/dev/null; fi
    if [[ -n "$receiver_pid" ]]; then kill "$receiver_pid" &>/dev/null; fi
    rm -f "$PIPE_IN" "$PIPE_OUT" /tmp/chattr2_req_$$*
    tput cnorm
    echo -e "\nExiting."
}
trap cleanup EXIT

function start_chat() {
    local peer_name=$1
    local is_server=$2

    tput civis

    local LOCAL_HOME
    if [[ -n "$SUDO_USER" ]]; then
        LOCAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        LOCAL_HOME=$HOME
    fi

    (
        local in_file_transfer=false
        local transfer_path=""

        while read -r line; do
            echo -ne "\r\033[K"
            local prefix="${line%%:*}"
            local data="${line#*:}"

            case "$prefix" in
                REQ_COPY)
                    local src_b64="${data%%:*}"; local dest_b64="${data#*:}"
                    local src_file=$(echo "$src_b64" | base64 -d); local dest_file=$(echo "$dest_b64" | base64 -d)
                    dest_file="${dest_file/#\~/$HOME}"
                    echo "Incoming file request: '$src_file' to '$dest_file'. Allow? (yes/no)"
                    echo "REQ_COPY:$src_b64:$(echo -n "$dest_file" | base64 -w0)" > "/tmp/chattr2_req_$$"
                    ;;
                REQ_EXEC)
                    local cmd_b64="$data"; local cmd=$(echo "$cmd_b64" | base64 -d)
                    echo "Incoming exec request: '$cmd'. Allow? (yes/no)"
                    echo "REQ_EXEC:$cmd_b64" > "/tmp/chattr2_req_$$"
                    ;;
                REQ_LIVE) # NEW: Handle /live requests
                    local cmd_b64="${data%%:*}"; local peer_ip="${data#*:}"
                    local cmd=$(echo "$cmd_b64" | base64 -d)
                    echo "Incoming interactive session request for: '$cmd'. Allow? (yes/no)"
                    echo "REQ_LIVE:$cmd_b64:$peer_ip" > "/tmp/chattr2_req_$$"
                    ;;
                RESP_LIVE_OK) # NEW: Peer accepted /live, start our socat
                    echo "Peer accepted. Starting interactive session... (When done, exit the command to return to chat)"
                    tput cnorm
                    # This socat connects our terminal to the peer's listening socat
                    socat "TCP:$data:$LIVE_PORT" "READLINE,history=$HOME/.chattr2_history"
                    tput civis
                    echo "Interactive session ended. You are back in chat."
                    ;;
                CMD_ERR)
                    local err_msg=$(echo "$data" | base64 -d)
                    echo -e "Remote command failed:\n---\n$err_msg\n---"
                    ;;
                RESP_OK)
                    echo "Peer accepted the request. Starting action..."
                    local request_file="/tmp/chattr2_req_$$_ack"
                    if [[ -f "$request_file" ]]; then
                        local req_line=$(cat "$request_file")
                        local req_prefix="${req_line%%:*}"; local req_data="${req_line#*:}"
                        if [[ "$req_prefix" == "REQ_COPY" ]]; then
                            local src_file=$(echo "${req_data%%:*}" | base64 -d)
                            echo "INFO:Sending file $src_file..." >&3
                            base64 -w 0 "$src_file" | while read -r chunk; do echo "FILE_DATA:$chunk" >&3; done
                            echo "FILE_END" >&3
                        fi
                        rm -f "$request_file"
                    fi
                    ;;
                RESP_NO)
                    echo "Peer denied the request."
                    rm -f "/tmp/chattr2_req_$$_ack"
                    ;;
                FILE_DATA) if [[ "$in_file_transfer" == true ]]; then echo "$data" | base64 -d >> "$transfer_path"; fi ;;
                FILE_BEGIN) in_file_transfer=true; transfer_path="$data"; echo "Receiving file to '$transfer_path'..."; > "$transfer_path" ;;
                FILE_END) in_file_transfer=false; echo "File transfer to '$transfer_path' complete."; transfer_path="" ;;
                CMD_OUT) echo "Remote: $data" ;;
                INFO) echo "Peer Info: $data" ;;
                *) echo "$peer_name: $line" ;;
            esac
            echo -n "You: "
        done < "$PIPE_OUT"
        echo -e "\n$peer_name disconnected."
        kill $$
    ) &
    receiver_pid=$!

    exec 3>"$PIPE_IN"
    echo -n "You: "
    while read -r -e msg; do
        if [[ "$msg" == "exit" ]]; then break; fi
        
        local pending_req="/tmp/chattr2_req_$$"
        if [[ -f "$pending_req" ]]; then
            local req_line=$(cat "$pending_req")
            local req_prefix="${req_line%%:*}"; local req_data="${req_line#*:}"

            if [[ "$msg" =~ ^[yY]([eE][sS])?$ ]]; then
                echo "RESP_OK" >&3
                if [[ "$req_prefix" == "REQ_COPY" ]]; then
                    local dest_file=$(echo "${req_data#*:}" | base64 -d)
                    echo "FILE_BEGIN:$dest_file" >&3
                elif [[ "$req_prefix" == "REQ_EXEC" ]]; then
                    local cmd_to_run=$(echo "$req_data" | base64 -d)
                    echo "INFO:Executing '$cmd_to_run'..." >&3
                    local output; output=$(eval "$cmd_to_run" 2>&1); local status=$?
                    if [[ $status -ne 0 ]]; then
                        echo "Local command failed. Notifying peer."; echo "--- ERROR ---"; echo "$output"; echo "--- END ERROR ---"
                        echo "CMD_ERR:$(echo -n "$output" | base64 -w 0)" >&3
                    else
                        while IFS= read -r output_line; do echo "CMD_OUT:$output_line" >&3; done <<< "$output"
                    fi
                    echo "INFO:Execution finished." >&3
                elif [[ "$req_prefix" == "REQ_LIVE" ]]; then # NEW: Accept /live request
                    local cmd_b64="${req_data%%:*}"; local peer_ip="${req_data#*:}"
                    local cmd_to_run=$(echo "$cmd_b64" | base64 -d)
                    
                    echo "RESP_LIVE_OK:$peer_ip" >&3
                    echo "Accepted. Starting interactive session for peer..."
                    tput cnorm
                    # This socat listens and executes the command, providing a TTY
                    socat "TCP-LISTEN:$LIVE_PORT,reuseaddr,fork" "EXEC:'$cmd_to_run',pty,stderr,setsid,sigint,sane"
                    tput civis
                    echo "Peer's interactive session ended."
                fi
            else
                echo "RESP_NO" >&3; echo "Denied request."
            fi
            rm -f "$pending_req"

        elif [[ "$msg" == /* ]]; then
            msg="${msg//\$'/'/$LOCAL_HOME}"
            read -r -a cmd_parts <<< "$msg"
            case "${cmd_parts[0]}" in
                "/copy")
                    local local_file="${cmd_parts[1]}"; local remote_file="${cmd_parts[2]}"
                    if [[ -z "$local_file" ]]; then echo "Usage: /copy <local_file> [remote_path]"; continue; fi
                    if [[ ! -f "$local_file" ]]; then echo "Error: File '$local_file' not found."; continue; fi
                    if [[ -z "$remote_file" ]]; then remote_file=$(basename -- "$local_file"); fi
                    local src_b64=$(echo -n "$local_file" | base64 -w0); local dest_b64=$(echo -n "$remote_file" | base64 -w0)
                    echo "REQ_COPY:$src_b64:$dest_b64" > "/tmp/chattr2_req_$$_ack"
                    echo "REQ_COPY:$src_b64:$dest_b64" >&3
                    echo "Requesting to send '$local_file' as '$remote_file'. Waiting..."
                    ;;
                "/exec")
                    local cmd_to_req="${msg#*/exec }"; if [[ -z "$cmd_to_req" ]]; then echo "Usage: /exec <command...>"; continue; fi
                    local cmd_b64=$(echo -n "$cmd_to_req" | base64 -w0)
                    echo "REQ_EXEC:$cmd_b64" > "/tmp/chattr2_req_$$_ack"
                    echo "REQ_EXEC:$cmd_b64" >&3
                    echo "Requesting to execute '$cmd_to_req' on peer. Waiting..."
                    ;;
                "/live") # NEW: Initiate a /live request
                    local cmd_to_req="${msg#*/live }"; if [[ -z "$cmd_to_req" ]]; then echo "Usage: /live <command...>"; continue; fi
                    local local_ip;
                    # Get the IP address used for the main chat connection
                    if [[ "$is_server" == "true" ]]; then
                        local_ip=$(ss -tnp | grep "$openssl_pid" | grep 'ESTAB' | awk '{print $4}' | cut -d: -f1 | head -n1)
                    else
                        local_ip=$(ss -tnp | grep "$openssl_pid" | grep 'ESTAB' | awk '{print $5}' | cut -d: -f1 | head -n1)
                    fi
                    if [[ -z "$local_ip" ]]; then echo "Error: Could not determine local IP for live session."; continue; fi

                    local cmd_b64=$(echo -n "$cmd_to_req" | base64 -w0)
                    echo "REQ_LIVE:$cmd_b64:$local_ip" >&3
                    echo "Requesting interactive session for '$cmd_to_req'. Waiting..."
                    ;;
                "/help")
                    echo "Commands: /copy, /exec, /live, /help. Path Shortcuts: \$/ (your home), ~/ (peer's home)"
                    ;;
                *) echo "Unknown command: ${cmd_parts[0]}. Type /help." ;;
            esac
        else
            if ! ps -p $openssl_pid > /dev/null; then break; fi
            echo "$msg" >&3
        fi
        echo -n "You: "
    done
    exec 3>&-
}

function server_mode() {
    local port_arg=$1; if [[ -n $port_arg && $port_arg =~ ^[0-9]+$ ]]; then PORT=$port_arg; fi
    local cert_file; cert_file=$(generate_cert)
    while true; do
        mkfifo "$PIPE_IN" "$PIPE_OUT"
        echo "Starting chattr2 server on port $PORT... (Ctrl+C to stop)"
        openssl s_server -brief -accept "$PORT" -cert "$cert_file" -quiet < "$PIPE_IN" > "$PIPE_OUT" &
        openssl_pid=$!
        echo "Waiting for a client to connect..."
        # A simple wait for the connection to be established
        until ss -tnp | grep "$openssl_pid" | grep -q 'ESTAB'; do sleep 0.5; done
        echo "Client connected. (Type /help for commands)"
        start_chat "Client" "true"
        kill "$openssl_pid" "$receiver_pid" &>/dev/null
        wait "$openssl_pid" 2>/dev/null
        rm -f "$PIPE_IN" "$PIPE_OUT" /tmp/chattr2_req_$$*
        tput cnorm
        echo "Client session ended. Server is ready for a new connection."
        sleep 1
    done
}

function client_mode() {
    local server_ip=$1; local port_arg=$2
    if [[ -n $port_arg && $port_arg =~ ^[0-9]+$ ]]; then PORT=$port_arg; fi
    mkfifo "$PIPE_IN" "$PIPE_OUT"
    echo "Connecting to $server_ip:$PORT ..."
    openssl s_client -connect "$server_ip:$PORT" -quiet < "$PIPE_IN" > "$PIPE_OUT" 2>/dev/null &
    openssl_pid=$!
    sleep 0.5
    if ! ps -p $openssl_pid > /dev/null; then
       echo "Connection failed. Is the server running?" >&2; exit 1
    fi
    echo "Connected. (Type /help for commands)"
    start_chat "Server" "false"
}

case "$1" in
    server) server_mode "${@:2}"; ;;
    client) if [[ -z "$2" ]]; then echo "Error: Missing server IP." >&2; show_help; exit 1; fi; client_mode "${@:2}"; ;;
    --help|-h) show_help; ;;
    ""|*) if [[ -n "$1" ]]; then echo "Error: Invalid command '$1'." >&2; fi; show_help; exit 1 ;;
esac
