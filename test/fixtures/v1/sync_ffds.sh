#!/bin/bash

dataSetPath=/mnt/dst-fs/DataSet

main() {
    startTime=$(date)

    echo "Start sync [SMB] source NAS to [WEKA] Data Set..."
    echo ""
    echo "$startTime start job"
    echo ""
    subPath=
    if [[ "$1" == *"/"* ]]; then
        subPath=/"${1%/*}"
    fi
    rsync -avzhP --no-owner --no-group --delete /mnt/src-share/DataSet/$1 $dataSetPath$subPath

    targetPath=$dataSetPath/$1

    doChangeFileList=$(find $targetPath -not -user root -or -not -group datasetgrp | wc -l)
    if [ "$doChangeFileList" -eq 0 ]; then
        echo "Change file owner and group in $targetPath..."
        echo ""
        find $targetPath -not -user root -or -not -group datasetgrp -print0 | xargs -0 chown root:datasetgrp
    fi

    echo "Change file permission in $targetPath..."
    echo ""
    find $targetPath -type f ! -perm 775 -print0 | xargs -0 chmod 775

    echo "Change directory permission in $targetPath..."
    echo ""
    find $targetPath -type d ! -perm 775 -print0 | xargs -0 chmod 775

    echo Start job at $startTime
    echo Folder: $targetPath
    date
    echo "Done."
}

process=N

if [[ "$1" == "" ]]; then
    isRun=$(pgrep -a sync_ffds.sh | wc -l)
    if [ "$isRun" -le 2 ]; then
        process=Y
    else
        pgrep -a sync_ffds.sh
    fi
    exit 0
else
    isRun=$(pgrep -a rsync | grep $1 | wc -l)
    if [ "$isRun" -eq 0 ]; then
        process=Y
    else
        pgrep -a rsync | grep $1
    fi
fi

logSuffix="${1//\//_}"

echo "Invoke job at $(date)." >> /var/log/rsync-smb$logSuffix.log

if [ "$process" == "Y" ]; then
    main $1 > /var/log/rsync-smb$logSuffix.log 2>&1
fi
