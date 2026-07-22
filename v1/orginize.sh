#!/bin/bash
original_PWD=$PWD

filename=$1
extension=$(echo ${filename##*.})
dirname=$(dirname "${filename}")
directory=$(echo "${2}" | sed 's/[_.]/ /g')
file=$(basename "${filename}" .${filename##*.})
media=$3
mediaFile=${file}.${extension}

echo
echo "=================================================================================="
echo "-- ORGINIZING -- ${file}"
echo "=================================================================================="
echo

skipIfExists() {
   local output="$1" 
   if [[ -f ${output} ]]
   then
      echo "${output} exist... skipping"
      exit
   fi
}

orginizeDefault() {
   local targetDir="$1"

   skipIfExists "${media}/${targetDir}/${directory}/${mediaFile}"
   mkdir -p "${media}/${targetDir}/${directory}"
   echo "moving media file..." ${filename}
   mv -n "${filename}" "${media}/${targetDir}/${directory}/${mediaFile}"
}

orginizeByDate() {
   if [[ ${file} =~ ([Cc]over|[Aa]lbum|[Aa]rt) ]]
   then
      echo "${filename}... skipping"
      exit
   fi

    local outputDir=$(exiftool "${filename}" | sort -u | grep -m 1 "Date/Time Original\|Metadata Date" | grep -Eo '[[:digit:]]{4}:[[:digit:]]{2}:[[:digit:]]{2}' | sed 's/:/\//g')

    if [[ -z ${outputDir} ]] 
    then
        outputDir=$(exiftool "${filename}" | sort -u | grep -m 1 "File Modification Date/Time" | grep -Eo '[[:digit:]]{4}:[[:digit:]]{2}:[[:digit:]]{2}' | sed 's/:/\//g')
    fi

    local targetDir="$1"

    skipIfExists "${media}/${targetDir}/${outputDir}/${mediaFile}"
    mkdir -p "${media}/${targetDir}/${outputDir}"
    echo "moving media file..." ${filename}
    mv -n "${filename}" "${media}/${targetDir}/${outputDir}/${mediaFile}"
}

orginizeByTags() {
   local artistDir=$(exiftool "${filename}" | grep -E -m 1 '^Album\s*[aA]rtist\s*:' | sed 's/^.*\:\(.*\)$/\1/' | sed 's/^[ \t]*//;s/[ \t]*$//' | sed 's/\//-/g')
   if [[ -z ${artistDir} ]]; then echo "missing artist... skipping"; exit; fi

   local yearDir=$(exiftool "${filename}" | grep -E -m 1 '^(Date|Content Create Date)\s*:' | sed 's/^.*\:\(.*\)$/\1/' | sed 's/^[ \t]*//;s/[ \t]*$//' | sed 's/\//-/g')
   if [[ -z ${yearDir} ]]; then echo "missing year... skipping"; exit; fi

   local albumDir=$(exiftool "${filename}" | grep -E -m 1 '^Album\s*:' | sed 's/^.*\:\(.*\)$/\1/' | sed 's/^[ \t]*//;s/[ \t]*$//' | sed 's/\//-/g')
   if [[ -z ${albumDir} ]]; then echo "missing album... skipping"; exit; fi

   local diskNumFile=$(exiftool "${filename}" | grep -E -m 1 '^Dis[ck]\s*[Nn]umber\s*:' | sed 's/^.*\:\(.*\)$/\1/' | sed 's/^[ \t]*//;s/[ \t]*$//' | grep -Eo '^[[:digit:]]+' | awk '{ printf "%01s\n", $1 }')
   if [[ -z ${diskNumFile} ]]; then echo "missing disk number... skipping"; exit; fi

   local trackNumFile=$(exiftool "${filename}" | grep -E -m 1 '^Track\s*[Nn]umber\s*:' | sed 's/^.*\:\(.*\)$/\1/' | sed 's/^[ \t]*//;s/[ \t]*$//' | grep -Eo '^[[:digit:]]+' | awk '{ printf "%02s\n", $1 }')
   if [[ -z ${trackNumFile} ]]; then echo "missing track number... skipping"; exit; fi

   local titleFile=$(exiftool "${filename}" | grep -E -m 1 '^Title\s*:' | sed 's/^.*\:\(.*\)$/\1/' | sed 's/^[ \t]*//;s/[ \t]*$//' | sed 's/\//-/g')
   if [[ -z ${titleFile} ]]; then echo "missing title... skipping"; exit; fi

   local targetDir="$1"
   local recordDir="${media}/${targetDir}/${artistDir}/${yearDir} - ${albumDir}"
   local recordFile="${diskNumFile}.${trackNumFile} - track.${extension}"

   skipIfExists "${recordDir}/${recordFile}"
   mkdir -p "${recordDir}"
   echo "moving media file..." ${filename}
   cp -n "${filename}" "${recordDir}/${recordFile}"
}

if [[ ${extension} == "m4a" ]]
then
   orginizeByTags "MUSIC"
elif [[ ${extension} == "flac" ]]
then
   orginizeByTags "MUSIC"
elif [[ ${extension} == "mp3" ]]
then
   orginizeByTags "MUSIC"
elif [[ ${extension} == "mp4" ]]
then
   orginizeByDate "PHOTOS"
elif [[ ${extension} == "MP4" ]]
then
   orginizeByDate "PHOTOS"   
elif [[ ${extension} == "jpg" ]]
then
   orginizeByDate "PHOTOS"
elif [[ ${extension} == "JPG" ]]
then
   orginizeByDate "PHOTOS"
elif [[ ${extension} == "jpg" ]]
then
   orginizeByDate "PHOTOS"
elif [[ ${extension} == "jpeg" ]]
then
   orginizeByDate "PHOTOS"
elif [[ ${extension} == "ORF" ]]
then
   orginizeByDate "PHOTOS"
elif [[ ${extension} == "orf" ]]
then
   orginizeByDate "PHOTOS"
elif [[ ${extension} == "RW2" ]]
then
   orginizeByDate "PHOTOS"
elif [[ ${extension} == "rw2" ]]
then
   orginizeByDate "PHOTOS"
elif [[ ${extension} == "heic" ]]
then
   orginizeByDate "PHOTOS"
elif [[ ${extension} == "avi" ]]
then
   orginizeDefault "MOVIES"
elif [[ ${extension} == "AVI" ]]
then
   orginizeDefault "MOVIES"
elif [[ ${extension} == "mov" ]]
then
   orginizeByDate "PHOTOS"
elif [[ ${extension} == "MOV" ]]
then
   orginizeByDate "PHOTOS"
elif [[ ${extension} == "mkv" ]]
then
   orginizeDefault "MOVIES"
elif [[ ${extension} == "MKV" ]]
then
   orginizeDefault "MOVIES"
elif [[ ${extension} == "mpeg" ]]
then
   orginizeDefault "MOVIES"
elif [[ ${extension} == "MPEG" ]]
then
   orginizeDefault "MOVIES"
elif [[ ${extension} == "avc" ]]
then
   orginizeDefault "MOVIES"
elif [[ ${extension} == "AVC" ]]
then
   orginizeDefault "MOVIES"
elif [[ ${extension} == "m4v" ]]
then
   orginizeDefault "MOVIES"
elif [[ ${extension} == "M4V" ]]
then
   orginizeDefault "MOVIES"
else
   echo "unsupported file [${filename}], skipping..."
fi
