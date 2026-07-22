#!/bin/bash

rm -r ./import.log &>/dev/null
rm -r ./export.log &>/dev/null
rm -r ./backup.log &>/dev/null
rm -r ./sync.log &>/dev/null

# booksDir="/Volumes/Roman/Books"

# virtual network settings
# vpnName="mylib.io (L2TP)"
# localMountFolder="network"
# remotePersonalFolder="Roman"
# remotePublicFolder="Public"

# export to directories
# cameraBackupDir="${localMountFolder}/${remotePersonalFolder}/Camera"
# recordsBackupDir="${localMountFolder}/${remotePublicFolder}/Shared Music"
# projectsBackupDir="${localMountFolder}/${remotePersonalFolder}"

# import from directories
localMediaDir="/Volumes/WD-ELEMENTS"
localMusicDir="${localMediaDir}/MUSIC"
localPhotosDir="${localMediaDir}/PHOTOS"
localVideoDir="${localMediaDir}/VIDEO"
localMoviesDir="${localMediaDir}/MOVIES"

# library directories
libraryDir="/Volumes/WD-ELEMENTS"
libraryPhotosDir="${libraryDir}/PHOTOS.JPEG"
libraryMoviesDir="${libraryDir}/MOVIES.MP4"
libraryMusicDir="${libraryDir}/MUSIC.MP4"

# Source directories
cameraDir="/Volumes/LUMIX"
downloadsDir="/Volumes/WD-ELEMENTS/INBOX"
# downloadsDir="/Users/roman.grygorovych/Movies"
# projectsDir="/Users/roman.grygorovych/Projects"

# ------------------------------------------------------------------------------------------

# echo "Connecting to VPN ${vpnName}..."
# networksetup -connectpppoeservice "${vpnName}"

# sleep 3

# echo "Creating local mount folders..."
# mkdir -p "${localMountFolder}/${remotePersonalFolder}"
# mkdir -p "${localMountFolder}/${remotePublicFolder}"

# sleep 3

# echo "Mounting remote folders..."
# mount_smbfs "//roman:longhappylife@storage.mylib.org/${remotePersonalFolder}" "${localMountFolder}/${remotePersonalFolder}"
# mount_smbfs "//roman:longhappylife@storage.mylib.org/${remotePublicFolder}" "${localMountFolder}/${remotePublicFolder}"

# # ------------------------------------------------------------------------------------------

echo
echo "##################################################################################"
echo "## CAMERA [LUMIX] ################################################################"
echo "##################################################################################"
echo

for dir in "${cameraDir}"/*; do {
    fromDir=$(echo "${dir##*LUMIX/}")
    ./import.sh "${dir}" "${fromDir}" "${localMediaDir}" & pid=$!
    PID_LIST+=" $pid";
} done

trap "kill $PID_LIST" SIGINT
echo "Photos importing has strated";
wait $PID_LIST
echo
echo "All photo importing processes have completed";

# # ------------------------------------------------------------------------------------------
#   !!! Deprecated !!!
# for dir in "${localPhotosDir}"/*; do {
#     fromDir=$(echo "${dir##*photos/}")
#     toDir="${libraryPhotosDir}/${fromDir}"
#     ./export.sh "${dir}" "${fromDir}" "${toDir}" & pid=$!
#     PID_LIST+=" $pid";
# } done

# trap "kill $PID_LIST" SIGINT
# echo "Photos exporting has strated";
# wait $PID_LIST
# echo
# echo "All photo exporting processes have completed";

# # ------------------------------------------------------------------------------------------

# echo "Backing up the photos to ${cameraBackupDir}... "
# ./backup.sh "${localPhotosDir}" "${cameraBackupDir}" photos
# echo
# echo "All photos backing up have completed";

# # ------------------------------------------------------------------------------------------

# echo "Videos exporting has strated";
# ./backup.sh "${localVideoDir}" "${libraryVideoDir}" video on
# echo
# echo "All video exporting processes have completed";

# # ------------------------------------------------------------------------------------------

# echo "Backing up the videos to ${cameraBackupDir}... "
# ./backup.sh "${localVideoDir}" "${cameraBackupDir}" video
# echo
# echo "All videos backing up have completed";

# # ------------------------------------------------------------------------------------------

echo
echo "##################################################################################"
echo "## DOWNLOADS #####################################################################"
echo "##################################################################################"
echo

for dir in "${downloadsDir}"/*; do {
    fromDir=$(echo "${dir##*INBOX/}")
    ./import.sh "${dir}" "${fromDir}" "${localMediaDir}" & pid=$!
    PID_LIST+=" $pid";
} done

trap "kill $PID_LIST" SIGINT
echo "Downloaded media importing has strated";
wait $PID_LIST
echo
echo "All media importing processes have completed";

# # ------------------------------------------------------------------------------------------

echo
echo "##################################################################################"
echo "## MUSIC #########################################################################"
echo "##################################################################################"
echo

for dir in "${localMusicDir}"/*; do {
    fromDir=$(echo "${dir##*MUSIC/}")
    toDir="${libraryMusicDir}/${fromDir}"
    ./export.sh "${dir}" "${fromDir}" "${toDir}" & pid=$!
    PID_LIST+=" $pid";
} done

trap "kill $PID_LIST" SIGINT
echo "Music exporting have started";
wait $PID_LIST
echo
echo "All music exporting processes have completed";

# # ------------------------------------------------------------------------------------------

echo
echo "##################################################################################"
echo "## MOVIES ########################################################################"
echo "##################################################################################"
echo

echo "Movies exporting have started";

for dir in "${localMoviesDir}"/*; do {
    fromDir=$(echo "${dir##*MOVIES/}")
    toDir="${libraryMoviesDir}/${fromDir}"
    ./export.sh "${dir}" "${fromDir}" "${toDir}"
} done

echo
echo "All movies exporting processes have completed";

# # ------------------------------------------------------------------------------------------

# echo "Backing up the records to ${recordsBackupDir}... "
# ./backup.sh "${localMusicDir}" "${recordsBackupDir}" music
# echo
# echo "All records backing up have completed";

# # ------------------------------------------------------------------------------------------

# echo "Backing up the projects to ${projectsBackupDir}... "
# rsync -rblogvh --progress --ignore-errors --force --delete --stats "${projectsDir}" "${projectsBackupDir}" 2>&1 | tee -a ./sync.log

# # ------------------------------------------------------------------------------------------

echo 
echo "##################################################################################"
echo "## CLEANING ######################################################################"
echo "##################################################################################"
echo
echo "Cleaning up ... "

find "${libraryPhotosDir}" -name .syncing -type d -exec rm -r {} +
find "${libraryMoviesDir}" -name .syncing -type d -exec rm -r {} +
find "${libraryMusicDir}" -name .syncing -type d -exec rm -r {} +

find "${localMoviesDir}" -empty -type d -delete 2>&1
find "${localMusicDir}" -empty -type d -delete 2>&1
find "${localPhotosDir}" -empty -type d -delete 2>&1
find "${localVideoDir}" -empty -type d -delete 2>&1

find "${cameraDir}" -empty -type d -delete 2>&1
find "${downloadsDir}" -empty -type d -delete 2>&1