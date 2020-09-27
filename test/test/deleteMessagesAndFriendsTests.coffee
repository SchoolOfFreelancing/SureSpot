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
socketPort = process.env.SURESPOT_SOCKET ? 8080
redisSentinelPort = parseInt(process.env.SURESPOT_REDIS_SENTINEL_PORT) ? 6379
redisSentinelHostname = process.env.SURESPOT_REDIS_SENTINEL_HOSTNAME ? "127.0.0.1"
dontUseSSL = process.env.SURESPOT_DONT_USE_SSL is "true"
baseUri = process.env.SURESPOT_TEST_BASEURI ? "http://127.0.0.1:8080"
cleanupDb = process.env.SURESPOT_TEST_CLEANDB is "true"
useRedisSentinel = process.env.SURESPOT_USE_REDIS_SENTINEL is "true"

rc = if useRedisSentinel then redisSentinel.createClient(redisSentinelPort, redisSentinelHostname) else redis.createClient(redisSentinelPort, redisSentinelHostname)
port = socketPort

jar0 = undefined
jar1 = undefined
cookie0 = undefined
cookie1 = undefined

cleanup = (done) ->
  keys = [
    "u:test0",
    "u:test1",
    "f:test0",
    "f:test1",
    "is:test0",
    "ir:test0",
    "is:test1",
    "ir:test1",
    "m:test1",
    "d:test0:test0:test1",
    "c:test1",
    "c:test0",
    "kv:test0",
    "k:test0",
    "kv:test1",
    "k:test1",
    "cm:test0:test1",
    "cm:test0:test1:id"
    "cu:test0",
    "cu:test1",
    "cu:test0:id",
    "cu:test1:id",
    "ud:test0",
    "ud:test1",
    "d:test0",
    "d:test1"]

  multi = rc.multi()
  multi.del keys
  multi.srem "u", "test0", "test1"
  multi.hdel "mcounters", "test0:test1"
  multi.exec (err, results) ->
    if err
      done err
    else
      done()


login = (username, password, jar, authSig, done, callback) ->
  request.post
    url: baseUri + "/login"
    jar: jar
    json:
      username: username
      password: password
      authSig: authSig
      version: 56
      platform:'android'
    (err, res, body) ->
      if err
        done err
      else
        cookie = jar.get({ url: baseUri }).map((c) -> c.name + "=" + c.value).join("; ")
        callback res, body, cookie

signup = (username, password, jar, dhPub, dsaPub, authSig, done, callback) ->
  request.post
    url: baseUri + "/users"
    jar: jar
    json:
      username: username
      password: password
      dhPub: dhPub
      dsaPub: dsaPub
      authSig: authSig
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

client = undefined
client1 = undefined
jsonMessage = {type: "message", to: "test0", toVersion: "1", from: "test1", fromVersion: "1", iv: 1, data: "message data", mimeType: "text/plain"}

sendThreeMessagesFromEachUser = (done) ->
  clientDone = false
  client1Done = false
  jsonMessage.from = "test0"
  jsonMessage.to = "test1"
  jsonMessage.iv = "0"
  client.send JSON.stringify(jsonMessage)
  client.on 'message', (receivedMessage) ->
    receivedMessage = JSON.parse receivedMessage
    if receivedMessage.iv is "4"
      client.removeAllListeners 'message'
      clientDone = true
      if (clientDone && client1Done)
        done()


  jsonMessage.from = "test1"
  jsonMessage.to = "test0"
  jsonMessage.iv = "1"
  client1.send JSON.stringify(jsonMessage)
  client1.on 'message', (receivedMessage) ->
    receivedMessage = JSON.parse receivedMessage
    if receivedMessage.iv is "5"
      client1.removeAllListeners 'message'
      client1Done = true
      if (clientDone && client1Done)
        done()

  jsonMessage.from = "test0"
  jsonMessage.to = "test1"
  jsonMessage.iv = "2"
  client.send JSON.stringify(jsonMessage)

  jsonMessage.from = "test1"
  jsonMessage.to = "test0"
  jsonMessage.iv = "3"
  client1.send JSON.stringify(jsonMessage)

  jsonMessage.from = "test0"
  jsonMessage.to = "test1"
  jsonMessage.iv = "4"
  client.send JSON.stringify(jsonMessage)

  jsonMessage.from = "test1"
  jsonMessage.to = "test0"
  jsonMessage.iv = "5"
  client1.send JSON.stringify(jsonMessage)

