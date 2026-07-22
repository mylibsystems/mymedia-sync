#!/bin/bash
original_PWD=$PWD

source=$1
destination=$2
media=$3
export=$4

filename=${source}
extension=$(echo ${filename##*.})
dirname=$(dirname "${filename}")
directory=$(echo "${dirname##*$2/}")
file=$(basename "${filename}" .${filename##*.})
dirDestination=${destination}$(echo "${dirname##*./${media}}")

moveFolder() {
    mkdir -p "${dirDestination}"
    echo "moving media file..." ${file}.${extension}
    mv -v -n ${source} ${dirDestination}
}

copyFolder() {
    mkdir -p "${dirDestination}"
    echo "copying media file..." ${file}.${extension}
    cp -v -n ${source} ${dirDestination}
}

if [[ ${export} == "on" ]]
then
   copyFolder
else
   moveFolder
fi      