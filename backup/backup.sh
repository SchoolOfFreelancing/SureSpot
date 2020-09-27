outfile=redis_dump.rdb
cd /root/surespot_backup
source ./backup.env
cp /var/lib/redis/dump.rdb $outfile
./gzEncrypt.sh $outfile
coffee backuprs $outfile.gz.enc
rm $outfile
rm $outfile.gz.enc
