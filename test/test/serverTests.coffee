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
      authSig: authSig
      version: 56
      platform:'android'
    (err, res, body) ->
      if err
        done err
      else
        callback res, body

signup = (username, password, dhPub, dsaPub, authSig, done, callback) ->
  http.post
    url: baseUri + "/users"
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

  sig = sign ecdsa.pem_priv, new Buffer("test#{i}"), new Buffer("test#{i}")
    #Buffer.concat([random, new Buffer(dsaPubSig, 'base64')]).toString('base64')

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


describe "surespot server", () ->
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
      signup "012345678901234567890", "test0", keys[0].ecdh.pem_pub, keys[0].ecdsa.pem_pub, keys[0].sig, done, (res, body) ->
        res.statusCode.should.equal 400
        done()

    it "should respond with 400 if username empty", (done) ->
      signup '', "test0", keys[0].ecdh.pem_pub, keys[0].ecdsa.pem_pub, keys[0].sig, done, (res, body) ->
        res.statusCode.should.equal 400
        done()

    it "should respond with 400 if password too long", (done) ->
      random = crypto.randomBytes 1025
      pw = random.toString('hex')
      signup "test0", pw, keys[0].ecdh.pem_pub, keys[0].ecdsa.pem_pub, keys[0].sig, done, (res, body) ->
        res.statusCode.should.equal 400
        done()


    it "should respond with 201", (done) ->
      signup "test0", "test0", keys[0].ecdh.pem_pub, keys[0].ecdsa.pem_pub, keys[0].sig, done, (res, body) ->
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
      signup "test0", "test0", keys[0].ecdh.pem_pub, keys[0].ecdsa.pem_pub, keys[0].sig, done, (res, body) ->
        res.statusCode.should.equal 409
        done()

  #    it "even if the request case is different", (done) ->
  #      signup "tEsT", "test", keys[0].ecdh.pem_pub, keys[0].ecdsa.pem_pub, keys[0].sig, done, (res, body) ->
  #        res.statusCode.should.equal 409
  #        done()


    it "should be able to roll the key pair", (done) ->

      http.post
        url: baseUri + "/keytoken"
        json:
          username: "test0"
          password: "test0"
          authSig: keys[0].sig
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 200
            body.keyversion.should.equal 2
            body.token.should.exist



            #generate new key pairs
            generateKey 0, (err, nkp) ->
              oldKeys[0] = keys[0]
              keys[0] = nkp

              tokenSig = sign oldKeys[0].ecdsa.pem_priv, new Buffer(body.token, 'base64'), "test0"

              http.post
                url: baseUri + "/keys"
                json:
                  username: "test0"
                  password: "test0"
                  authSig: oldKeys[0].sig,
                  dhPub: keys[0].ecdh.pem_pub,
                  dsaPub: keys[0].ecdsa.pem_pub
                  keyVersion: body.keyversion
                  tokenSig: tokenSig
                (err, res, body) ->
                  if err
                    done err
                  else
                    res.statusCode.should.equal 201
                    done()

