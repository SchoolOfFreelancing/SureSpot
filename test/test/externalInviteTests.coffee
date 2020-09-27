request = require("request")
assert = require("assert")
should = require("should")
redis = require("redis")
util = require("util")
fs = require("fs")
io = require 'socket.io-client'
crypto = require 'crypto'
dcrypt = require 'dcrypt'
async = require 'async'
redisSentinel = require 'redis-sentinel-client'
helenus = require 'helenus'

socketPort = process.env.SURESPOT_SOCKET ? 8080
redisSentinelPort = parseInt(process.env.SURESPOT_REDIS_SENTINEL_PORT) ? 6379
redisSentinelHostname = process.env.SURESPOT_REDIS_SENTINEL_HOSTNAME ? "127.0.0.1"
dontUseSSL = process.env.SURESPOT_DONT_USE_SSL is "true"
baseUri = process.env.SURESPOT_TEST_BASEURI
cleanupDb = process.env.SURESPOT_TEST_CLEANDB is "true"
useRedisSentinel = process.env.SURESPOT_USE_REDIS_SENTINEL is "true"


pool = new helenus.ConnectionPool({host:'127.0.0.1', port:9160, keyspace:'surespot'});

rc = if useRedisSentinel then redisSentinel.createClient(redisSentinelPort, redisSentinelHostname) else redis.createClient(redisSentinelPort, redisSentinelHostname)
port = socketPort

jar1 = undefined
jar2 = undefined
jar3 = undefined
jar4 = undefined
cookie1 = undefined
cookie2 = undefined
cookie3 = undefined

cleanup = (done) ->
  keys = [
    "u:test0",
    "u:test1",
    "u:test2",
    "u:test3",
    "f:test0",
    "f:test1",
    "is:test0",
    "ir:test0",
    "is:test1",
    "is:test2",
    "is:test3",
    "ir:test1",
    "ir:test2",
    "ir:test3",
    "c:test1",
    "c:test0",
    "c:test2",
    "kt:test0"
    "kv:test0",
    "k:test0",
    "kv:test1",
    "k:test1",
    "kv:test2",
    "k:test2",
    "kv:test3",
    "k:test3"]

  multi = rc.multi()

  multi.del keys
  multi.hdel "mcounters", "test0:test1"
  multi.hdel "ucmcounters", "test0"
  multi.hdel "ucmcounters", "test1"
  multi.hdel "ucmcounters", "test2"
  multi.hdel "ucmcounters", "test3"
  multi.srem "u", "test0", "test1", "test2", "test3"
  multi.exec (err, results) ->
    return done err if err?
    pool.connect (err, keyspace) ->
      return done err if err?

      cql = "begin batch
               delete from chatmessages where username = ?
               delete from chatmessages where username = ?

               delete from usercontrolmessages where username = ?
               delete from usercontrolmessages where username = ?
               delete from usercontrolmessages where username = ?
               delete from usercontrolmessages where username = ?
            apply batch"

      pool.cql cql, ["test0", "test1", "test0", "test1","test2","test3"], (err, results) ->
        if err
          done err
        else
          done()


login = (username, password, jar, authSig, referrers, done, callback) ->
  request.post
    url: baseUri + "/login"
    jar: jar
    json:
      username: username
      password: password
      authSig: authSig
      referrers: referrers
      version: 56
      platform:'android'
    (err, res, body) ->
      if err
        done err
      else
        cookie = jar.get({ url: baseUri }).map((c) -> c.name + "=" + c.value).join("; ")
        callback res, body, cookie

signup = (username, password, jar, dhPub, dsaPub, authSig, referrers, done, callback) ->
  request.post
    url: baseUri + "/users"
    jar: jar
    json:
      username: username
      password: password
      dhPub: dhPub
      dsaPub: dsaPub
      authSig: authSig
      referrers: referrers
      version: 56
      platform:'android'
    (err, res, body) ->
      if err
        done err
      else
        cookie = jar.get({ url: baseUri }).map((c) -> c.name + "=" + c.value).join("; ")
        callback res, body, cookie

generateKey = (i, callback) ->
  ecdsa = new dcrypt.keypair.newECDSA 'secp521r1'
  ecdh = new dcrypt.keypair.newECDSA 'secp521r1'

  random = crypto.randomBytes 16

  dsaPubSig =
    crypto
      .createSign('sha256')
      .update(new Buffer("test#{i}"))
      .update(new Buffer("test#{i}"))
      .update(random)
      .sign(ecdsa.pem_priv, 'base64')

  sig = Buffer.concat([random, new Buffer(dsaPubSig, 'base64')]).toString('base64')

  callback null, {
  ecdsa: ecdsa
  ecdh: ecdh
  sig: sig
  }


makeKeys = (i) ->
  return (callback) ->
    generateKey i, callback

createKeys = (number, done) ->
  keys = []
  for i in [0..number]
    keys.push makeKeys(i)

  async.parallel keys, (err, results) ->
    if err?
      done err
    else
      done null, results


