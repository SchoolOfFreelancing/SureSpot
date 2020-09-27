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
baseUri = process.env.SURESPOT_TEST_BASEURI ? "http://127.0.0.1:8080"
cleanupDb = process.env.SURESPOT_TEST_CLEANDB is "true"
useRedisSentinel = process.env.SURESPOT_USE_REDIS_SENTINEL is "true"

pool = new helenus.ConnectionPool({host:'127.0.0.1', port:9160, keyspace:'surespot'});


rc = if useRedisSentinel then redisSentinel.createClient(redisSentinelPort, redisSentinelHostname) else redis.createClient(redisSentinelPort, redisSentinelHostname)
port = socketPort

jars = []
cookies = []
clients = []
jsonMessage = {type: "message", to: "test0", toVersion: "1", from: "test1", fromVersion: "1", iv: 1, data: "message data", mimeType: "text/plain"}
localid = 0



cleanup = (done) ->
  multi = rc.multi()

  buildKeys = (i) ->
    multi.del "u:test#{i}"
    multi.del "k:test#{i}"
    multi.del "kv:test#{i}"
    multi.del "ud:test#{i}"
    multi.del "f:test#{i}"
    multi.del "f:test#{i}"
    multi.del "is:test#{i}"
    multi.del "ir:test#{i}"
    multi.del "c:test#{i}"
    multi.srem "u", "test#{i}"
    multi.srem "d", "test#{i}"

  for i in [0..2]
    buildKeys i

  multi.hdel "mcounters", "test0:test1"
  multi.hdel "mcounters", "test0:test2"
  multi.hdel "mcmcounters", "test0:test1"
  multi.hdel "mcmcounters", "test0:test2"
  multi.hdel "ucmcounters", "test0"
  multi.hdel "ucmcounters", "test1"
  multi.hdel "ucmcounters", "test2"
  multi.del("d:test0")
  multi.del("m:test1")
  multi.del("m:test2")


  multi.exec (err, blah) ->
    return done err if err?
    pool.connect (err, keyspace) ->
      return done err if err?

      cql = "begin batch
         delete from chatmessages where username = ?
         delete from chatmessages where username = ?
         delete from chatmessages where username = ?
         delete from messagecontrolmessages where username = ?
         delete from messagecontrolmessages where username = ?
         delete from messagecontrolmessages where username = ?
         delete from usercontrolmessages where username = ?
         delete from usercontrolmessages where username = ?
         delete from usercontrolmessages where username = ?
         apply batch"

      pool.cql cql, ["test0", "test1", "test2","test0", "test1","test2","test0", "test1","test2"], (err, results) ->
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



sign = (priv, b1, b2) ->
  random = crypto.randomBytes 16

  dsaPubSig =
    crypto
      .createSign('sha256')
      .update(b1)
      .update(b2)
      .update(random)
      .sign(priv, 'base64')

  return Buffer.concat([random, new Buffer(dsaPubSig, 'base64')]).toString('base64')

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


sendMessages = (clientNum, to, number, callback) ->
  async.each(
    [1..number],
    (item, callback) ->
      jsonMessage.from = "test#{clientNum}"
      jsonMessage.to = to
      jsonMessage.iv = "#{localid++}"
      clients[clientNum].once 'message', ->
        callback()
      clients[clientNum].send JSON.stringify(jsonMessage)
    (err) ->
      callback null)


