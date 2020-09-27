sourcefile=$1
encrfile=$1".gz.enc"

gzip -c "$sourcefile" |
openssl enc -AES-256-CBC -salt -out "$encrfile" -pass env:SURESPOT_RACKSPACE_BACKUP_ENCRYPTION_PASSWORD
