assert = require("assert")
should = require("should")
http = require("request")
redis = require("redis")
util = require("util")
crypto = require 'crypto'
dcrypt = require 'dcrypt'
async = require 'async'
fs = require("fs")
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


cleanup = (done) ->
  keys = [
    "u:test0",
    "u:test1",
    "u:test2",
    "f:test0",
    "f:test1",
    "fi:test0",
    "is:test0",
    "ir:test0",
    "is:test1",
    "ir:test1",
    "m:test0",
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
    "d:test2"]
  multi = rc.multi()

  multi.del keys
  multi.hdel "mcounters", "test0:test1"
  multi.hdel "ucmcounters", "test0"
  multi.hdel "ucmcounters", "test1"

  multi.srem "u", "test0", "test1", "test2"
  multi.exec (err, results) ->
    return done err if err?
    pool.connect (err, keyspace) ->
      return done err if err?

      cql = "begin batch
               delete from chatmessages where username = ?
               delete from chatmessages where username = ?
               delete from usercontrolmessages where username = ?
               delete from usercontrolmessages where username = ?
               delete from frienddata where username = ?
               delete from frienddata where username = ?
                 apply batch"

      pool.cql cql, ["test0", "test1", "test0", "test1", "test0", "test1"], (err, results) ->
        if err
          done err
        else
          done()


login = (username, password, authSig, done, callback) ->
  http.post
    url: baseUri + "/login"
    json:
      username: username
      password: password
      authSig2: authSig
      version: 60
      platform:'android'
    (err, res, body) ->
      if err
        done err
      else
        callback res, body

signup = (username, password, keys, done, callback) ->
  http.post
    url: baseUri + "/users2"
    json:
      username: username
      password: password
      dhPub: keys.ecdh.pem_pub
      dsaPub: keys.ecdsa.pem_pub
      authSig2: keys.authSig
      clientSig: keys.clientSig
      version: 60
      platform:'android'
    (err, res, body) ->
      if err
        done err
      else
        callback res, body



generateKey = (i, callback) ->
  ecdsa = new dcrypt.keypair.newECDSA 'secp521r1'
  ecdh = new dcrypt.keypair.newECDSA 'secp521r1'

#  random = crypto.randomBytes 16

#  dsaPubSig =
#    crypto
#      .createSign('sha256')
#      .update(new Buffer("test#{i}"))
#      .update(new Buffer("test#{i}"))
#      .update(random)
#      .sign(ecdsa.pem_priv, 'base64')

  authSig = sign ecdsa.pem_priv, new Buffer("test#{i}"), new Buffer("test#{i}")
    #Buffer.concat([random, new Buffer(dsaPubSig, 'base64')]).toString('base64')
  clientSig = signClient ecdsa.pem_priv, "test#{i}", 1, ecdh.pem_pub

  callback null, {
    ecdsa: ecdsa
    ecdh: ecdh
    authSig: authSig
    clientSig: clientSig
  }

generateKeyVersion = (i, version, firstDsa, callback) ->
  ecdsa = new dcrypt.keypair.newECDSA 'secp521r1'
  ecdh = new dcrypt.keypair.newECDSA 'secp521r1'