describe "delete identity tests", () ->
  keys = undefined
  before (done) ->
    createKeys 3, (err, keyss) ->
      keys = keyss
      if cleanupDb
        cleanup done
      else
        done()


  it 'connect clients', (done) ->
    async.each(
      [0..2],
      (i, callback) ->
        jars[i] = request.jar()
        signup "test#{i}", "test#{i}", jars[i], keys[i].ecdh.pem_pub, keys[i].ecdsa.pem_pub, keys[i].sig, done, (res, body, cookie) ->
          clients[i] = io.connect baseUri, { 'force new connection': true}, cookie
          cookies[i] = cookie
          clients[i].once 'connect', ->
            callback()
      (err) ->
        return done err if err?
        done() )

  it 'become friends', (done) ->
    request.post
      jar: jars[0]
      url: baseUri + "/invite/test1"
      (err, res, body) ->
        if err
          done err
        else
          request.post
            jar: jars[0]
            url: baseUri + "/invite/test2"
            (err, res, body) ->
              if err
                done err
              else
                request.post
                  jar: jars[1]
                  url: baseUri + "/invites/test0/accept"
                  (err, res, body) ->
                    if err
                      done err
                    else
                      request.post
                        jar: jars[2]
                        url: baseUri + "/invites/test0/accept"
                        (err, res, body) ->
                          if err
                            done err
                          else
                            done()


  it 'send 3 messages for each friend pair', (done) ->
    tasks = []
    tasks.push (callback) -> sendMessages(0, 'test1', 3, callback)
    tasks.push (callback) -> sendMessages(1, 'test0', 3, callback)
    tasks.push (callback) -> sendMessages(0, 'test2', 3, callback)
    tasks.push (callback) -> sendMessages(2, 'test0', 3, callback)

    async.parallel(
      tasks
      (err,results) ->
        done())

  it 'can delete identity successfully', (done) ->

    request.post
      url: baseUri + "/deletetoken"
      jar: jars[0]
      json:
        username: "test0"
        password: "test0"
        authSig: keys[0].sig
      (err, res, body) ->
        if err
          done err
        else
          res.statusCode.should.equal 200
          body.should.exist
          tokenSig = sign keys[0].ecdsa.pem_priv, new Buffer(body, 'base64'), "test0"

          request.post
            url: baseUri + "/users/delete"
            jar: jars[0]
            json:
              username: "test0"
              password: "test0"
              authSig: keys[0].sig,
              dhPub: keys[0].ecdh.pem_pub,
              dsaPub: keys[0].ecdsa.pem_pub
              keyVersion: 1
              tokenSig: tokenSig
            (err, res, body) ->
              if err
                done err
              else
                res.statusCode.should.equal 204
                done()


  it 'each remaining user should have 3 of his messages left', (done) ->
    request.get
      jar: jars[1]
      url: baseUri + "/messages/test0/before/13"
      (err, res, body) ->
        if err
          done err
        else
          res.statusCode.should.equal 200
          data = JSON.parse(body)
          data.length.should.equal 3

          JSON.parse(data[0]).from.should.equal "test1"
          JSON.parse(data[1]).from.should.equal "test1"
          JSON.parse(data[2]).from.should.equal "test1"

          request.get
            jar: jars[1]
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

                request.get
                  jar: jars[2]
                  url: baseUri + "/messages/test0/before/13"
                  (err, res, body) ->
                    if err
                      done err
                    else
                      res.statusCode.should.equal 200
                      data = JSON.parse(body)
                      data.length.should.equal 3

                      JSON.parse(data[0]).from.should.equal "test2"
                      JSON.parse(data[1]).from.should.equal "test2"
                      JSON.parse(data[2]).from.should.equal "test2"

                      request.get
                        jar: jars[2]
                        url: baseUri + "/messagedata/test0/0/-1"
                        (err, res, body) ->
                          if err
                            done err
                          else
                            res.statusCode.should.equal 200
                            data = JSON.parse(body)
                            data.messages.length.should.equal 3

                            JSON.parse(data.messages[0]).from.should.equal "test2"
                            JSON.parse(data.messages[1]).from.should.equal "test2"
                            JSON.parse(data.messages[2]).from.should.equal "test2"

                            done()

  it 'the delete flag should be set on the deleting user for the deleted user', (done) ->
    request.get
      jar: jars[1]
      url: baseUri + "/friends"
      (err, res, body) ->
        if err
          done err
        else
          res.statusCode.should.equal 200
          data = JSON.parse(body)
          flags = parseInt(data.friends["test0"])
          flags & 1.should.equal 1
          done()

  it 'should not be able to send message to someone who has deleted you', (done) ->
    clients[1].once 'messageError', (data) ->
      data.id.should.equal jsonMessage.iv
      data.status.should.equal 404
      done()


    jsonMessage.from = "test1"
    jsonMessage.to = "test0"
    jsonMessage.iv = localid++
    clients[1].send JSON.stringify(jsonMessage)

  describe 'delete deleted users friends', ->
    it 'should not allow creating of deleted user when friends remain that had the deleted user as a friend', (done) ->
      request.del
        jar: jars[1]
        url: baseUri + "/friends/test0"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 204
            signup "test0", "test0", jars[0], keys[0].ecdh.pem_pub, keys[0].ecdsa.pem_pub, keys[0].sig, done, (res, body, cookie) ->
              res.statusCode.should.equal 409
              done()

    it 'should allow creating of deleted user when no friends remain that had the deleted user as a friend', (done) ->
      request.del
        jar: jars[2]
        url: baseUri + "/friends/test0"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 204
            signup "test0", "test0", jars[0], keys[0].ecdh.pem_pub, keys[0].ecdsa.pem_pub, keys[0].sig, done, (res, body, cookie) ->
              res.statusCode.should.equal 201
              done()

  describe 'can delete all the identities', ->
    it 'can delete test0', (done) ->
      request.post
        url: baseUri + "/deletetoken"
        jar: jars[0]
        json:
          username: "test0"
          password: "test0"
          authSig: keys[0].sig
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 200
            body.should.exist
            tokenSig = sign keys[0].ecdsa.pem_priv, new Buffer(body, 'base64'), "test0"

            request.post
              url: baseUri + "/users/delete"
              jar: jars[0]
              json:
                username: "test0"
                password: "test0"
                authSig: keys[0].sig,
                dhPub: keys[0].ecdh.pem_pub,
                dsaPub: keys[0].ecdsa.pem_pub
                keyVersion: 1
                tokenSig: tokenSig
              (err, res, body) ->
                if err
                  done err
                else
                  res.statusCode.should.equal 204
                  done()


    it 'can delete test1', (done) ->
      request.post
        url: baseUri + "/deletetoken"
        jar: jars[1]
        json:
          username: "test1"
          password: "test1"
          authSig: keys[1].sig
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 200
            body.should.exist
            tokenSig = sign keys[1].ecdsa.pem_priv, new Buffer(body, 'base64'), "test1"

            request.post
              url: baseUri + "/users/delete"
              jar: jars[1]
              json:
                username: "test1"
                password: "test1"
                authSig: keys[1].sig,
                dhPub: keys[1].ecdh.pem_pub,
                dsaPub: keys[1].ecdsa.pem_pub
                keyVersion: 1
                tokenSig: tokenSig
              (err, res, body) ->
                if err
                  done err
                else
                  res.statusCode.should.equal 204
                  done()

    it 'can delete test2', (done) ->
      request.post
        url: baseUri + "/deletetoken"
        jar: jars[2]
        json:
          username: "test2"
          password: "test2"
          authSig: keys[2].sig
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 200
            body.should.exist
            tokenSig = sign keys[2].ecdsa.pem_priv, new Buffer(body, 'base64'), "test2"

            request.post
              url: baseUri + "/users/delete"
              jar: jars[2]
              json:
                username: "test2"
                password: "test2"
                authSig: keys[2].sig,
                dhPub: keys[2].ecdh.pem_pub,
                dsaPub: keys[2].ecdsa.pem_pub
                keyVersion: 1
                tokenSig: tokenSig
              (err, res, body) ->
                if err
                  done err
                else
                  res.statusCode.should.equal 204
                  done()


  after (done) ->
    clients[0].disconnect()
    clients[1].disconnect()
    clients[2].disconnect()
    if cleanupDb
      #cleanup done
      done()
    else
      done()