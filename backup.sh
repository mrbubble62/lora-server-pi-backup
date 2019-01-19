#!/bin/bash

# Copyright 2019, Trevor Hobson
# This file is released under the terms of the MIT license.
# See the accompanying LICENSE file or https://opensource.org/licenses/MIT for details.

print_usage () {
    local exe_name="$(basename "$0")"
    echo "Backup a LoRa Server + Gateway + Node-RED on Raspberry Pi Zero for later restore."
    echo "Usage: $exe_name source-address backup-destination"
    echo "  source-address      - IP or hostname of the Pi to backup from."
    echo "  backup-destination  - Directory to create and populate with backup files."
}

close_ssh_master () {
    echo "Closing SSH master session."
    ssh -O exit -S $SSH_MASTER_PATH "pi@$SOURCE_ADDR"
}

on_error () {
    echo "Aborting on error!" >&2
    if [[ -e "$SSH_MASTER_PATH" ]]; then
        close_ssh_master
    fi
}

set -eE # Abort on any command failure
trap on_error ERR

## Main

if [[ $# -ne 2 ]]; then
    echo "Wrong number of arguments" >&2
    print_usage >&2
    exit 2
fi

SCRIPT_FILE="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_FILE")"

SOURCE_ADDR="$1"
DEST_PATH="$2"

mkdir "$DEST_PATH"
cd "$DEST_PATH"

# Things to backup:
# - Configuration files
#   - /home/pi/.node-red: everything
# - More configuration files (may be removed from backup when an installation script does the work)
#   - /etc: toml files for: loraserver, lora-app-server, lora-gateway-bridge
#   - /etc: certificates for lora-app-server
#   - /opt/ttn-gateway/bin: local_conf.json, global_conf.json
# - SQL databases
#   - loraserver_as, loraserver_ns

## Configuration files

# list of files and directories to transfer
readarray -t item_list < "${SCRIPT_DIR}/item-list.txt"

if false; then
    echo "items: ${item_list[@]}"
fi

# establish ssh master connection
SSH_MASTER_PATH="$HOME/.ssh/master-$$"
ssh -o ControlMaster=yes -o ControlPersist=yes -S $SSH_MASTER_PATH "pi@$SOURCE_ADDR" \
    echo "SSH master connection established."

# Use the master connection to use ssh without needing to log in again.
# All arguments are passed as additional arguments to ssh.
ssh_auto () {
    ssh -o ChallengeResponseAuthentication=no -S "$SSH_MASTER_PATH" "pi@$SOURCE_ADDR" "${@}"
}

# copy with tar to preserve ownership and permissions
ssh_auto "sudo tar -C / -cz ${item_list[@]}" > files.tar.gz

# list details of captured files (including ownership)
if false; then
    tar --list --verbose -f files.tar.gz
fi

## SQL databases

fetch_pg_dump () {
    [[ $# -eq 1 ]]
    local name="$1"
    # Note: Run postgres utilities on the pi so:
    # - client and server versions will match, and
    # - avoid exposing postgresql over the network.
    echo "Database dump: $name"
    ssh_auto "sudo -u postgres pg_dump --clean --create $name" > $name.sql
}

fetch_pg_dump loraserver_as
fetch_pg_dump loraserver_ns

# terminate ssh master connection
echo "Backup complete."
close_ssh_master