describe "delete messages and friends test", () ->
  keys = undefined
  before (done) ->
    createKeys 2, (err, keyss) ->
      keys = keyss
      if cleanupDb
        cleanup done
      else
        done()


  it 'client 1 connect', (done) ->
    jar0 = request.jar()
    signup 'test0', 'test0', jar0, keys[0].ecdh.pem_pub, keys[0].ecdsa.pem_pub, keys[0].sig, done, (res, body, cookie) ->
      client = io.connect baseUri, { 'force new connection': true}, cookie
      cookie0 = cookie
      client.once 'connect', ->
        done()

  it 'client 2 connect', (done) ->
    jar1 = request.jar()
    signup 'test1', 'test1', jar1, keys[1].ecdh.pem_pub, keys[1].ecdsa.pem_pub, keys[1].sig, done, (res, body, cookie) ->
      client1 = io.connect baseUri, { 'force new connection': true}, cookie
      cookie1 = cookie
      client1.once 'connect', ->
        done()

  it 'become friends', (done) ->
    request.post
      jar: jar1
      url: baseUri + "/invite/test0"
      (err, res, body) ->
        if err
          done err
        else

          request.post
            jar: jar0
            url: baseUri + "/invites/test1/accept"
            (err, res, body) ->
              if err
                done err
              else
                done()

  it 'send 3 messages from each user', (done) ->
    sendThreeMessagesFromEachUser(done)


  describe 'delete all of a user\'s messages', ->
    it 'should succeed', (done) ->
      request.del
        jar: jar0
        url: baseUri + "/messagesutai/test1/100"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 204
            done()


    it 'the user should not have any messages left', (done) ->
      request.get
        jar: jar0
        url: baseUri + "/messages/test1/before/7"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 200
            data = JSON.parse(body)
            data.length.should.equal 0

            request.get
              jar: jar0
              url: baseUri + "/messagedata/test1/0/-1"
              (err, res, body) ->
                if err
                  done err
                else
                  res.statusCode.should.equal 204
                  done()

    it 'the other user should have 3 of his messages left', (done) ->
      request.get
        jar: jar1
        url: baseUri + "/messages/test0/before/7"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 200
            data = JSON.parse(body)
            data.length.should.equal 3

            request.get
              jar: jar1
              url: baseUri + "/messagedata/test0/0/-1"
              (err, res, body) ->
                if err
                  done err
                else
                  res.statusCode.should.equal 200
                  data = JSON.parse(body)
                  data.messages.length.should.equal 3

                  JSON.parse(data.messages[0]).from.should.equal "test1"
                  JSON.parse(data.messages[1]).from.should.equal "test1"
                  JSON.parse(data.messages[2]).from.should.equal "test1"

                  done()

    it 'the other user should be able to delete his messages', (done) ->
      request.del
        jar: jar1
        url: baseUri + "/messagesutai/test0/100"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 204
            done()


    it 'the other user should not have any messages left', (done) ->
      request.get
        jar: jar1
        url: baseUri + "/messages/test0/before/7"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 200
            data = JSON.parse(body)
            data.length.should.equal 0

            request.get
              jar: jar1
              url: baseUri + "/messagedata/test0/0/-1"
              (err, res, body) ->
                if err
                  done err
                else
                  res.statusCode.should.equal 204
                  done()

  describe 'delete friend', ->
    it 'send 3 messages from each user', (done) ->
      sendThreeMessagesFromEachUser(done)



    it 'should delete a user successfully', (done) ->
      request.del
        jar: jar0
        url: baseUri + "/friends/test1"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 204
            done()


    it 'should return 403 for message get by deleting user', (done) ->
      request.get
        jar: jar0
        url: baseUri + "/messages/test1/before/13"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 403
            done()

    it 'the deleted user should have 3 of his messages left', (done) ->
      request.get
        jar: jar1
        url: baseUri + "/messages/test0/before/13"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 200
            data = JSON.parse(body)
            data.length.should.equal 3

            request.get
              jar: jar1
              url: baseUri + "/messagedata/test0/0/-1"
              (err, res, body) ->
                if err
                  done err
                else
                  res.statusCode.should.equal 200
                  data = JSON.parse(body)
                  data.messages.length.should.equal 3

                  JSON.parse(data.messages[0]).from.should.equal "test1"
                  JSON.parse(data.messages[1]).from.should.equal "test1"
                  JSON.parse(data.messages[2]).from.should.equal "test1"

                  done()

    it 'the delete flag should be set on the deleting user for the deleted user', (done) ->
      request.get
        jar: jar1
        url: baseUri + "/friends"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 200
            data = JSON.parse(body)
            flags = parseInt(data.friends[0].flags)
            masked = flags & 1
            masked.should.equal 1
            done()


    it 'the delete flag should persist on invite from deleting user', (done) ->
      request.post
        jar: jar0
        url: baseUri + "/invite/test1"
        (err, res, body) ->
          if err
            done err
          else
            request.get
              jar: jar1
              url: baseUri + "/friends"
              (err, res, body) ->
                if err
                  done err
                else
                  res.statusCode.should.equal 200
                  data = JSON.parse(body)
                  flags = parseInt(data.friends[0].flags)
                  (flags & 1).should.equal 1
                  done()

    it 'should not be able to send message to someone who has deleted you', (done) ->
      client1.once 'messageError', (data) ->
        data.id.should.equal jsonMessage.iv
        data.status.should.equal 403
        done()


      client1.send JSON.stringify(jsonMessage)

    it 'accepting the invite should remove the delete flag', (done) ->
      request.post
        jar: jar1
        url: baseUri + "/invites/test0/accept"
        (err, res, body) ->
          if err
            done err
          else
            request.get
              jar: jar1
              url: baseUri + "/friends"
              (err, res, body) ->
                if err
                  done err
                else
                  res.statusCode.should.equal 200
                  data = JSON.parse(body)
                  flags = parseInt(data.friends["test0"])
                  (flags & 1).should.equal 0
                  done()



    it 'should delete the user successfully', (done) ->
      request.del
        jar: jar1
        url: baseUri + "/friends/test0"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 204
            done()


    it 'should return 403 for message get by deleting user', (done) ->
      request.get
        jar: jar1
        url: baseUri + "/messages/test0/before/13"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 403
            done()





  after (done) ->
    client.disconnect()
    client1.disconnect()
    if cleanupDb
      cleanup done
      #done()
    else
      done()