#
    it "should not be able to login with the old signature", (done) ->
      login "test0", "test0", oldKeys[0].sig, done, (res, body) ->
        res.statusCode.should.equal 401
        done()


  describe "login with invalid password", ->
    it "should return 401", (done) ->
      login "test0", "bollocks", keys[0].sig, done, (res, body) ->
        res.statusCode.should.equal 401
        done()

  describe "login with short signature", ->
    it "should return 401", (done) ->
      login "test0", "test0", "martin", done, (res, body) ->
        res.statusCode.should.equal 401
        done()


  describe "login with invalid signature", ->
    it "should return 401", (done) ->
      login "test0", "test0", "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Aenean venenatis dictum viverra. Duis vel justo vel purus hendrerit consequat. Duis ac nisi at ante elementum faucibus in eget lorem. Morbi cursus blandit sollicitudin. Aenean tincidunt, turpis eu malesuada venenatis, urna eros sagittis augue, et vehicula quam turpis at risus. Sed ac orci a tellus semper tincidunt eget non lorem. In porta nisi eu elit porttitor pellentesque vestibulum purus luctus. Nam venenatis porta porta. Vestibulum eget orci massa. Fusce laoreet vestibulum lacus ut hendrerit. Proin ac eros enim, ac faucibus eros. Aliquam erat volutpat.",
      done, (res, body) ->
        res.statusCode.should.equal 401
        done()

  describe "login with non existant user", ->
    it "should return 401", (done) ->
      login "your", "mama", "what kind of sig is this?", done, (res, body) ->
        res.statusCode.should.equal 401
        done()


  describe "login with valid credentials", ->
    it "should return 204", (done) ->
      login "test0", "test0", keys[0].sig, done, (res, body) ->
        res.statusCode.should.equal 204
        done()

  describe 'validate valid user', ->
    it "should return 204", (done) ->
      http.post
        url: baseUri + "/validate"
        json:
          username: 'test0'
          password: 'test0'
          authSig: keys[0].sig
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 204
            done()


  describe "invite exchange", ->
    it "created user", (done) ->
      signup "test1", "test1", keys[1].ecdh.pem_pub, keys[1].ecdsa.pem_pub, keys[1].sig, done, (res, body) ->
        res.statusCode.should.equal 201
        done()

    it "should not be allowed to invite himself", (done) ->
      http.post
        url: baseUri + "/invite/test1"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 403
            done()


    it "who invites a user successfully should receive 204", (done) ->
      http.post
        url: baseUri + "/invite/test0"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 204
            done()

    it "who invites them again should receive 403", (done) ->
      http.post
        url: baseUri + "/invite/test0"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 403
            done()

    it "who accepts their invite should receive 204", (done) ->
      login "test0", "test0", keys[0].sig, done, (res, body) ->
        http.post
          url: baseUri + "/invites/test1/accept"
          (err, res, body) ->
            if err
              done err
            else
              res.statusCode.should.equal 204
              done()

    it "who accepts a non existent invite should receive 404", (done) ->
      http.post
        url: baseUri + "/invites/nosuchinvite/accept"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 404
            done()


    it "who invites them again should receive a 409", (done) ->
      http.post
        url: baseUri + "/invite/test1"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 409
            done()


  describe "inviting non existent user", ->
    it "should return 404", (done) ->
      http.post
        url: baseUri + "/invites/nosuchuser"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 404
            done()


  describe "getting the public identity of a non existant user", ->
    it "should return not found", (done) ->
      http.get
        url: baseUri + "/publicidentity/nosuchuser"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 404
            done()

  describe "getting the public identity of a non friend user", ->
    it "should not be allowed", (done) ->
      signup "test2", "test2", keys[2].ecdh.pem_pub, keys[2].ecdsa.pem_pub, keys[2].sig, done, (res, body) ->
        res.statusCode.should.equal 201
        http.get
          url: baseUri + "/publickeys/test0"
          (err, res, body) ->
            if err
              done err
            else
              res.statusCode.should.equal 403
              done()

  describe "getting other user's message data", ->
    it "should not be allowed", (done) ->
      http.get
        url: baseUri + "/messagedata/test0/0/0"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 403
            done()

  describe "getting other user's messages after x", ->
    it "should not be allowed", (done) ->
      http.get
        url: baseUri + "/messagedata/test0/0/0"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 403
            done()

  describe "getting other user's messages before x", ->
    it "should not be allowed", (done) ->
      http.get
        url: baseUri + "/messages/test0/before/100"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 403
            done()

  describe "uploading an image to a valid spot", ->
    it "should return the 200", (done) ->
      login "test0", "test0", keys[0].sig, done, (res, body) ->
        res.statusCode.should.equal 204
        r = http.post baseUri + "/images/1/test1/1", (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 200
            done()

        form = r.form()
        form.append "image", fs.createReadStream "test/testImage"

  #todo add test to make sure we receive associated message and download the image

  describe "uploading an image for a friend ", ->
    location = undefined
    it "should return 200 and the image url", (done) ->
      login "test0", "test0", keys[0].sig, done, (res, body) ->
        res.statusCode.should.equal 204
        r = http.post baseUri + "/images/test1/1", (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 200
            location = body
            should.exists location
            done()

        form = r.form()
        form.append "image", fs.createReadStream "test/testImage"
    #todo set filename explicitly

    it "should return the same friend image when url requested", (done) ->
      http.get
        url: location
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 200
            res.body.should.equal "madman\n"
            done()

  describe "uploading an image to a spot we don't belong to", ->
    it "should not be allowed", (done) ->
      login "test2", "test2", keys[2].sig, done, (res, body) ->
        res.statusCode.should.equal 204

        r = http.post baseUri + "/images/1/test1/1", (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 403
            done()

        form = r.form()
        form.append "image", fs.createReadStream "test/testImage", { contentType: "image/"}


  #todo set filename explicitly
  after (done) ->
    if cleanupDb
      cleanup done
    else
      done()