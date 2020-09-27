request = require("request")
http = require 'http'
assert = require("assert")
should = require("should")
redis = require("redis")
util = require("util")
fs = require("fs")
io = require 'socket.io-client'
async = require 'async'
_ = require 'underscore'
dcrypt = require 'dcrypt'
crypto = require 'crypto'

rc = redis.createClient()

# generate keys like this: (bash)
#  private:
#    for i in {0..4999}; do openssl ecparam -name secp521r1 -outform PEM -out test${i}_priv.pem -genkey; done
# then public
#    for i in {0..4999}; do openssl ec -inform PEM -outform PEM -in test${i}_priv.pem -out test${i}_pub.pem -pubout; done


testkeydir = '../testkeys'
baseUri = "https://localhost"
minclient = 0
maxclient = 1999
#maxsockets = 100

#http.globalAgent.maxSockets = maxsockets

#generateKey = (i, callback) ->
#  ecdsa = new dcrypt.keypair.newECDSA 'secp521r1'
#  ecdh = new dcrypt.keypair.newECDSA 'secp521r1'
#
#  random = crypto.randomBytes 16
#
#  dsaPubSig =
#    crypto
#      .createSign('sha256')
#      .update(new Buffer("test#{i}"))
#      .update(new Buffer("test#{i}"))
#      .update(random)
#      .sign(ecdsa.pem_priv, 'base64')
#
#  sig = Buffer.concat([random, new Buffer(dsaPubSig, 'base64')]).toString('base64')
#
#  callback null, {
#  ecdsa: ecdsa
#  ecdh: ecdh
#  sig: sig
#  }
#
#
#makeKeys = (i) ->
#  return (callback) ->
#    generateKey i, callback
#
#createKeys = (minclient, maxclient, done) ->
#  keys = []
#  for i in [minclient..maxclient] by 1
#    keys.push makeKeys(i)
#
#  async.parallel keys, (err, results) ->
#    if err?
#      done err
#    else
#      done null, results

signup = (username, password, dhPub, dsaPub, authSig, done, callback) ->
  request.post
    url: baseUri + "/users"
    json:
      username: username
      password: password
      dhPub: dhPub
      dsaPub: dsaPub
      authSig: authSig
    (err, res, body) ->
      if err
        done err
      else
        res.statusCode.should.equal 201
        callback res, body


createUsers = (i, key, callback) ->
  #console.log 'i: ' + i
  signup 'test' + i, 'test' + i, key.pub, key.pub, key.sig, callback, (res, body) ->
    callback null

makeCreate = (i, key) ->
  return (callback) ->
    createUsers(i, key, callback)


keys = []

for i in [minclient..maxclient]
  pub = fs.readFileSync "#{testkeydir}/test#{i}_pub.pem", 'utf-8'
  sig = fs.readFileSync "#{testkeydir}/test#{i}.sig", 'utf-8'
  keys[i-minclient] =  {
    sig: sig
    pub: pub
  }

tasks = []
#create connect clients tasks
index = 0
for i in [minclient..maxclient] by 1
  tasks.push makeCreate i, keys[index++]
#execute the tasks which creates the cookie jars
async.series tasks, (err) ->
  console.log err if err?
  process.exit()
