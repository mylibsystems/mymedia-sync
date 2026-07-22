

IFS=$'\n'; set -f
for f in $(find PHOTOS -name '*.RW2' -or -name '*.TIFF' -or -name '*.rw2' -or -name '*.tiff'); do

if [[ "$f" == *"RW2"* ]] || [[ "$f" == *"rw2"* ]]; then
    echo $f

    rm -f "${f%.RW2}.jpeg"
    rm -f "${f%.RW2}.JPEG"
    rm -f "${f%.RW2}.jpg"
    rm -f "${f%.RW2}.JPG"
fi

if [[ "$f" == *"TIFF"* ]] || [[ "$f" == *"tiff"* ]]; then
 echo $f
 rm -f "$f"
fi

done
unset IFS; set +f