#  authSig = sign ecdsa.pem_priv, new Buffer("test#{i}"), new Buffer("test#{i}")
  clientSig = signClient firstDsa, "test#{i}", version, ecdh.pem_pub

  callback null, {
    ecdsa: ecdsa
    ecdh: ecdh
 #   authSig: authSig
    clientSig: clientSig
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


signClient = (priv, username, version, dhPubKey) ->
  vbuffer = new Buffer(4)
  vbuffer.writeInt32BE(version, 0)

  clientSig =
    crypto
    .createSign('sha256')
    .update(new Buffer(username))
    .update(vbuffer)
    .update(new Buffer(dhPubKey))
    .sign(priv, 'base64')

  return clientSig

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


describe "auth 2 tests", () ->
  keys = undefined
  oldKeys = []
  before (done) ->
    createKeys 3, (err, keyss) ->
      keys = keyss
      if cleanupDb
        cleanup done
      else
        done()

  describe "create user", () ->
    it "should respond with 400 if username invalid", (done) ->
      signup "012345678901234567890", "test0", keys[0], done, (res, body) ->
        res.statusCode.should.equal 400
        done()

    it "should respond with 400 if username empty", (done) ->
      signup '', "test0", keys[0], done, (res, body) ->
        res.statusCode.should.equal 400
        done()

    it "should respond with 400 if password too long", (done) ->
      random = crypto.randomBytes 1025
      pw = random.toString('hex')
      signup "test0", pw, keys[0], done, (res, body) ->
        res.statusCode.should.equal 400
        done()


    it "should respond with 201", (done) ->
      signup "test0", "test0", keys[0], done, (res, body) ->
        res.statusCode.should.equal 201
        done()

    it "and subsequently exist", (done) ->
      http.get
        url: baseUri + "/users/test0/exists",
        (err, res, body) ->
          if err
            done err
          else
            body.should.equal "true"
            done()

    #    it "even if the request case is different", (done) ->
    #      http.get
    #        url: baseUri + "/users/TEST/exists",
    #        (err,res,body) ->
    #          if err
    #            done err
    #          else
    #            body.should.equal "true"
    #            done()

    it "shouldn't be allowed to be created again", (done) ->
      signup "test0", "test0", keys[0], done, (res, body) ->
        res.statusCode.should.equal 409
        done()

  #    it "even if the request case is different", (done) ->
  #      signup "tEsT", "test", keys[0].ecdh.pem_pub, keys[0].ecdsa.pem_pub, keys[0].sig, done, (res, body) ->
  #        res.statusCode.should.equal 409
  #        done()


    it "should be able to roll the key pair", (done) ->

      http.post
        url: baseUri + "/keytoken2"
        json:
          username: "test0"
          password: "test0"
          authSig2: keys[0].authSig
          #clientSig: keys[0].clientSig
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 200
            body.keyversion.should.equal 2
            body.token.should.exist


            oldKeys[0] = keys[0]
            #generate new key pairs, sign with first dsa key
            generateKeyVersion 0, body.keyversion, oldKeys[0].ecdsa.pem_priv, (err, nkp) ->

              keys[0] = nkp

              tokenSig = sign oldKeys[0].ecdsa.pem_priv, new Buffer(body.token, 'base64'), "test0"

              http.post
                url: baseUri + "/keys2"
                json:
                  username: "test0"
                  password: "test0"
                  authSig2: oldKeys[0].authSig
                  dhPub: keys[0].ecdh.pem_pub
                  dsaPub: keys[0].ecdsa.pem_pub
                  keyVersion: body.keyversion
                  tokenSig: tokenSig
                  clientSig: keys[0].clientSig
                (err, res, body) ->
                  if err
                    done err
                  else
                    res.statusCode.should.equal 201
                    done()

#
  describe "should not be able to login with the new signature", ->
    it "should return 401", (done) ->
      login "test0", "test0", keys[0].authSig, done, (res, body) ->
        res.statusCode.should.equal 401
        done()
#
  describe "login with invalid password", ->
    it "should return 401", (done) ->
      login "test0", "bollocks", oldKeys[0].sig, done, (res, body) ->
        res.statusCode.should.equal 401
        done()

  describe "login with short signature", ->
    it "should return 401", (done) ->
      login "test0", "test0", "martin", done, (res, body) ->
        res.statusCode.should.equal 401
        done()
#
#
  describe "login with invalid signature", ->
    it "should return 401", (done) ->
      login "test0", "test0", "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Aenean venenatis dictum viverra. Duis vel justo vel purus hendrerit consequat. Duis ac nisi at ante elementum faucibus in eget lorem. Morbi cursus blandit sollicitudin. Aenean tincidunt, turpis eu malesuada venenatis, urna eros sagittis augue, et vehicula quam turpis at risus. Sed ac orci a tellus semper tincidunt eget non lorem. In porta nisi eu elit porttitor pellentesque vestibulum purus luctus. Nam venenatis porta porta. Vestibulum eget orci massa. Fusce laoreet vestibulum lacus ut hendrerit. Proin ac eros enim, ac faucibus eros. Aliquam erat volutpat.",
      done, (res, body) ->
        res.statusCode.should.equal 401
        done()
#
  describe "login with non existant user", ->
    it "should return 401", (done) ->
      login "your", "mama", "what kind of sig is this?", done, (res, body) ->
        res.statusCode.should.equal 401
        done()
#
#
  describe "login with valid credentials", ->
    it "should return 204", (done) ->
      login "test0", "test0", oldKeys[0].authSig, done, (res, body) ->
        res.statusCode.should.equal 204
        done()


  #todo set filename explicitly
  after (done) ->
    if cleanupDb
      cleanup done
    else
      done()