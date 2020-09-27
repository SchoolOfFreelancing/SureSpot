sourcefile=$1
decfile=`basename $1 .gz.enc`

openssl enc -AES-256-CBC -d -salt -in $sourcefile -pass env:SURESPOT_RACKSPACE_BACKUP_ENCRYPTION_PASSWORD | gunzip -c > $decfile
