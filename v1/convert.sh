#!/bin/bash
original_PWD=$PWD

filename=$1
extension=$(echo ${filename##*.})
dirname=$(dirname "${filename}")
directory=$(echo "${dirname##*$2/}")
file=$(basename "${filename}" .${filename##*.})
media=$3/.syncing
track=$(echo "${file%%-*}")
audio="$3/${directory}/${track}- track.m4a"
videoResolution="1080"
video="$3/${file}-${videoResolution}p.m4v"
photoResolution="3648"
photo="${file}-${photoResolution}"
picture="$3/${directory}/${photo}px.jpg"

#alias ffmpeg='docker run jrottenberg/ffmpeg'

echo
echo "=================================================================================="
echo "-- CONVERTING -- ${file}"
echo "=================================================================================="
echo

skipIfExists() {
   rm -r "${media}" &>/dev/null
   local output="$1" 
   if [[ -f $output ]]
   then
      echo "${output} exist... skipping"
      exit
   fi
}

convertToJpeg() {
   skipIfExists "${picture}"
   echo "converting to jpeg..." ${filename}
   mkdir -p "${media}/${file}/../../${directory}"
   sips -s format jpeg "${filename}" --out "${media}/${file}/${photo}px.jpg" -Z ${photoResolution}
   sips -s format jpeg "${media}/${file}/${photo}px.jpg" --out "${media}/${file}/thumbnail.jpg" -Z 320
   cd "${media}/${file}"
   exiftool "-thumbnailimage<=thumbnail.jpg" "${photo}px.jpg"
   cd "${original_PWD}"
   mv -n "${media}/${file}/${photo}px.jpg" "${picture}"
   rm -r "${media}/${file}"
}

normilizeTags() {
   local audio="$1" 
   echo "normilizing tags..." ${audio}
   mkdir -p "${media}/${directory}"
   eyeD3 --write-images "${media}/${directory}" "${audio}"
   eyeD3 --remove-all-images "${audio}"
   local images=( "${media}/${directory}/*.jpg" )
   mv -n "${images[0]}" "${media}/../${directory}/cover.jpg"
   eyeD3 --add-image "${media}/../${directory}/cover.jpg":FRONT_COVER "${audio}"
   eyeD3 --add-image "${media}/../${directory}/cover.jpg":MEDIA:image/jpeg "${audio}"
   eyeD3 --to-v2.3 "${audio}"
   rm -r "${media}/${directory}"
}

convertToMp3() {
   skipIfExists "${audio}"
   echo "converting to mp3..." ${filename}
   mkdir -p "${media}/../${directory}"
   avconv -n -i "${filename}" -qscale:a 0 -id3v2_version 3 -write_id3v1 1 -c:v mjpeg -s 400:400 "${audio}"
   normilizeTags "${audio}"
}

convertToM4a() {
   skipIfExists "${audio}"
   echo "converting to m4a..." ${filename}
   mkdir -p "${media}/../${directory}"
   docker run -v /Volumes/:/Volumes/ jrottenberg/ffmpeg -i "${filename}" -map 0:v -map -0:V -c:v mjpeg -s 420:420 -vsync 0 "${media}/../${directory}/cover.jpg" -n
   docker run -v /Volumes/:/Volumes/ jrottenberg/ffmpeg -i "${filename}" -c:a libfdk_aac -b:a 640k -ar 48000 -id3v2_version 3 -write_id3v1 1 -c:v mjpeg -s 420:420 -vsync 0 "${audio}" -y
   #ffmpeg -i "${audio}" -i "${media}/.${directory}/cover.jpg" -map 0:0 -map 0:1 -c copy -id3v2_version 3 "${audio}" -y
   # rm -r "${media}"
}

convertToM4v() {
   skipIfExists "${video}"
   echo "converting to m4v..." ${filename}
   mkdir -p "${media}"
   docker run -v /Volumes/:/Volumes/ jrottenberg/ffmpeg -i "${filename}" -vf scale=${videoResolution}:${videoResolution} -c:v libx264 -preset fast -profile:v baseline -c:a libfdk_aac -b:a 640k -ar 48000 "${video}" -hide_banner
}

copyM4v() {
   skipIfExists "${video}"
   echo "copy video file..." ${filename}
   mkdir -p "${media}/../${directory}"
   cp -n "${filename}" "${video}"
}

copyM4a() {
   skipIfExists "${audio}"
   echo "copy audio file..." ${filename}
   mkdir -p "${media}/../${directory}"
   docker run -v $PWD:/Volumes jrottenberg/ffmpeg -i "${filename}" -map 0:v -map -0:V -c:v mjpeg -s 420:420 -vsync 0 "${media}/../${directory}/cover.jpg" -n
   cp -n "${filename}" "${audio}"
}

copyMp3() {
   skipIfExists "${audio}"
   echo "copy audio file..." ${filename}
   mkdir -p "${media}/../${directory}"
   cp -n "${filename}" "${audio}"
   normilizeTags "${audio}"
}

if [[ ${extension} == "flac" ]] 
then
   convertToM4a
elif [[ ${extension} == "mp3" ]]
then
   convertToM4a
elif [[ ${extension} == "mp4" ]]
then
   convertToM4a
elif [[ ${extension} == "MP4" ]]
then
   copyM4v
elif [[ ${extension} == "avi" ]]
then
   convertToM4v
elif [[ ${extension} == "AVI" ]]
then
   convertToM4v
elif [[ ${extension} == "mov" ]]
then
   convertToM4v
elif [[ ${extension} == "MOV" ]]
then
   convertToM4v
elif [[ ${extension} == "mkv" ]]
then
   convertToM4v
elif [[ ${extension} == "MKV" ]]
then
   convertToM4v
elif [[ ${extension} == "mpeg" ]]
then
   convertToM4v
elif [[ ${extension} == "MPEG" ]]
then
   convertToM4v
elif [[ ${extension} == "avc" ]]
then
   convertToM4v
elif [[ ${extension} == "AVC" ]]
then
   convertToM4v
elif [[ ${extension} == "m4v" ]]
then
   copyM4v
elif [[ ${extension} == "M4V" ]]
then
   copyM4v
elif [[ ${extension} == "m4a" ]]
then
   convertToM4a
elif [[ ${extension} == "jpg" ]]
then
   convertToJpeg
elif [[ ${extension} == "JPG" ]]
then
   convertToJpeg
elif [[ ${extension} == "ORF" ]]
then
   convertToJpeg
elif [[ ${extension} == "orf" ]]
then
   convertToJpeg
elif [[ ${extension} == "RW2" ]]
then
   convertToJpeg
elif [[ ${extension} == "rw2" ]]
then
   convertToJpeg
else
   echo "unsupported file [${filename}], skipping..."
fi
