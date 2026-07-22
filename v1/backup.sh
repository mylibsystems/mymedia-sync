#!/bin/bash

find "$1" -mindepth 1 -maxdepth 8 -type f -exec ./transfer.sh {} "$2" "$3" "$4" \; 2>&1 | tee -a ./backup.log
