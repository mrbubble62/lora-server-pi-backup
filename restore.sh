#!/bin/bash

# Copyright 2019, Trevor Hobson
# This file is released under the terms of the MIT license.
# See the accompanying LICENSE file or https://opensource.org/licenses/MIT for details.

print_usage () {
    local exe_name="$(basename "$0")"
    echo "Restore a LoRa Server + Gateway + Node-RED on Raspberry Pi Zero from an earlier backup."
    echo "Usage: $exe_name destination-address backup-source"
    echo "  destination-address - IP or hostname of the Pi to restore to."
    echo "  backup-source       - Directory containing backup files to restore from."
}

close_ssh_master () {
    echo "Closing SSH master session."
    ssh -O exit -S $SSH_MASTER_PATH "pi@$DEST_ADDR"
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

DEST_ADDR="$1"
SOURCE_PATH="$2"

if [[ ! -e "$SOURCE_PATH" ]]; then
    echo "Backup doesn't exist: $SOURCE_PATH" >&2
    print_usage >&2
    exit 1
fi

cd "$SOURCE_PATH"

# Things in the backup:
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
ssh -o ControlMaster=yes -o ControlPersist=yes -S $SSH_MASTER_PATH "pi@$DEST_ADDR" \
    echo "SSH master connection established."

# Use the master connection to use ssh without needing to log in again.
# All arguments are passed as additional arguments to ssh.
ssh_auto () {
    ssh -o ChallengeResponseAuthentication=no -S "$SSH_MASTER_PATH" "pi@$DEST_ADDR" "${@}"
}

# stop services that use the files and databases about to be restored
ssh_auto "\
sudo systemctl stop nodered && \
sudo systemctl stop loraserver && \
sudo systemctl stop lora-app-server && \
sudo systemctl stop lora-gateway-bridge"

# backup the node-red directory before replacing it (delete the previous backup first)
# other files replaced during restore aren't backed up
NODE_RED_DIR=".node-red"
ssh_auto "\
if [[ -e \"$NODE_RED_DIR\" ]]; then \
    rm -fr \"${NODE_RED_DIR}-before-restore\"; \
    mv \"$NODE_RED_DIR\" \"${NODE_RED_DIR}-before-restore\"; \
fi"

# files
if false; then
    # restore to a dummy location for testing
    ssh_auto "\
    sudo rm -fr /tmp/dummy-restore && \
    sudo mkdir /tmp/dummy-restore && \
    sudo tar -C /tmp/dummy-restore -xz" < files.tar.gz
else
    ssh_auto "sudo tar -C / -xz" < files.tar.gz
fi

## SQL databases

restore_pg_dump () {
    [[ $# -eq 1 ]]
    local name="$1"
    # Note: Run postgres utilities on the pi so:
    # - client and server versions will match, and
    # - avoid exposing postgresql over the network.
    echo "Database restore: $name"
    # TODO Eliminate all non-warning output. Have unsuccessfully tried:
    # - env PGOPTIONS='-c client_min_messages=WARNING' psql ...
    # - env PGOPTIONS='--client-min-messages=warning' psql ...
    # - psql --set=client_min_messages=WARNING ...
    ssh_auto "sudo -u postgres psql --set=ON_ERROR_STOP=1 --pset pager=off --quiet" < $name.sql
}

restore_pg_dump loraserver_as
restore_pg_dump loraserver_ns

# start services that were stopped earlier
ssh_auto "\
sudo systemctl start lora-gateway-bridge && \
sudo systemctl start lora-app-server && \
sudo systemctl start loraserver && \
sudo systemctl start nodered"

# terminate ssh master connection
echo "Restore complete."
close_ssh_master