describe "external invite tests", () ->
  keys = undefined
  before (done) ->
    createKeys 3, (err, keyss) ->
      keys = keyss
      if cleanupDb
        cleanup done
      else
        done()

  client = undefined
  client1 = undefined
  jsonMessage = {type: "message", to: "test0", toVersion: "1", from: "test1", fromVersion: "1", iv: 1, data: "message data", mimeType: "text/plain"}

  it 'signup with auto invite user should send invite control message to auto invite user', (done) ->
    receivedSignupResponse = false
    gotControlMessage = false
    jar1 = request.jar()
    signup 'test0', 'test0', jar1, keys[0].ecdh.pem_pub, keys[0].ecdsa.pem_pub, keys[0].sig, null, done, (res, body, cookie) ->
      client = io.connect baseUri, { 'force new connection': true}, cookie
      client.once 'connect', ->
        jar2 = request.jar()
        signup 'test1', 'test1', jar2, keys[1].ecdh.pem_pub, keys[1].ecdsa.pem_pub, keys[1].sig, JSON.stringify([{ utm_content: "test0"}]), done , (res, body, cookie) ->
          receivedSignupResponse = true
          done() if gotControlMessage

      client.once 'control', (data) ->
        receivedControlMessage = JSON.parse data
        receivedControlMessage.type.should.equal 'user'
        receivedControlMessage.action.should.equal 'invite'
        receivedControlMessage.data.should.equal 'test1'
        should.not.exist receivedControlMessage.localid
        should.not.exist receivedControlMessage.moredata
        gotControlMessage = true
        done() if receivedSignupResponse



  describe 'get friends after signup', () ->
    it 'should have user marked invited', (done) ->
      request.get
        jar: jar1
        url: baseUri + "/friends"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 200
            friendData = JSON.parse(body)
            friendData.friends[0].flags.should.equal 32
            done()

    it 'should have created an invite user control message', (done) ->
      request.get
        jar: jar1
        url: baseUri + "/latestids/0"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 200
            messageData = JSON.parse(body)

            controlData = messageData.userControlMessages
            controlData.length.should.equal 1
            receivedControlMessage = JSON.parse(controlData[0])
            receivedControlMessage.type.should.equal "user"
            receivedControlMessage.action.should.equal "invite"
            receivedControlMessage.data.should.equal "test1"
            receivedControlMessage.id.should.equal 1
            should.not.exist receivedControlMessage.moredata
            should.not.exist receivedControlMessage.from
            done()


#  it 'login with auto invite user should send invite control message to auto invite user', (done) ->
#    receivedSignupResponse = false
#    gotControlMessage = false
#    jar3 = request.jar()
#    jar4 = request.jar()
#
#    signup 'test2', 'test2', jar3, keys[2].ecdh.pem_pub, keys[2].ecdsa.pem_pub, keys[2].sig, null, done, (res, body, cookie) ->
#      client2 = io.connect baseUri, { 'force new connection': true}, cookie
#      client2.once 'connect', ->
#        signup 'test3', 'test3', jar4, keys[3].ecdh.pem_pub, keys[3].ecdsa.pem_pub, keys[3].sig, null, done, (res, body, cookie) ->
#          request.get
#            jar: jar4
#            url: baseUri + "/logout"
#            (err, res, body) ->
#              if err
#                done err
#              else
#                login "test3", "test3", jar4, keys[3].sig, JSON.stringify([{ utm_content: "test2"}]), done, (res, body) ->
#                  receivedSignupResponse = true
#                  done() if gotControlMessage
#
#      client2.once 'control', (data) ->
#        receivedControlMessage = JSON.parse data
#        receivedControlMessage.type.should.equal 'user'
#        receivedControlMessage.action.should.equal 'invite'
#        receivedControlMessage.data.should.equal 'test3'
#        should.not.exist receivedControlMessage.localid
#        should.not.exist receivedControlMessage.moredata
#        gotControlMessage = true
#        done() if receivedSignupResponse



#  describe 'get friends after login', () ->
#    it 'should have user marked invited', (done) ->
#      request.get
#        jar: jar3
#        url: baseUri + "/friends"
#        (err, res, body) ->
#          if err
#            done err
#          else
#            res.statusCode.should.equal 200
#            messageData = JSON.parse(body)
#            messageData.friends[0].flags.should.equal 32
#            done()
#
#    it 'should have created an invite user control message', (done) ->
#      request.get
#        jar: jar3
#        url: baseUri + "/latestids/0"
#        (err, res, body) ->
#          if err
#            done err
#          else
#            res.statusCode.should.equal 200
#            messageData = JSON.parse(body)
#
#            controlData = messageData.userControlMessages
#            controlData.length.should.equal 1
#            receivedControlMessage = JSON.parse(controlData[0])
#            receivedControlMessage.type.should.equal "user"
#            receivedControlMessage.action.should.equal "invite"
#            receivedControlMessage.data.should.equal "test3"
#            receivedControlMessage.id.should.equal 1
#            should.not.exist receivedControlMessage.localid
#            should.not.exist receivedControlMessage.moredata
#            should.not.exist receivedControlMessage.from
#            done()

  after (done) ->
    client.disconnect()
    if cleanupDb
      cleanup done
    else
      done()