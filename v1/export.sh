#!/bin/bash

find "$1" -maxdepth 8 -type f -exec ./convert.sh {} "$2" "$3" \; 2>&1 | tee -a ./export.log
