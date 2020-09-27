cloudfiles = require 'cloudfiles'
fs = require 'fs'
dateformat = require 'dateformat'
crypto = require 'crypto'
zlib = require 'zlib'
cs = require 'cipherstream'

sourceFile = process.argv[2]
process.exit 1 unless sourceFile?


outfile = "#{sourceFile}.encrypted"
encryptionPassword = "password"

#compress and encrypt file
gzip = zlib.createGzip()
inp = fs.createReadStream(sourceFile)

out = fs.createWriteStream outfile
encStream = new cs.CipherStream(encryptionPassword)
inp.pipe(gzip).pipe(encStream).pipe(out)

out.on 'close', ->

  #decrypt and decompress
  gunzip = zlib.createGunzip()
  id = fs.createReadStream(outfile)
  out2 = fs.createWriteStream "#{sourceFile}.original"
  decStream = new cs.DecipherStream(encryptionPassword)
  id.pipe(decStream).pipe(gunzip).pipe(out2)



