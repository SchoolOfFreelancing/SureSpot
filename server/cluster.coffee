###

  surespot node.js server
  copyright 2fours LLC
  written by Adam Patacchiola adam@2fours.com

###
env = process.env.SURESPOT_ENV ? 'Local' # one of "Local","Stage", "Prod"

cluster = require('cluster')
cookie = require("cookie")
express = require("express")
passport = require("passport")
LocalStrategy = require("passport-local").Strategy
crypto = require 'crypto'
RedisStore = require("connect-redis")(express)
util = require("util")
gcm = require("node-gcm")
fs = require("fs")
bcrypt = require 'bcrypt'
mkdirp = require("mkdirp")
async = require 'async'
_ = require 'underscore'
querystring = require 'querystring'
formidable = require 'formidable'
pkgcloud = require 'pkgcloud'
utils = require('connect/lib/utils')
pause = require 'pause'
stream = require 'stream'
redbacklib = require 'redback'
googleapis = require 'googleapis'
apn = require 'apn'
uaparser = require 'ua-parser'
bunyan = require 'bunyan'
IAPVerifier = require 'iap_verifier'
cdb = require './cdb'
common = require './common'

#constants
USERNAME_LENGTH = 20
CONTROL_MESSAGE_HISTORY = 100
MAX_MESSAGE_LENGTH = 500000
MAX_HTTP_REQUEST_LENGTH = 500000
NUM_CORES =  parseInt(process.env.SURESPOT_CORES, 10) ? 4
GCM_TTL = 604800
GCM_RETRIES = 6

oneYear = 31536000000
oneDay = 86400

#config

#rate limit to MESSAGE_RATE_LIMIT_RATE / MESSAGE_RATE_LIMIT_SECS (seconds) (allows us to get request specific on top of iptables)
RATE_LIMITING_MESSAGE=process.env.SURESPOT_RATE_LIMITING_MESSAGE is "true"
RATE_LIMIT_BUCKET_MESSAGE = process.env.SURESPOT_RATE_LIMIT_BUCKET_MESSAGE ? 5
RATE_LIMIT_SECS_MESSAGE = process.env.SURESPOT_RATE_LIMIT_SECS_MESSAGE ? 10
RATE_LIMIT_RATE_MESSAGE = process.env.SURESPOT_RATE_LIMIT_RATE_MESSAGE ? 100

MESSAGES_PER_USER = process.env.SURESPOT_MESSAGES_PER_USER ? 500
MAX_GCM_SOCKETS = process.env.SURESPOT_MAX_GCM_SOCKETS ? 30
debugLevel = process.env.SURESPOT_DEBUG_LEVEL ? 'debug'
database = process.env.SURESPOT_DB ? 0
socketPort = process.env.SURESPOT_SOCKET ? 8080
googleApiKey = process.env.SURESPOT_GOOGLE_API_KEY
googleClientId = process.env.SURESPOT_GOOGLE_CLIENT_ID
googleClientSecret = process.env.SURESPOT_GOOGLE_CLIENT_SECRET
googleRedirectUrl = process.env.SURESPOT_GOOGLE_REDIRECT_URL
googleOauth2Code = process.env.SURESPOT_GOOGLE_OAUTH2_CODE
rackspaceApiKey = process.env.SURESPOT_RACKSPACE_API_KEY
rackspaceCdnImageBaseUrl = process.env.SURESPOT_RACKSPACE_IMAGE_CDN_URL
rackspaceCdnVoiceBaseUrl = process.env.SURESPOT_RACKSPACE_VOICE_CDN_URL
rackspaceImageContainer = process.env.SURESPOT_RACKSPACE_IMAGE_CONTAINER
rackspaceVoiceContainer = process.env.SURESPOT_RACKSPACE_VOICE_CONTAINER
rackspaceUsername = process.env.SURESPOT_RACKSPACE_USERNAME
iapSecret = process.env.SURESPOT_IAP_SECRET
sessionSecret = process.env.SURESPOT_SESSION_SECRET
logConsole = process.env.SURESPOT_LOG_CONSOLE is "true"
redisPort = process.env.REDIS_PORT
redisSentinelPort = parseInt(process.env.SURESPOT_REDIS_SENTINEL_PORT, 10) ? 6379
redisSentinelHostname = process.env.SURESPOT_REDIS_SENTINEL_HOSTNAME ? "127.0.0.1"
redisPassword = process.env.SURESPOT_REDIS_PASSWORD ? null
useRedisSentinel = process.env.SURESPOT_USE_REDIS_SENTINEL is "true"
bindAddress = process.env.SURESPOT_BIND_ADDRESS ? "0.0.0.0"
dontUseSSL = process.env.SURESPOT_DONT_USE_SSL is "true"
apnGateway = process.env.SURESPOT_APN_GATEWAY
useSSL = not dontUseSSL

http = if useSSL then require 'https' else require 'http'

numCPUs = require('os').cpus().length

if NUM_CORES > numCPUs then NUM_CORES = numCPUs

#log to stdout to send to journal
bunyanStreams = [{
    level: debugLevel
    stream: process.stdout
  }]

if env is 'Local'
  bunyanStreams.push {
    level: 'debug'
    path: "logs/surespot.log"
  }


logger = bunyan.createLogger({
  name: 'surespot'
  streams: bunyanStreams
});



logger.debug "__dirname: #{__dirname}"

if (cluster.isMaster and NUM_CORES > 1)
  # Fork workers.
  for i in [0..NUM_CORES-1]
    cluster.fork();

  cluster.on 'online', (worker, code, signal) ->
    logger.debug 'worker ' + worker.process.pid + ' online'

  cluster.on 'exit', (worker, code, signal) ->
    logger.debug "worker #{worker.process.pid} died, forking another"
    cluster.fork()

  logger.warn "env: #{env}"
  logger.warn "database: #{database}"
  logger.warn "socket: #{socketPort}"
  logger.warn "address: #{bindAddress}"
  logger.warn "ssl: #{useSSL}"
  logger.warn "rate limiting messages: #{RATE_LIMITING_MESSAGE}, int: #{RATE_LIMIT_BUCKET_MESSAGE}, secs: #{RATE_LIMIT_SECS_MESSAGE}, rate: #{RATE_LIMIT_RATE_MESSAGE}"
  logger.warn "messages per user: #{MESSAGES_PER_USER}"
  logger.warn "debug level: #{debugLevel}"
  logger.warn "google api key: #{googleApiKey}"
  logger.warn "google client id: #{googleClientId}"
  logger.warn "google client secret: #{googleClientSecret}"
  logger.warn "google redirect url: #{googleRedirectUrl}"
  logger.warn "google oauth2 code: #{googleOauth2Code}"
  logger.warn "apple apn gateway: #{apnGateway}"
  logger.warn "rackspace api key: #{rackspaceApiKey}"
  logger.warn "rackspace image cdn url: #{rackspaceCdnImageBaseUrl}"
  logger.warn "rackspace image container: #{rackspaceImageContainer}"
  logger.warn "rackspace voice cdn url: #{rackspaceCdnVoiceBaseUrl}"
  logger.warn "rackspace voice container: #{rackspaceVoiceContainer}"
  logger.warn "rackspace username: #{rackspaceUsername}"
  logger.warn "iap secret: #{iapSecret}"
  logger.warn "session secret: #{sessionSecret}"
  logger.warn "cores: #{NUM_CORES}"
  logger.warn "console logging: #{logConsole}"
  logger.warn "use redis sentinel: #{useRedisSentinel}"
  logger.warn "redis sentinel hostname: #{redisSentinelHostname}"
  logger.warn "redis sentinel port: #{redisSentinelPort}"
  logger.warn "redis password: #{redisPassword}"
  logger.warn "cassandra urls: #{process.env.SURESPOT_CASSANDRA_IPS ? '127.0.0.1'}"
  logger.warn "max gcm sockets: #{MAX_GCM_SOCKETS}"

else

  if NUM_CORES is 1
    logger.warn "env: #{env}"
    logger.warn "database: #{database}"
    logger.warn "socket: #{socketPort}"
    logger.warn "address: #{bindAddress}"
    logger.warn "ssl: #{useSSL}"
    logger.warn "rate limiting messages: #{RATE_LIMITING_MESSAGE}, secs: #{RATE_LIMIT_SECS_MESSAGE}, rate: #{RATE_LIMIT_RATE_MESSAGE}"
    logger.warn "messages per user: #{MESSAGES_PER_USER}"
    logger.warn "debug level: #{debugLevel}"
    logger.warn "google api key: #{googleApiKey}"
    logger.warn "google client id: #{googleClientId}"
    logger.warn "google client secret: #{googleClientSecret}"
    logger.warn "google redirect url: #{googleRedirectUrl}"
    logger.warn "google oauth2 code: #{googleOauth2Code}"
    logger.warn "apple apn gateway: #{apnGateway}"
    logger.warn "rackspace api key: #{rackspaceApiKey}"
    logger.warn "rackspace image cdn url: #{rackspaceCdnImageBaseUrl}"
    logger.warn "rackspace image container: #{rackspaceImageContainer}"
    logger.warn "rackspace voice cdn url: #{rackspaceCdnVoiceBaseUrl}"
    logger.warn "rackspace voice container: #{rackspaceVoiceContainer}"
    logger.warn "rackspace username: #{rackspaceUsername}"
    logger.warn "iap secret: #{iapSecret}"
    logger.warn "session secret: #{sessionSecret}"
    logger.warn "cores: #{NUM_CORES}"
    logger.warn "console logging: #{logConsole}"
    logger.warn "redis sentinel hostname: #{redisSentinelHostname}"
    logger.warn "redis sentinel port: #{redisSentinelPort}"
    logger.warn "redis password: #{redisPassword}"
    logger.warn "use redis sentinel: #{useRedisSentinel}"
    logger.warn "cassandra urls: #{process.env.SURESPOT_CASSANDRA_IPS ? '127.0.0.1'}"
    logger.warn "max gcm sockets: #{MAX_GCM_SOCKETS}"

  sio = null
  sessionStore = null
  rc = null
  rcs = null
  pub = null
  sub = null
  redback = null
  client = null
  client2 = null
  app = null
  ssloptions = null
  oauth2Client = null
  iapClient = null

  cdb.connect (err) ->
    if err?
      logger.error 'could not connect to cassandra'
      process.exit(1)


  rackspace = pkgcloud.storage.createClient {provider: 'rackspace', username: rackspaceUsername, apiKey: rackspaceApiKey}

  apnOptions = { "gateway": apnGateway , "cert": "apn#{env}/cert.pem", "key": "apn#{env}/key.pem" }
  apnConnection = new apn.Connection(apnOptions);

  iapClient = new IAPVerifier iapSecret

  redis = null
  if useRedisSentinel
    redis = require 'redis-sentinel-client'
  else
    #use forked red
    redis = require 'redis'

  createRedisClient = (database, port, host, password) ->
    if port? and host?
      tempclient = null
      if useRedisSentinel
        sentinel = redis.createClient(port,host, {logger: logger})
        tempclient = sentinel.getMaster()

        sentinel.on 'error', (err) -> logger.error err
        tempclient.on 'error', (err) -> logger.error err
      else
        tempclient = redis.createClient(port,host)

      if password?
        tempclient.auth password
      #if database?
       # tempclient.select database
        #return tempclient
      else
        return tempclient
    else
      logger.debug "creating local redis client"
      tempclient = null

      if useRedisSentinel
        sentinel = redis.createClient(26379, "127.0.0.1", {logger: logger})
        tempclient = sentinel.getMaster()

        sentinel.on 'error', (err) -> logger.error err
        tempclient.on 'error', (err) -> logger.error err
      else
        tempclient = redis.createClient()

      if database?
        tempclient.select database
        return tempclient
      else
        return tempclient
  #ec
  serverPrivateKey = null
  serverPrivateKey = fs.readFileSync("ec#{env}/priv.pem")

  #ssl
  if useSSL
    ssloptions = {
    key: fs.readFileSync("ssl#{env}/surespot.key"),
    cert: fs.readFileSync("ssl#{env}/surespot.crt")
    }

    peerCertPath = "ssl#{env}/PositiveSSLCA2.crt"
    if fs.existsSync(peerCertPath)
      ssloptions["ca"] = fs.readFileSync(peerCertPath)

  # create EC keys like so
  # priv key
  # openssl ecparam -name secp521r1 -outform PEM -out priv.pem -genkey
  # pub key
  # openssl ec -inform PEM  -outform PEM -in priv.pem -out pub.pem -pubout
  #
  # verify signature like so
  # openssl dgst -sha256 -verify key -signature sig.bin data

  rc = createRedisClient database, redisSentinelPort, redisSentinelHostname, redisPassword
  rcs = createRedisClient database, redisSentinelPort, redisSentinelHostname, redisPassword
  pub = createRedisClient database, redisSentinelPort, redisSentinelHostname, redisPassword
  sub = createRedisClient database, redisSentinelPort, redisSentinelHostname, redisPassword
  client = createRedisClient database, redisSentinelPort, redisSentinelHostname, redisPassword
  client2 = createRedisClient database, redisSentinelPort, redisSentinelHostname, redisPassword

  redback = redbacklib.use rc
  ratelimitermessages = redback.createRateLimit('rlm', { bucket_interval: RATE_LIMIT_BUCKET_MESSAGE })


  app = express()

  app.configure ->
    app.use express.static(__dirname + '/public', { maxAge: oneYear })
    sessionStore = new RedisStore({
      client: client
    })
    app.use express.limit(MAX_HTTP_REQUEST_LENGTH)
    app.use express.compress()
    app.use express.cookieParser()
    app.use express.json()
    app.use express.urlencoded()
    app.set 'views', "#{__dirname}/views"
    app.set 'view engine', 'jade'

    #app.use(require('express-bunyan-logger')({name: 'surespot', streams : bunyanStreams }));
    app.use app.router
    #app.use(require('express-bunyan-logger').errorLogger({name: 'surespot', streams : bunyanStreams }));
    app.use (err, req, res, next) ->
      res.send err.status or 500

  http.globalAgent.maxSockets = Infinity

  server = if useSSL then http.createServer ssloptions, app else http.createServer app
  server.listen socketPort, bindAddress
  sio = require("socket.io").listen(server, {logger: logger})

  sioRedisStore = require("socket.io/lib/stores/redis")
  sio.set "store", new sioRedisStore(
    #use forked redis
    redis: require 'redis-sentinel-client/node_modules/redis'
    redisPub: pub
    redisSub: sub
    redisClient: client2
  )

  sio.set 'transports', ['websocket']
  sio.set 'destroy buffer size', MAX_MESSAGE_LENGTH
  sio.set 'browser client', false

  sio.set "authorization", (req, accept) ->
    logger.debug 'socket.io auth'
    if req.headers.cookie
      parsedCookie = cookie.parse(req.headers.cookie)
      connectSid = parsedCookie["connect.sid"]
      return accept null, false unless connectSid?

      req.sessionID = utils.parseSignedCookie(connectSid, sessionSecret)
      sessionStore.get req.sessionID, (err, session) ->
        if err or not session
          accept null, false
        else
          req.session = session
          if req.session.passport?.user?
            accept null, true
          else
            accept null, false
    else
      accept null, false

  typeIsArray = Array.isArray || ( value ) -> return {}.toString.call( value ) is '[object Array]'

  initSession = (req,res,next) ->
    mids = []
    mids.push express.session(
      secret: sessionSecret
      store: sessionStore
    #set cookie expiration in ms
      cookie: { maxAge: (oneDay*3000) }
      proxy: true
    )
    mids.push passport.initialize()
    mids.push passport.session({pauseStream: true})

    common.combineMiddleware(mids)(req,res,next)



  ensureAuthenticated = (req, res, next) ->
    mids = []
    mids.push express.session(
      secret: sessionSecret
      store: sessionStore
    #set cookie expiration in ms
      cookie: { maxAge: (oneDay*3000) }
      proxy: true
    )
    mids.push passport.initialize()
    mids.push passport.session({pauseStream: true})
    mids.push (req, res, next) ->
      logger.debug "ensureAuth"
      if req.isAuthenticated()
        logger.debug "authorized"
        next()
      else
        logger.debug "401"
        req.session?.destroy()
        res.send 401

    common.combineMiddleware(mids)(req,res,next)



  setNoCache = (req, res, next) ->
    res.setHeader "Cache-Control", "no-cache"
    next()

  setCache = (seconds) -> (req, res, next) ->
    res.setHeader "Cache-Control", "public, max-age=#{seconds}"
    next()

  userExists = (username, fn) ->
    rc.sismember "u", username, (err, isMember) ->
      return fn err if err?
      return fn null, if isMember then true else false


  userExistsOrDeleted = (username, checkReserved, fn) ->
    rc.sismember "u", username, (err, isMember) ->
      return fn err if err?
      return fn null, true if isMember
      rc.sismember "d", username, (err, isMember) ->
        return fn err if err?
        return fn null, true if isMember
        return fn null, false if not checkReserved
        rc.sismember "r", username, (err, isMember) ->
          return fn err if err?
          return fn null, true if isMember
          fn null, false


  checkUser = (username) ->
    #todo check for valid chars - letters or digits only
    return username?.length > 0 and username?.length  <= USERNAME_LENGTH


  checkPassword = (password) ->
    return password?.length > 0 and password?.length  <= 2048


  validateUsernamePassword = (req, res, next) ->
    username = req.body.username
    password = req.body.password

    if !checkUser(username) or !checkPassword(password)
      res.send 400
    else
      next()

  validateUsernameExists = (req, res, next) ->
    #pause and resume events - https://github.com/felixge/node-formidable/issues/213
    paused = pause req
    userExists req.params.username, (err, exists) ->
      if err?
        paused.resume()
        return next err


      if not exists
        paused.resume()
        return res.send 404


      next()
      paused.resume()

  validateUsernameExistsOrDeleted = (req, res, next) ->
    #pause and resume events - https://github.com/felixge/node-formidable/issues/213
    paused = pause req
    userExistsOrDeleted req.params.username, false, (err, exists) ->
      if err?
        paused.resume()
        return next err


      if not exists
        paused.resume()
        return res.send 404


      next()
      paused.resume()

  validateAreFriends = (req, res, next) ->
    #pause and resume events - https://github.com/felixge/node-formidable/issues/213
    paused = pause req
    username = req.user
    friendname = req.params.username
    isFriend username, friendname, (err, result) ->
      if err?
        paused.resume()
        return next err

      if result

        next()
        paused.resume()
      else
        paused.resume()
        res.send 403


  validateAreFriendsOrDeleted = (req, res, next) ->
    username = req.user
    friendname = req.params.username
    isFriend username, friendname, (err, result) ->
      return next err if err?
      if result
        next()
      else
        #if we're not friends check if he deleted himself
        rc.sismember "ud:#{username}", friendname, (err, isDeleted) ->
          return next err if err?
          if isDeleted
            next()
          else
            res.send 403

  validateAreFriendsOrDeletedOrMe = (req, res, next) ->
    username = req.user
    friendname = req.params.username
    return next() if username is friendname
    isFriend username, friendname, (err, result) ->
      return next err if err?
      if result
        next()
      else
        #if we're not friends check if he deleted himself
        rc.sismember "ud:#{username}", friendname, (err, isDeleted) ->
          return next err if err?
          if isDeleted
            next()
          else
            res.send 403


  validateAreFriendsOrDeletedOrInvited = (req, res, next) ->
    username = req.user
    friendname = req.params.username

    isFriend username, friendname, (err, result) ->
      return next err if err?
      if result
        next()
      else
        #we've been deleted
        rc.sismember "ud:#{username}", friendname, (err, isDeleted) ->
          return next err if err?
          if isDeleted
            next()
          else
            #we invited someone
            rc.sismember "is:#{username}", friendname, (err, isInvited) ->
              return next err if err?
              if isInvited
                next()
              else
                #nothing to do
                res.send 204


  #is friendname a friend of username
  isFriend = (username, friendname, callback) ->
    rc.sismember "f:#{username}", friendname, callback

  hasConversation = (username, room, callback) ->
    rc.sismember "c:#{username}", room, callback

  inviteExists = (username, friendname, callback) ->
    rc.sismember "is:#{username}", friendname, (err, result) =>
      return callback err if err?
      return callback null, false if not result
      rc.sismember "ir:#{friendname}", username, callback


  getPublicKeys = (req, res, next) ->
    username = req.params.username
    version = req.params.version

    if version?
      getKeys username, version, (err, keys) ->
        return next err if err?
        return res.send keys
    else
      getLatestKeys username, (err, keys) ->
        return next err if err
        res.send keys

  getPublicKeysSince = (req, res, next) ->
    username = req.params.username
    version = req.params.version
    cdb.getPublicKeysSince username, parseInt(version,10), (err, keys) ->
      return next err if err?
      logger.debug "getPublicKeysSince, username: #{username}, version: #{version}, returning: #{JSON.stringify(keys)}"
      res.send keys

  #oauth crap
  getAuthToken = (oauth2client, callback) ->
    #see if we have refresh token
    rc.hget "oauth2google", "refresh_token", (err, refreshToken) ->
      return if err?
      if refreshToken?
        oauth2client.credentials = { refresh_token: refreshToken }
        callback()
      else
        if not googleOauth2Code?
          logger.error 'no refresh token or oauth2 code available, exiting'
          process.exit(1)
        else
          oauth2client.getToken googleOauth2Code, (err, tokens) ->
            if err?
              logger.error err
              return

            if not tokens?
              logger.error "oauth2: no tokens return from google"
              return

            oauth2client.credentials = tokens
            if tokens.refresh_token?
              rc.hset "oauth2google", "refresh_token", tokens.refresh_token, (err, result) ->
                return if err?
                callback()


  getPurchaseInfo = (client, authClient, token, callback) ->
    if authClient.credentials?
      client.androidpublisher.inapppurchases.get({ packageName: "com.twofours.surespot", productId: "voice_messaging", token: token }).withAuthClient(authClient).execute(callback)

  #purchase handling
  validateVoiceToken = (username, token) ->
    return unless username? and token?

    logger.debug "validatingVoiceToken, username: #{username}, token: #{token}"
    #check token with google
    googleapis.discover("androidpublisher", "v1.1").execute (err, client) ->
      if err?
        logger.error "error validating voice messaging, #{JSON.stringify(err)}"
        oauth2Client = null
        return

      checkClient = (callback) ->
        if not oauth2Client?
          oauth2Client = new googleapis.OAuth2Client googleClientId, googleClientSecret, googleRedirectUrl
          getAuthToken oauth2Client, callback
        else
          callback()

      checkClient ->
        getPurchaseInfo client, oauth2Client, token, (err, data) ->
          if err?
            logger.error "error validating voice messaging, #{JSON.stringify(err)}"
            oauth2Client = null
            return
          return unless data?.purchaseState?

          valid =  if data.purchaseState is 0 then "true" else "false"
          logger.debug "validated voice_messaging, valid: #{valid}, token: #{token}"
          rc.hset "t", "v:vm:#{token}", valid


  updatePurchaseTokens = (username, purchaseTokens, validate) ->
    voiceToken = purchaseTokens?.voice_messaging ? null

    #if we have something to update, update
    userKey = "u:#{username}"
    multi = rc.multi()
    #single floating license implementation
    #map username to token

    #update token information
    updateLicense = (callback) ->
      #get this user's current token
      rc.hget userKey, "vm", (err, currtoken) ->
        return if err?
        #if they uploaded in a token
        if voiceToken?
          #get current user with token
          rc.hget "t", "u:vm:#{voiceToken}", (err, currentuser) ->
            return if err?
            #if user is different remove from current user
            if currentuser? and username isnt currentuser
              multi.hdel "u:#{currentuser}", "vm"

            #set token to user
            multi.hset userKey, "vm", voiceToken
            #update token mapping to user
            logger.debug "assigning voiceToken: #{voiceToken} to username: #{username}"
            multi.hset "t", "u:vm:#{voiceToken}", username

            #if token different, remove old token mapping and revalidate
            if currtoken? and currtoken isnt voiceToken
              multi.hdel "t","u:vm:#{currtoken}"
              multi.hdel "t","v:vm:#{currtoken}"
              validate = true
            callback()
        else
          #no token uploaded so perform check on existing token
          voiceToken = currtoken
          callback()

    updateLicense ->
      #map token to username
      multi.exec (err, results) ->
        return if err?

        #validate token with google
        if validate and voiceToken?
          validateVoiceToken username, voiceToken


  validateVoiceReceipt = (username, receipt) ->
    return unless username? and receipt?
    logger.debug "validatingVoiceReceipt, username: #{username}"

    #validate with apple
    iapClient.verifyReceipt receipt, true, (valid, msg, data) ->
      #do nothing on error
      return if msg is 'error'

      #see if we have valid voice messaging product id
      #looks like you get different results for different receipts ?@$$@#%
      inapp = data?.receipt?.in_app
      transactionid = null
      if inapp?
        #iterate through inapp purchases
        transaction = _.find(inapp, (purchase) -> purchase.product_id is "voice_messaging")
        valid = if transaction? then true else false
        if valid
          transactionid = transaction.original_transaction_id
      else
        if data?.receipt?.product_id is "voice_messaging"
          transactionid = data.receipt.original_transaction_id
          valid = true
        else
          valid = false

      logger.debug "validated voice messaging receipt, username: #{username}, valid: #{valid}, transactionid: #{transactionid}, data: #{JSON.stringify(data)}"

      userKey = "u:#{username}"
      multi = rc.multi()

      if transactionid?
      #if we have something to update, update

        #single floating license implementation
        multi.hset "t", "v:vmr:#{transactionid}", valid

        #get current user with token
        rc.hget "t", "u:vmr:#{transactionid}", (err, currentuser) ->
          return if err?
          #if user is different remove from current user
          if currentuser? and username isnt currentuser
            multi.hdel "u:#{currentuser}", "vmr"

          #set token to user
          multi.hset userKey, "vmr", transactionid
          #update token mapping to user
          multi.hset "t", "u:vmr:#{transactionid}", username
          multi.exec (err, results) ->
            logger.error "error updating voice message receipt: #{err}" if err?

      else
        #no transaction id, remove
        logger.debug "no voice message transaction found in receipt for: #{username}, removing voice message powers"
        multi.hdel userKey, "vmr"
        multi.exec (err, results) ->
          logger.error "error updating voice message receipt: #{err}" if err?





  updatePurchaseTokensMiddleware = (validate) -> (req, res, next) ->
    logger.debug "user #{req.user} received purchaseTokens #{req.body.purchaseTokens}, receipt: " + if req.body.purchaseReceipt? then "yes" else "no"

    purchaseTokens = req.body.purchaseTokens
    purchaseReceipt = req.body.purchaseReceipt

    if purchaseTokens
      try
        purchaseTokens = JSON.parse purchaseTokens
      catch error

      updatePurchaseTokens(req.user, purchaseTokens, validate)

    if purchaseReceipt
      validateVoiceReceipt(req.user, purchaseReceipt)

    next()

  hasValidVoiceMessageToken = (username, family, callback) ->
    return callback null, false unless username? and family?
    key = if family is 'iOS' then "vmr" else "vm"

    rc.hget "u:#{username}", key, (err, token) ->
      return callback err if err?
      return callback null, false unless token?

      rc.hget "t", "v:#{key}:#{token}", (err, valid) ->
        return callback err if err?
        return callback null, valid is "true"


  app.post "/updatePurchaseTokens", ensureAuthenticated, updatePurchaseTokensMiddleware(true), (req, res, next) ->
    res.send 204





  #workaround client sending dupes bug
  #todo remove when client fixed
  checkingIvs = {}
  checkForDuplicateMessage = (resendId, username, room, message, callback) ->
    if (resendId?)
      #logger.debug "checking if #{message.iv} is already being checked"
      #logger.debug "checkingIvs: #{JSON.stringify(checkingIvs)}"
      checkingMessageId = checkingIvs[message.iv]
      #logger.debug "checkingMessageId: #{checkingMessageId}"
      if checkingMessageId?
        message.id = checkingMessageId
        sMessage = JSON.stringify(message)
        #logger.debug "#{message.iv} is already being checked, sending message back #{sMessage}"
        callback null, sMessage
      else
        #set id of message we're checking so we can return same id to client and keep things in sync
        checkingIvs[message.iv] = message.id
        if (resendId > 0)
          logger.debug "searching room: #{room} from id: #{resendId} for duplicate messages"
          #check messages client doesn't have for dupes
          cdb.getMessagesAfterId username, room, parseInt(resendId, 10), false, (err, data) ->
            #logger.debug "error getting messages #{err}" if err?
            return callback err if err?
            found = _.find data, (checkMessage) ->
              #logger.debug "comparing ivs #{checkMessage.iv},#{message.iv}"
              checkMessage.iv == message.iv
            delete checkingIvs[message.iv]
            #logger.debug "checkingIvs: #{JSON.stringify(checkingIvs)}"
            callback null, JSON.stringify found
        else
          logger.debug "searching up to 30 messages from room: #{room} for duplicates"
          #check last 30 for dupes
          cdb.getMessages username, room, 30, false, (err, data) ->
            logger.error "error getting messages #{err}" if err?
            return callback err if err?
            found = _.find data, (checkMessage) ->
              #logger.debug "comparing ivs #{checkMessage.iv},#{message.iv}"
              checkMessage.iv == message.iv
            delete checkingIvs[message.iv]
            #logger.debug "checkingIvs: #{JSON.stringify(checkingIvs)}"
            callback null, JSON.stringify found
    else
      callback null, null

  getNextMessageId = (room, id, callback) ->
    #we will alread have an id if we uploaded a file
    return callback id if id?
    #INCR message id
    rc.hincrby "mcounters",room, 1, (err, newId) ->
      if err?
        logger.error "ERROR: getNextMessageId, room: #{room}, error: #{err}"
        callback null
      else
        callback newId

  getNextMessageControlId = (room, callback) ->
    #INCR message id
    rc.hincrby "mcmcounters",room,1, (err, newId) ->
      if err?
        logger.error "ERROR: getNextMessageControlId, room: #{room}, error: #{err}"
        callback null
      else
        callback newId

  getNextUserControlId = (user, callback) ->
          #INCR message id
    rc.hincrby "ucmcounters", user, 1, (err, newId) ->
      if err?
        logger.error "ERROR: getNextUserControlId, user: #{user}, error: #{err}"
        callback null
      else
        callback newId

  MessageError = (id, status) ->
    messageError = {}
    messageError.id = id
    messageError.status = status
    return messageError

  createAndSendMessage = (from, fromVersion, to, toVersion, iv, data, mimeType, id, dataSize, time, resendId, callback) ->
    message = {}
    message.to = to
    message.from = from
    message.datetime = time
    message.toVersion = toVersion
    message.fromVersion = fromVersion
    message.iv = iv
    message.data = data
    message.mimeType = mimeType
    message.dataSize = dataSize if dataSize
    room = common.getSpotName(from,to)

    #INCR message id
    getNextMessageId room, id, (id) ->
      return callback new MessageError(iv, 500) unless id?
      logger.debug "createAndSendMessage, spot: #{room}, id: #{id}, iv: #{iv}, resendId: #{resendId}"
      message.id = id

      #check for dupes after generating id to preserve ordering
      #check for dupes if message has been resent
      checkForDuplicateMessage resendId, from, room, message, (err, found) ->
        return callback new MessageError(iv, 500) if err?
        if found?
          logger.debug "found duplicate message, not adding to db"
          #if it's already in db it's already been sent to other user, no need to send again
          #sio.sockets.to(to).emit "message", found
          sio.sockets.to(from).emit "message", found
          callback()
        else
          #store message in cassandra
          cdb.insertMessage message, (err, results) ->
            if err?
              logger.error "error inserting message into cassandra: #{err}"
              return callback new MessageError(iv, 500)

            #store message pointer in sorted sets so we know the oldest to delete
            multi = rc.multi()

            #keep track of all the users message so we can remove the earliest when we cross their threshold
            #we use a sorted set here so we can easily remove when message is deleted O(N) vs O(M*log(N))
            userMessagesKey = "m:#{from}"
            multi.zadd userMessagesKey, time, "m:#{room}:#{id}"

            #make sure conversation is present
            multi.sadd "c:" + from, room
            multi.sadd "c:" + to, room

            #marketing wanted some stats
            #increment total user message / image counter
            switch mimeType
              when "text/plain"
                multi.hincrby "u:#{from}", "mc", 1
                multi.incr "tmc"

              when "image/"
                multi.hincrby "u:#{from}", "ic", 1
                multi.incr "tic"

              when "audio/mp4"
                multi.hincrby "u:#{from}", "vc", 1
                multi.incr "tvc"

            #if to user not connected, increment activity count
            roomCount = sio.sockets.clients(to).length
            logger.debug "room clients for #{to}, #{roomCount}"
            if roomCount is 0
              #increment new message count
              multi.hincrby "u:#{to}", "ac", 1

            multi.exec  (err, results) ->
              if err?
                logger.error ("ERROR: Socket.io onmessage, " + err)
                return callback new MessageError(iv, 500)

              deleteEarliestMessage = (callback) ->
                #check how many messages the user has total
                rc.zcard userMessagesKey, (err, card) ->
                  if err?
                    logger.warn "error deleting earliest message: #{err}"
                    return callback()
                  #TODO per user threshold based on pay status
                  #delete the oldest message(s)
                  deleteCount = card - MESSAGES_PER_USER
                  logger.debug "deleteCount #{from}: #{deleteCount}"
                  if deleteCount > 0

                    rc.zrange userMessagesKey,  0, deleteCount-1, (err, messagePointers) ->
                      if err?
                        logger.warn "error deleting earliest message: #{err}"
                        return callback()
                      myDeleteControlMessages = []
                      theirDeleteControlMessages = []
                      async.each(
                        messagePointers,
                        (item, callback) ->
                          messageData = getMessagePointerData from, item
                          #if the message we deleted is not part of the same conversation,send a control message
                          deletedFromSameSpot = room is messageData.spot
                          deleteMessage from, messageData.spot, messageData.id, not deletedFromSameSpot, (err, deleteControlMessage) ->
                            if not err? and deleteControlMessage?
                              myDeleteControlMessages.push deleteControlMessage

                              #don't send control message to other user in the message if it pertains to a different conversation
                              if deletedFromSameSpot
                                theirDeleteControlMessages.push deleteControlMessage


                            callback()
                        (err) ->
                          logger.warn "error getting old messages to delete: #{err}" if err?
                          callback myDeleteControlMessages, theirDeleteControlMessages)

                  else
                    callback()

              deleteEarliestMessage (myDeleteControlMessages, theirDeleteControlMessages) ->
                myMessage = null
                theirMessage = null

                #if we deleted messages, add the delete control message(s) to this message to save sending the delete control message separately
                if myDeleteControlMessages?.length > 0
                  message.deleteControlMessages = myDeleteControlMessages
                myMessage = JSON.stringify message

                if theirDeleteControlMessages?.length > 0
                  message.deleteControlMessages = theirDeleteControlMessages
                theirMessage = JSON.stringify message

                logger.debug "#{message.id}: #{from}->#{to}, mimeType: #{mimeType}"

                sio.sockets.to(to).emit "message", theirMessage
                sio.sockets.to(from).emit "message", myMessage

                process.nextTick ->
                  sendPushMessage message, theirMessage
                callback()


  sendPushMessage = (message, messagejson) ->
    #send gcm message
    userKey = "u:" + message.to
    rc.hmget userKey, ["gcmId", "apnToken", "ac"], (err, ids) ->
      if err?
        logger.error "error getting push ids for user: #{message.to}, error: #{err}"
        return

      gcmIds = ids[0]?.split(":")
      apn_tokens = ids[1]?.split(":")
      if gcmIds?.length > 0
        logger.debug "sending gcms for message"
        gcmmessage = new gcm.Message()
        logger.debug "gcm message created"
        sender = new gcm.Sender("#{googleApiKey}",  {maxSockets: MAX_GCM_SOCKETS})
        logger.debug "gcm sender created"
        gcmmessage.addData("type", "message")
        gcmmessage.addData("to", message.to)
        gcmmessage.addData("sentfrom", message.from)
        gcmmessage.addData("mimeType", message.mimeType)
        #pop entire message into gcm message if it's small enough
        if messagejson.length <= 3800
          gcmmessage.addData("message", messagejson)

        gcmmessage.delayWhileIdle = false
        gcmmessage.timeToLive = GCM_TTL

        logger.debug "gcm data set"

        logger.debug "sending push messages to: #{ids[0]}"
        sender.send gcmmessage, gcmIds, GCM_RETRIES, (err, result) ->
          return logger.error "Error sending message gcm from: #{message.from}, to: #{message.to}: #{err}" if err? or not result?
          logger.debug "sendGcm result: #{JSON.stringify(result)}"

          if result.failure > 0
            removeGcmIds message.to, gcmIds, result.results

          if result.canonical_ids > 0
            handleCanonicalIds message.to, gcmIds, result.results
      else
        logger.debug "no gcm id for #{message.to}"

      if apn_tokens?.length > 0
        logger.debug "sending apns for message"
        async.each(
          apn_tokens,
          (token, callback) ->
            apnDevice = new apn.Device token
            note = new apn.Notification()
            #apns are only 256 chars so we can't send the message

            badgeNum = parseInt ids[2]
            badgeNum = if isNaN(badgeNum) then 0 else badgeNum

            note.badge = badgeNum
            note.alert = { "loc-key": "notification_message", "loc-args": [message.to, message.from] }
            note.payload = { id:message.id }
            note.sound = "message.caf"
            logger.debug "sending apn to token: #{token} for #{message.to}"
            apnConnection.pushNotification note, apnDevice
            callback()
          (err) ->
            logger.error "error sending message apns: #{err}" if err?
        )
      else
        logger.debug "no apn tokens for #{message.to}"

  getMessagePointerData = (from, messagePointer) ->
    #delete message
    messageData = messagePointer.split(":")
    data = {}
    data.id =  parseInt messageData[3], 10
    data.spot =  messageData[1] + ":" + messageData[2]
    return data

  createMessageControlMessage = (from, to, spot, action, data, moredata, callback)  ->
    message = {}
    message.type = "message"
    message.action = action
    message.data = data

    if moredata?
      #make sure it's a string
      message.moredata = "#{moredata}"

    #add control message
    getNextMessageControlId spot, (id) ->
      return callback new Error 'could not create next message control id' unless id?
      message.id = id
      message.from = from
      sMessage = JSON.stringify message


      #delete oldest control message for this spot
      if (id > CONTROL_MESSAGE_HISTORY)
        deleteId = id - CONTROL_MESSAGE_HISTORY
        logger.debug "deleting control messageId #{deleteId}  from #{spot}"
        cdb.deleteControlMessages spot, [deleteId], (err, results) ->
          logger.error "error deleting control messages from spot #{spot}: #{err}" if err?

      cdb.insertMessageControlMessage spot, message, (err, results) ->
        return callback err if err?
        callback null, sMessage


  createAndSendMessageControlMessage = (from, to, room, action, data, moredata, callback) ->
    createMessageControlMessage from, to, room, action, data, moredata, (err, message) ->
      return callback err if err?
      sio.sockets.to(to).emit "control", message
      sio.sockets.to(from).emit "control", message
      callback null, message

  createAndSendUserControlMessage = (to, action, data, moredata, callback) ->
    userExists to, (err, exists) ->
      return callback() unless exists
      message = {}
      message.type = "user"
      message.action = action
      message.data = data

      if moredata?
        message.moredata = moredata

      #send control message to ourselves
      getNextUserControlId to,(id) ->
        return callback new Error 'could not get user control id' unless id?
        message.id = id
        newMessage = JSON.stringify(message)

        #delete oldest user control message for this user
        if (id > CONTROL_MESSAGE_HISTORY)
          deleteId = id - CONTROL_MESSAGE_HISTORY
          logger.debug "deleting user control messageId #{deleteId}  from user #{to}"
          cdb.deleteUserControlMessages to, [deleteId], (err, results) ->
            logger.error "error deleting user control messages from user #{to}: #{err}" if err?

        cdb.insertUserControlMessage to, message, (err, results) ->
          return callback err if err?
          sio.sockets.to(to).emit "control", newMessage
          callback()

  # broadcast a key revocation message to who's conversations
  sendRevokeMessages = (who, newVersion, callback) ->
    logger.debug "sending user control message to #{who}: #{who} has completed a key roll"

    createAndSendUserControlMessage who, "revoke", who, "#{newVersion}", (err) ->
      logger.error "ERROR: adding user control message, #{err}" if err?
      return callback new Error "could not send user controlmessage: #{err}" if err?


      #Get all the dude's conversations
      rc.smembers "c:#{who}", (err, convos) ->
        return callback err if err?
        async.each convos, (room, callback) ->
          to = common.getOtherSpotUser(room, who)
          createAndSendUserControlMessage to, "revoke", who, "#{newVersion}", (err) ->
            logger.error ("ERROR: adding user control message, " + err) if err?
            return callback new error 'could not send user controlmessage' if err?
            callback()
        , callback


  handleMessages = (socket, user, data) ->
    #rate limit
    if RATE_LIMITING_MESSAGE
      ratelimitermessages.add user
      ratelimitermessages.count user, RATE_LIMIT_SECS_MESSAGE, (err,requests) ->

        if requests > RATE_LIMIT_RATE_MESSAGE
          ip = client.handshake.headers['x-forwarded-for'] or client.handshake.address.address
          logger.warn "rate limiting messages for user: #{user}, ip: #{ip}"
          try
            message = JSON.parse(data)

            if typeIsArray message
              #todo  this blows but will do for now
              #would be better to send bulk messages on a separate event but fuck it
              return socket.emit "messageError", new MessageError(data, 429)
            else
              return socket.emit "messageError", new MessageError(message.iv, 429)
          catch error
            return socket.emit "messageError", new MessageError(data, 500)



    message = null
    #todo check from and to exist and are friends
    try
      message = JSON.parse(data)
    catch error
      return socket.emit new MessageError(data, 500)

    if typeIsArray message
      logger.debug "received array of messages from #{user}, length #{message.length}" if message.length > 0
      async.each(
        message,
        (item, callback) ->
          handleSingleMessage user, item, (err) ->
            socket.emit "messageError", err if err?
            callback()
        (err) -> )

    else
      logger.debug "received single message: #{data}"
      handleSingleMessage user, message, (err) ->
        socket.emit "messageError", err if err?


  handleSingleMessage = (user, message, callback) ->
    # message.user = user
    logger.debug "received message from user #{user}"

    iv = message.iv
    return callback new MessageError(user, 400) unless iv?
    cipherdata = message.data
    return callback new MessageError(user, 400) unless cipherdata?
    to = message.to
    return callback new MessageError(iv, 400) unless to?
    from = message.from
    return callback new MessageError(iv, 400) unless from?
    toVersion = message.toVersion
    return callback new MessageError(iv, 400) unless toVersion?
    fromVersion = message.fromVersion
    return callback new MessageError(iv, 400) unless fromVersion?


    #if this message isn't from the logged in user we have problems
    return callback new MessageError(iv, 403) unless user is from


    userExists from, (err, exists) ->
#      return callback new MessageError(iv, 500) if err?
      return callback new MessageError(iv, 404) if not exists
      userExists to, (err, exists) ->
        return callback new MessageError(iv, 500) if err?
        return callback new MessageError(iv, 404) if not exists

        if exists
          #if they're not friends with us or we're not friends with them we have a problem
          isFriend user, to, (err, aFriend) ->
            return callback new MessageError(iv, 500) if err?
            return callback new MessageError(iv, 403) if not aFriend

            resendId = message.resendId

            createAndSendMessage from, fromVersion, to, toVersion, iv, cipherdata, "text/plain", null, null, Date.now(), resendId, callback


  sio.on "connection", (socket) ->
    user = socket.handshake.session.passport.user
    logger.debug "#{user} connected"

    socket.join user

    socket.on "message", (data) -> handleMessages socket, user, data
    socket.on "disconnect", ->
      socket.leave user
      logger.debug "#{user} disconnected"



  #delete all messages
  app.delete "/messagesutai/:username/:id", ensureAuthenticated, validateUsernameExistsOrDeleted, validateAreFriendsOrDeleted, (req, res, next) ->

    username = req.user
    otherUser = req.params.username
    room = common.getSpotName username, otherUser
    id = parseInt req.params.id, 10

    return res.send 400 unless id? and not Number.isNaN(id)

    logger.debug "deleting messages, user: #{username}, otherUser: #{otherUser}, utaiId: #{id}"
    deleteAllMessages username, otherUser, id, (err) ->
      return next err if err?
      res.send 204


  deleteAllMessages = (username, otherUser, utaiId, callback) ->
    spot = common.getSpotName username, otherUser
    cdb.getAllMessages username, spot, (err, messages) ->
      return callback err if err?

      lastMessageId = null

      if messages?.length > 0
        #messageCount = messages.length
        #ordered by id so newest will be last
        lastMessageId = messages[messages.length-1].id
        logger.debug "lastMessageID #{lastMessageId}"

        #todo do we need to do this?
        #if there are messages > than those we want to delete we need to insert them after
        #the delete because fucking cassandra doesn't let you delete from with < or > check (why on select but not delete?)
        #messagesToInsert = []
#        if lastMessageId > utaiId
#          for i in [messageCount..0]
#            message = messages[i]
#            if message.id > utaiId
#              messagesToInsert.push message

        idsToDelete = []
        multi = rc.multi()
        async.each(
          messages
          (oMessage, callback) ->
            #if we sent it remove it from our set of pointers and remove data from rackspace if we need to
            if oMessage.from is username
              multi.zrem "m:#{username}", "m:#{spot}:#{oMessage.id}"

              #delete file from rackspace if necessary
              deleteFile oMessage.data, oMessage.mimeType
              idsToDelete.push oMessage.id

            callback()

          (err) ->
            cdb.deleteMessages username, spot, idsToDelete, (err, results) ->
              return callback err if err?

              multi.exec (err, mResults) ->
                return callback err if err?
                createAndSendMessageControlMessage username, otherUser, spot, "deleteAll", spot, lastMessageId, (err) ->
                  return callback err if err?
                  callback())
      else
        callback()


  deleteMessage = (deletingUser, spot, messageId, sendControlMessage, callback) ->
    logger.debug "user #{deletingUser} deleting message from: #{spot} id: #{messageId}"
    otherUser = common.getOtherSpotUser spot, deletingUser

    #call callback immediately
    if (sendControlMessage)
      createAndSendMessageControlMessage deletingUser, otherUser, spot, "delete", spot, messageId, (err, message) ->
        return callback err if err?
        callback null, message
    else
      createMessageControlMessage deletingUser, otherUser, spot, "delete", spot, messageId, (err, message) ->
        return callback err if err?
        callback null, message

    #then delete stuff

    #delete it from redis
    rc.zrem "m:#{deletingUser}", "m:#{spot}:#{messageId}", (err, result) ->
      logger.error "error deleting message from redis: #{err}" if err?
      logger.debug "deleted message pointer for: #{spot} id: #{messageId}"

    #get the message we're deleting
    #todo eliminate this get by storing from, data and mimetype in redis if not text
    cdb.getMessage deletingUser, spot, messageId, (err, message) ->
      logger.error "error gettingMessage: #{err}" if err?
      logger.debug "got message from cassandra for: #{spot} id: #{messageId}"
      #if it's not in cassandra then don't do anything else
      return if not message?

      #delete message data
      #remove message data from cassandra
      cdb.deleteMessage deletingUser, message.from, spot, messageId

      #remove from my message pointer set if i sent it
      if deletingUser is message.from
        #if we sent it delete the data from rackspace if we need to
        deleteFile message.data, message.mimeType




  deleteFile = (uri, mimeType) ->
    container = null
    if mimeType is "image/"
      container = rackspaceImageContainer
    else
      if mimeType is "audio/mp4"
        container = rackspaceVoiceContainer

    return unless container?

    splits = uri.split('/')
    path = splits[splits.length - 1]
    logger.debug "removing file from rackspace: #{path}"
    rackspace.removeFile container, path, (err) ->
      if err?
        logger.error "could not remove file from rackspace: #{path}, error: #{err}"
      else
        logger.debug "removed file from rackspace: #{path}"

  #delete single message
  app.delete "/messages/:username/:id", ensureAuthenticated, validateUsernameExistsOrDeleted, validateAreFriendsOrDeleted, (req, res, next) ->

    messageId = parseInt req.params.id, 10
    return next new Error 'id required' unless messageId? and not Number.isNaN(messageId)

    username = req.user
    otherUser = req.params.username
    
    spot = common.getSpotName username, otherUser

    deleteMessage username, spot, messageId, true, (err, deleteControlMessage) ->
      return next err if err?
      res.send (if deleteControlMessage? then 204 else 404)

  app.post "/deletetoken", setNoCache, (req, res, next) ->
    return res.send 400 unless req.body?.username?
    return res.send 400 unless req.body?.authSig?
    return res.send 400 unless req.body?.password?

    username = req.body.username
    password = req.body.password
    authSig = req.body.authSig
    validateUser username, password, authSig, (err, status, user) ->
      return next err if err?
      return res.send 403 unless user?

      generateSecureRandomBytes 'base64', (err, token) ->
        return next err if err?
        rc.set "dt:#{username}", token, (err, result) ->
          return next err if err?
          res.send token



  app.post "/passwordtoken", setNoCache, (req, res, next) ->
    return res.send 400 unless req.body?.username?
    return res.send 400 unless req.body?.authSig?
    return res.send 400 unless req.body?.password?

    username = req.body.username
    password = req.body.password
    authSig = req.body.authSig
    validateUser username, password, authSig, (err, status, user) ->
      return next err if err?
      return res.send 403 unless user?

      generateSecureRandomBytes 'base64', (err, token) ->
        return next err if err?
        rc.set "pt:#{username}", token, (err, result) ->
          return next err if err?
          res.send token

  app.put "/messages/:username/:id/shareable", ensureAuthenticated, validateUsernameExists, validateAreFriends, (req, res, next) ->
    messageId = parseInt req.params.id, 10
    return next new Error 'id required' unless messageId? and not Number.isNaN(messageId)

    shareable = req.body.shareable
    return next new Error 'shareable required' unless shareable?

    username = req.user
    otherUser = req.params.username
    spot = common.getSpotName username, otherUser
    bShareable = shareable is 'true'

    cdb.updateMessageShareable spot, messageId, bShareable, (err, results) ->
      return next err if err?
      newStatus = if bShareable then "shareable" else "notshareable"
      createAndSendMessageControlMessage username, otherUser, spot, newStatus, spot, messageId, (err) ->
        return next err if err?
        res.send newStatus

  app.put "/users/:username/alias", ensureAuthenticated, validateUsernameExists, validateAreFriends, (req, res, next) ->

    username = req.user
    friendname = req.params.username
    version = req.body.version
    return res.send 400 unless version?
    data = req.body.data
    return res.send 400 unless data?
    iv = req.body.iv
    return res.send 400 unless iv?

    cdb.insertFriendAliasData username, friendname, data, version, iv, (err, results) ->
      return next err if err?
      createAndSendUserControlMessage username, "friendAlias", friendname, { data: data, iv: iv, version: version }, (err) ->
        if err?
          logger.error "#{username} /users/#{friendname}/alias/#{version}, error creating and sending user control message: #{err}"
        res.send 204



  app.delete "/users/:username/alias", ensureAuthenticated, validateUsernameExists, validateAreFriends, (req, res, next) ->
    username = req.user
    friendname = req.params.username

    cdb.deleteFriendAliasData username, friendname, (err, results) ->
      return next err if err?
      createAndSendUserControlMessage username, "friendAlias", friendname, null, (err) ->
        if err?
          logger.error "delete #{username} /users/#{friendname}/alias, error creating and sending user control message: #{err}"
        res.send 204


  app.delete "/users/:username/image", ensureAuthenticated, validateUsernameExists, validateAreFriends, (req, res, next) ->
    username = req.user
    friendname = req.params.username

    cdb.deleteFriendImageData username, friendname, (err, results) ->
      return next err if err?
      createAndSendUserControlMessage username, "friendImage", friendname, null, (err) ->
        if err?
          logger.error "delete #{username} /users/#{friendname}/alias, error creating and sending user control message: #{err}"
        res.send 204

  app.post "/images/:username/:version", ensureAuthenticated, validateUsernameExists, validateAreFriends, (req, res, next) ->

    username = req.user
    otherUser = req.params.username
    version = req.params.version
    return res.send 400 unless version?

    form = new formidable.IncomingForm()
    form.onPart = (part) ->
      return form.handlePart part unless part.filename?
      iv = part.filename

      outStream = new stream.PassThrough()

      part.on 'data', (buffer) ->
        form.pause()
        #logger.debug 'received part data'
        outStream.write buffer, ->
          form.resume()

      part.on 'end', ->
        form.pause()
        #logger.debug 'received part end'
        outStream.end ->
          form.resume()

      #no need for secure randoms for image paths
      generateRandomBytes 'hex', (err, bytes) ->
        return next err if err?

        path = bytes
        logger.debug "received part: #{part.filename}, uploading to rackspace at: #{path}"

        outStream.pipe rackspace.upload {container: rackspaceImageContainer, remote: path, headers: { "content-type": "application/octet-stream"}}, (err) ->
          if err?
            logger.error "POST /images/:username/:version, error: #{err}"
            return next err #delete filenames[part.filename]

          logger.debug 'upload completed'
          url = rackspaceCdnImageBaseUrl + "/#{path}"

          cdb.getFriendData username, otherUser, (err, friend) ->
            if err?
              logger.error "POST /images/#{username}/#{version}, error getting friend data: #{err}"
            else
              if friend?.imageUrl?
                deleteFile friend.imageUrl, "image/"


            cdb.insertFriendImageData username, otherUser, url, version, iv, (err, results) ->
              if err?
                logger.error "POST /images/#{username}/#{version}, error: #{err}"
                deleteFile url, "image/"
                return next err

              createAndSendUserControlMessage username, "friendImage", otherUser, { url: url, iv: iv, version: version }, (err) ->
                if err?
                  logger.error "POST /images/:username/:version, error: #{err}"
                  deleteFile url, "image/"
                  return next err

                res.send url

    form.on 'error', (err) ->
      next err

    form.parse req

  #doing more than images now, don't feel like changing the api though..yet
  app.post "/images/:fromversion/:username/:toversion", ensureAuthenticated, validateUsernameExists, validateAreFriends, (req, res, next) ->
    #upload image to rackspace then create a message with the image url and send it to chat recipients
    username = req.user
    path = null
    size = 0
    container = null
    cdn = null

    form = new formidable.IncomingForm()
    form.onPart = (part) ->
      return form.handlePart part unless part.filename?
    #  filenames[part.filename] = "uploading"
      mimeType = part.mime

      logger.debug "checking mimeType: #{mimeType}"
      #check valid mimetypes
      unless mimeType in ['text/plain', 'image/','audio/mp4']
        return res.send 400

      outStream = new stream.PassThrough()

      part.on 'data', (buffer) ->
        form.pause()

        size += buffer.length
        #logger.debug "received file data, length: #{buffer.length}, size: #{size}"
        #logger.debug 'received part data'
        outStream.write buffer, ->
          form.resume()


      part.on 'end', ->
        form.pause()
        #logger.debug 'received part end'

        outStream.end ->
          form.resume()

      checkPermissions = (callback) ->
        #if it's audio make sure we have permission
        if mimeType is "audio/mp4"
          cdn = rackspaceCdnVoiceBaseUrl
          container = rackspaceVoiceContainer

          os = uaparser.parseOS req.headers['user-agent']
          family = os.family
          logger.debug "family: #{family}"

          hasValidVoiceMessageToken username, family, (err, valid) ->
            if err?
              return next err

            logger.debug "validated voice purchase for #{username}, valid: #{valid}"
            #yes it's a 402
            if not valid
              return res.send 402
            callback()
        else
          cdn = rackspaceCdnImageBaseUrl
          container = rackspaceImageContainer
          callback()


      checkPermissions ->
        #todo validate versions

        room = common.getSpotName username, req.params.username
        getNextMessageId room, null, (id) ->
          #todo send message error on socket
          if not id?
            err = new Error 'could not generate messageId'
            logger.error "fileupload, mimeType: #{mimeType} error: #{err}"
            #sio.sockets.to(username).emit "messageError", new MessageError(iv, 500)
            return next err # delete filenames[part.filename]

          #no need for secure randoms for image paths
          generateRandomBytes 'hex', (err, bytes) ->
            if err?
              logger.error "fileupload, mimeType: #{mimeType} error: #{err}"
              #sio.sockets.to(username).emit "messageError", new MessageError(iv, 500)
              return next err #delete filenames[part.filename]

            path = bytes
            logger.debug "received part: #{part.filename}, uploading to rackspace at: #{path}"

            outStream.pipe rackspace.upload {container: container, remote: path, headers: { "content-type": "application/octet-stream"}}, (err) ->
              if err?
                logger.error "fileupload, mimeType: #{mimeType} error: #{err}"
                #sio.sockets.to(username).emit "messageError", new MessageError(iv, 500)
                return next err #delete filenames[part.filename]

              logger.debug "upload completed #{path}, size: #{size}"
              url = cdn + "/#{path}"

              time = Date.now()
              createAndSendMessage req.user, req.params.fromversion, req.params.username, req.params.toversion, part.filename, url, mimeType, id, size, time, null, (err) ->
                logger.error "error sending message on socket: #{err}" if err?
                return next err if err?
                res.send { id: id, url: url, time: time, size: size}


    form.on 'error', (err) ->
      return next new Error err

    form.on 'end', ->
      logger.debug "form end"


    form.parse req


  getConversationIds = (username, callback) ->
    rc.smembers "c:" + username, (err, conversations) ->
      return callback err if err?
      if (conversations.length > 0)
        conversationsWithId = _.map conversations, (conversation) -> "#{conversation}"
        rc.hmget "mcounters", conversationsWithId, (err, ids) ->
          return next err if err?
          conversationIds = []
          _.each conversations, (conversation, i) -> conversationIds.push { conversation: conversation, id: ids[i] }
          callback null, conversationIds
      else
        callback null, null

  getLatestUserControlMessages = (username, userControlId, asArrayOfJsonString,  callback) ->
    rc.hget "ucmcounters", username, (err, latestUserControlId) ->
      return callback err if err?

      latestUserControlId = latestUserControlId ? userControlId
      latestUserControlId = parseInt(latestUserControlId, 10)

      logger.debug "comparing userControlId: #{userControlId} with latestUserControlId: #{latestUserControlId}"

      if userControlId < latestUserControlId
        cdb.getUserControlMessagesAfterId username, userControlId, asArrayOfJsonString, callback
      else
        callback()

  #get all the optimized data we need in one call
  app.post "/optdata/:userControlId", ensureAuthenticated, updatePurchaseTokensMiddleware(false), setNoCache, (req, res, next) ->
    #need array of {un: username, mid: , cmid: }

    username = req.user
    userControlId = parseInt req.params.userControlId, 10
    return next new Error 'no userControlId' unless userControlId? and not Number.isNaN(userControlId)

    logger.debug "optdata, userControlId: #{userControlId}, spotIds: #{req.body.spotIds}"

    spotIds = {}
    if req.body?.spotIds?
      try

        spotIdsJson = JSON.parse req.body.spotIds
        for spotItem in spotIdsJson
          spotIdData = {}
          spot = common.getSpotName username, spotItem.u
          spotIdData.cm = parseInt(spotItem.cm, 10)
          spotIdData.m = parseInt(spotItem.m, 10)
          spotIdData.u = spotItem.u
          spotIds[spot] = spotIdData

      catch error

    getLatestUserControlMessages username, userControlId, false, (err, userControlMessages) ->
      return next err if err?

      data =  {}
      if userControlMessages?.length > 0
        logger.debug "got new user control messages: #{userControlMessages}"
        data.userControlMessages = userControlMessages

      #see if they need to update sigs
      rc.hget "u:#{username}", "sigs", (err, sigs) ->
        return next err if err?
        data.sigs = true unless sigs?

        getConversationIds req.user, (err, conversationIds) ->
          return next err if err?

          checkConversations = (callback) ->
            if not conversationIds? or conversationIds.length is 0
              rc.hset "u:#{username}", "ac", 0, (err, result) ->
                return callback err if err?
                callback null, false
            else
              callback null, true

          checkConversations (err, hasConversations) ->
            return next err if err
            if not hasConversations
              sData = JSON.stringify(data)
              logger.debug "/optdata sending #{sData}"
              res.set {'Content-Type': 'application/json'}
              return res.send data
            else
              controlIdKeys = []
              latestMessageIds = {}

              async.each(
                conversationIds
                (item, callback) ->
                  controlIdKeys.push "#{item.conversation}"
                  logger.debug "setting latest message id: #{item.id} for conversation: #{item.conversation}"
                  latestMessageIds[item.conversation] = item.id
                  callback()
                (err) ->
                  return next err if err?
                  #Get control ids
                  rc.hmget "mcmcounters", controlIdKeys, (err, rControlIds) ->
                    return next err if err?
                    controlIds = {}
                    _.each(
                      rControlIds
                      (controlId, i) ->
                        if controlId?
                          conversation = conversationIds[i].conversation
                          logger.debug "setting latest control id: #{controlId} for conversation: #{conversation}"
                          controlId = parseInt(controlId, 10)
                          controlIds[conversation] = controlId)

                    if Object.keys(latestMessageIds).length > 0
                      data.conversationIds = latestMessageIds

                    if Object.keys(controlIds).length > 0
                      data.controlIds = controlIds

                    addNewMessages = (callback) ->
                      keys = Object.keys(spotIds)
                      if keys.length > 0
                        messages = []
                        #get messages
                        async.each(
                          keys,
                          (spot, callback1) ->
                            item = spotIds[spot]
                            getMessagesAndControlMessagesOpt(username, item.u, item.m, latestMessageIds[spot], item.cm, controlIds[spot], false, (err, data) ->
                              return callback1() if err?
                              if data?
                                messages.push data
                              callback1())
                          (err) ->
                            if messages.length > 0
                              data.messageData = messages
                            callback())
                      else
                        callback()

                    addNewMessages ->
                      #clear new message counter
                      rc.hset "u:#{username}", "ac", 0, (err, result) ->
                        return next(err) if err?
                        sData = JSON.stringify(data)
                        logger.debug "/optdata sending #{sData}"
                        res.set {'Content-Type': 'application/json'}
                        res.send data)

  #get all the data we need in one call
  app.post "/latestdata/:userControlId", ensureAuthenticated, setNoCache, (req, res, next) ->
    #need array of {un: username, mid: , cmid: }

    username = req.user
    userControlId = parseInt req.params.userControlId, 10
    return next new Error 'no userControlId' unless userControlId? and not Number.isNaN(userControlId)

    spotIds = null
    try
      logger.debug "latestdata, spotIds: #{req.body.spotIds}"
      spotIds = JSON.parse req.body.spotIds
    catch error

    getLatestUserControlMessages username, userControlId, true, (err, userControlMessages) ->
      return next err if err?

      data =  {}
      if userControlMessages?.length > 0
        logger.debug "got new user control messages: #{userControlMessages}"
        data.userControlMessages = userControlMessages

      getConversationIds req.user, (err, conversationIds) ->
        return next err if err?

        return res.send data unless conversationIds?
        controlIdKeys = []
        latestMessageIds = {}
        latestControlIds = {}
        async.each(
          conversationIds
          (item, callback) ->
            controlIdKeys.push "#{item.conversation}"
            logger.debug "setting latest message id: #{item.id} for conversation: #{item.conversation}"
            latestMessageIds[item.conversation] = item.id
            callback()
          (err) ->
            return next err if err?
            #Get control ids
            rc.hmget "mcmcounters", controlIdKeys, (err, rControlIds) ->
              return next err if err?
              controlIds = []
              _.each(
                rControlIds
                (controlId, i) ->
                  if controlId isnt null
                    conversation = conversationIds[i].conversation
                    latestControlIds[conversation] = controlId

                    logger.debug "setting latest control id: #{controlId} for conversation: #{conversation}"
                    controlIds.push({conversation: conversation, id: controlId}))

              if conversationIds.length > 0
                data.conversationIds = conversationIds

              if controlIds.length > 0
                data.controlIds = controlIds

              addNewMessages = (callback) ->
                if spotIds?.length > 0
                  messages = []
                  #get messages
                  async.each(
                    spotIds,
                    (item, callback1) ->
                      spot = common.getSpotName username, item.username
                      getMessagesAndControlMessagesOpt(username, item.username, parseInt(item.messageid, 10),  latestMessageIds[spot], parseInt(item.controlmessageid, 10), latestControlIds[spot], true, (err, data) ->
                        return callback1() if err?
                        if data?
                          messages.push data
                        callback1())
                    (err) ->
                      if messages.length > 0
                        data.messageData = messages
                      callback())
                else
                  callback()

              addNewMessages ->
                sData = JSON.stringify(data)
                logger.debug "/latestdata sending #{sData}"
                res.set {'Content-Type': 'application/json'}
                res.send sData)

  app.get "/latestids/:userControlId", ensureAuthenticated, setNoCache, (req, res, next) ->
    userControlId = parseInt req.params.userControlId, 10
    logger.debug "#{req.user} /latestids/#{userControlId}"
    return next new Error 'no userControlId' unless userControlId? and not Number.isNaN(userControlId)

    getLatestUserControlMessages req.user, userControlId, true, (err, userControlMessages) ->
      return next err if err?

      data =  {}
      if userControlMessages?.length > 0
        #logger.debug "got new user control messages: #{userControlMessages}"
        data.userControlMessages = userControlMessages

      getConversationIds req.user, (err, conversationIds) ->
        return next err if err?

        return res.send data unless conversationIds?
        controlIdKeys = []
        async.each(
          conversationIds
          (item, callback) ->
            controlIdKeys.push "#{item.conversation}"
            callback()
          (err) ->
            return next err if err?
            #Get control ids
            rc.hmget "mcmcounters", controlIdKeys, (err, rControlIds) ->
              return next err if err?
              controlIds = []
              _.each(
                rControlIds
                (controlId, i) ->
                  if controlId isnt null
                    controlIds.push({conversation: conversationIds[i].conversation, id: controlId}))

              if conversationIds.length > 0
                data.conversationIds = conversationIds

              if controlIds.length > 0
                data.controlIds = controlIds
              logger.debug "/latestids sending #{JSON.stringify(data)}"
              res.send data)



  #get remote messages before id
  app.get "/messages/:username/before/:messageid", ensureAuthenticated, validateUsernameExistsOrDeleted, validateAreFriendsOrDeleted, setNoCache, (req, res, next) ->
    #return messages since id
    id = parseInt req.params.messageid, 10
    return res.send 400 unless id? and not Number.isNaN(id)

    cdb.getMessagesBeforeId req.user, common.getSpotName(req.user, req.params.username), id, true, (err, data) ->
      return next err if err?
      #sData = JSON.stringify(data)

      #logger.debug "sending #{sData}"
      res.set {'Content-Type': 'application/json'}
      res.send data


  app.get "/messagesopt/:username/before/:messageid", ensureAuthenticated, validateUsernameExistsOrDeleted, validateAreFriendsOrDeleted, setNoCache, (req, res, next) ->
    #return messages since id
    id = parseInt req.params.messageid, 10
    return res.send 400 unless id? and not Number.isNaN(id)

    cdb.getMessagesBeforeId req.user, common.getSpotName(req.user, req.params.username), id, false, (err, data) ->
      return next err if err?
      #sData = JSON.stringify(data)

      #logger.debug "sending #{sData}"
      res.set {'Content-Type': 'application/json'}
      res.send data

  app.get "/messagedataopt/:username/:messageid/:controlmessageid", ensureAuthenticated, validateUsernameExistsOrDeleted, validateAreFriendsOrDeleted, setNoCache, (req, res, next) ->

    messageId = parseInt req.params.messageid, 10
    return next new Error 'message id required' unless messageId? and not Number.isNaN(messageId)

    messageControlId = parseInt req.params.controlmessageid, 10
    return next new Error 'control message id required' unless messageControlId? and not Number.isNaN(messageControlId)

    #get latest ids
    spot = common.getSpotName req.user, req.params.username
    multi = rc.multi()
    multi.hget "mcounters", spot
    multi.hget "mcmcounters", spot
    multi.exec (err, results) ->
      return next err if err?
      getMessagesAndControlMessagesOpt req.user, req.params.username, messageId, results[0], messageControlId, results[1], false, (err, data) ->
        return next err if err?
        if data?
          sData = JSON.stringify(data)
          logger.debug "sending: #{sData}"
          res.set {'Content-Type': 'application/json'}
          res.send data
        else
          logger.debug "no new messages for user #{req.user} for friend #{req.params.username}"
          res.send 204

  app.get "/messagedata/:username/:messageid/:controlmessageid", ensureAuthenticated, validateUsernameExistsOrDeleted, validateAreFriendsOrDeleted, setNoCache, (req, res, next) ->

    messageId = parseInt req.params.messageid, 10
    return next new Error 'message id required' unless messageId? and not Number.isNaN(messageId)

    messageControlId = parseInt req.params.controlmessageid, 10
    return next new Error 'control message id required' unless messageControlId? and not Number.isNaN(messageControlId)

    #get latest ids
    spot = common.getSpotName req.user, req.params.username
    multi = rc.multi()
    multi.hget "mcounters", spot
    multi.hget "mcmcounters", spot
    multi.exec (err, results) ->
      return next err if err?
      getMessagesAndControlMessagesOpt req.user, req.params.username, messageId, results[0], messageControlId, results[1], true, (err, data) ->
        return next err if err?
        if data?
          sData = JSON.stringify(data)
          logger.debug "sending: #{sData}"
          res.set {'Content-Type': 'application/json'}
          res.send sData
        else
          logger.debug "no new messages for user #{req.user} for friend #{req.params.username}"
          res.send 204


  getMessagesAndControlMessagesOpt = (username, friendname, messageId, latestMessageId, controlMessageId, latestControlMessageId, asArrayOfJsonStrings, callback) ->
    logger.debug "getMessagesAndControlMessagesOpt username: #{username}, friendname: #{friendname}, messageId: #{messageId}, latestMessageId: #{latestMessageId}, controlMessageId: #{controlMessageId}, latestControlMessageId: #{latestControlMessageId}"
    spot = common.getSpotName(username, friendname)
    data = {}
    data.username = friendname

    getLatestMessages = (callback) ->

      if messageId < 0 then messageId = latestMessageId
      if (messageId < latestMessageId)
        cdb.getMessagesAfterId username, spot, messageId, asArrayOfJsonStrings, (err, messageData) ->
          return callback err if err?
          if messageData?.length > 0
            data.messages = messageData
          callback()
      else
        callback()

    getLatestMessages (err) ->
      return callback err if err?
      getLatestControlMessages = (callback) ->
        latestControlMessageId = latestControlMessageId ? 0
        if controlMessageId < 0 then controlMessageId = latestControlMessageId
        if (controlMessageId < latestControlMessageId)
          #return messages since id
          cdb.getControlMessagesAfterId username, spot, controlMessageId, asArrayOfJsonStrings, (err, controlData) ->
            return callback err if err?
            if controlData?.length > 0
              data.controlMessages = controlData
            callback()
        else
          callback()

      getLatestControlMessages (err) ->
        return callback err if err?
        callback null, if data.messages? or data.controlMessages? then data else null


  #TODO change url to "latest" - will probably go away after new client off
  app.get "/publickeys/:username", ensureAuthenticated, validateUsernameExistsOrDeleted, validateAreFriendsOrDeletedOrMe, setNoCache, getPublicKeys
  app.get "/publickeys/:username/:version", ensureAuthenticated, validateUsernameExistsOrDeleted, validateAreFriendsOrDeletedOrMe, setCache(oneYear), getPublicKeys
  app.get "/publickeys/:username/since/:version", ensureAuthenticated, validateUsernameExistsOrDeleted, validateAreFriendsOrDeletedOrMe, setNoCache, getPublicKeysSince
  app.get "/keyversion/:username", ensureAuthenticated, validateUsernameExistsOrDeleted, validateAreFriendsOrDeleted,(req, res, next) ->
    rc.hget "u:#{req.params.username}", "kv", (err, version) ->
      return next err if err?
      res.send version

  handleReferrers = (username, referrers, callback) ->
    return callback() if referrers.length is 0
    usersToInvite = []
    multi = rc.multi()
    async.each(
      referrers,
      (referrer, callback) ->
        referralUserName = referrer.utm_content
        referralSource = referrer.utm_medium
        usersToInvite.push { username: referralUserName, source: referralSource }
        multi.sismember "u", referralUserName
        callback()
      (err) ->
        return callback err if err?

        multi.exec (err, results) ->
          return callback err if err?
          _.each(
            results,
            (exists, index, list) ->
              if exists
                #send invite
                ref = usersToInvite[index]
                inviteUser username, ref.username, ref.source, (err, inviteSent) ->
                  logger.error "handleReferrers, error: #{err}" if err?
          )
          callback())


  #they didn't have surespot on their phone so they came here so direct them to the play store
  app.get "/autoinvite/:username/:source", validateUsernameExists, (req, res, next) ->
    os = uaparser.parseOS req.headers['user-agent']
    family = os.family
    logger.debug "user agent family: #{family}"

    #change what we sent back based on what's connecting
    if family is 'Android'

      #they hit https://server.surespot.me/autoinvite because they didn't have surespot installed on their phone so
      #redirect them to the play store and use analytics mechanism to invite the user once installed

      #if they have the app installed it will intercept the link and invite them

      username = req.params.username
      source = req.params.source

      redirectUrl = "market://details?id=com.twofours.surespot&referrer="
      query = "utm_source=surespot_android&utm_medium=#{source}&utm_content=#{username}"

      resText = redirectUrl + encodeURIComponent(query)
      logger.debug "auto-invite redirecting to: #{resText}"
      res.redirect resText
    else
      if family is 'iOS'
        res.render 'autoinviteIosProd', {username: req.params.username}
      else
        #couldn't figure out the device so give user option
#        username = req.params.username
#        source = req.params.source
#
#        redirectUrl = "market://details?id=com.twofours.surespot&referrer="
#        query = "utm_source=surespot_android&utm_medium=#{source}&utm_content=#{username}"
#
#        androidUrl = redirectUrl + encodeURIComponent(query)
#
##        inviteText = "If on iOS, please click on the link above to install or open surespot and invite #{req.params.username}. If surespot needs installing you will need to click the above link again after installing to invite the user. If no link appears above on iOS, open this page in Safari."
##        resText = "<meta name=\"viewport\" content=\"width=device-width\">#{inviteText}<br><br><meta name=\"apple-itunes-app\" content=\"app-id=352861751, app-argument=surespot://autoinvite/#{req.params.username}\"/><br><br>" +
#        resText = "If on Android, please <a href=\"#{androidUrl}\">click here</a> to invite #{req.params.username} to be a friend / install surespot."
#        resText += "<br><br>If on iOS and surespot is installed please <a href=\"surespot://autoinvite/#{req.params.username}\">click here</a> to invite the user, or <a href=\"http://tflig.ht/1bth8Eq\">click here</a> to install the alpha version."
#        logger.debug "auto-invite response: #{resText}"
#        res.send resText
        #todo add autoinvite params and dynamically update play store/itunes links
        res.redirect "https://www.surespot.me"
        #res.render 'autoinviteIosAlpha', {username: req.params.username}


  createNewUser = (req, res, next) ->
    username = req.body.username
    password = req.body.password
    version = req.body.version
    platform = req.body.platform

    #older versions won't have platform set so tell them to upgrade
    return res.send 403 if platform isnt 'ios' and platform isnt 'android'

    #ios handled by validateVersion

    #android < 49 doesn't handle some chars in auto invite links
    #tell them to upgrade if < 49
    if platform is 'android'
      intVersion = parseInt version
      if isNaN intVersion
        return res.send 403
      else
        return res.send 403 if intVersion < 49

    userExistsOrDeleted username, true, (err, exists) ->
      return next err if err?
      if exists
        logger.debug "user already exists"
        return res.send 409
      else
        user = {}
        user.username = username
        user.kv = 1

        keys = {}
        keys.version = 1
        if req.body?.dhPub?
          keys.dhPub = req.body.dhPub
        else
          return next new Error('dh public key required')

        if req.body?.dsaPub?
          keys.dsaPub = req.body.dsaPub
        else
          return next new Error('dsa public key required')

        return next new Error('auth signature required') unless req.body?.authSig?

        if req.body?.gcmId?
          user.gcmId = req.body.gcmId


        referrers = null

        if req.body?.referrers?
          try
            referrers = JSON.parse(req.body.referrers)
          catch error
            logger.error "createNewUser, error: #{error}"
            return next error


        logger.debug "gcmID: #{user.gcmId}"
        logger.debug "referrers: #{req.body.referrers}"

        bcrypt.genSalt 10, 32, (err, salt) ->
          return next err if err?
          bcrypt.hash password, salt, (err, password) ->
            return next err if err?
            user.password = password

            #sign the keys
            keys.dhPubSig = crypto.createSign('sha256').update(new Buffer(keys.dhPub)).sign(serverPrivateKey, 'base64')
            keys.dsaPubSig = crypto.createSign('sha256').update(new Buffer(keys.dsaPub)).sign(serverPrivateKey, 'base64')
            logger.debug "#{username}, dhPubSig: #{keys.dhPubSig}, dsaPubSig: #{keys.dsaPubSig}"

            #user id
            rc.incr "uid", (err, newid) ->
              return next err if err?

              user.id = newid

              cdb.insertPublicKeys username, keys, (err, result) ->
                return next err if err?
                multi = rc.multi()
                multi.hmset "u:#{username}", user
                multi.sadd "u", username
                multi.exec (err,replies) ->
                  return next err if err?
                  logger.warn "#{username} created, uid: #{user.id}, platform: #{platform}, version: #{version}"

                  #now we have a user we can create a session
                  initSession req, res, (err) ->
                    if err?
                      req.session?.destroy()
                      return next(err)

                    req.login username, ->
                      if referrers
                        handleReferrers username, referrers, next
                      else
                        next()

  createNewUser2 = (req, res, next) ->
    username = req.body.username
    password = req.body.password
    version = req.body.version
    platform = req.body.platform

    userExistsOrDeleted username, true, (err, exists) ->
      return next err if err?
      if exists
        logger.debug "user already exists"
        return res.send 409
      else
        user = {}
        user.username = username
        user.kv = 1
        user.sigs = true

        keys = {}
        keys.version = 1
        if req.body?.dhPub?
          keys.dhPub = req.body.dhPub
        else
          return next new Error('dh public key required')

        if req.body?.dsaPub?
          keys.dsaPub = req.body.dsaPub
        else
          return next new Error('dsa public key required')

        return next new Error('auth signature required') unless req.body?.authSig?
        return next new Error('client signature required') unless req.body?.clientSig?

        sig = req.body.clientSig
        #check sig
        verified = verifyClientSignature username, 1, keys.dhPub, keys.dsaPub, sig, keys.dsaPub
        logger.debug "verify signature for username: #{username}, result: #{verified}"
        return res.send 400 unless verified

        #store client sig
        keys.clientSig = sig

        if req.body?.gcmId?
          user.gcmId = req.body.gcmId


        referrers = null

        if req.body?.referrers?
          try
            referrers = JSON.parse(req.body.referrers)
          catch error
            logger.error "createNewUser2, error: #{error}"
            return next error


        logger.debug "gcmID: #{user.gcmId}"
        logger.debug "referrers: #{req.body.referrers}"

        bcrypt.genSalt 10, 32, (err, salt) ->
          return next err if err?
          bcrypt.hash password, salt, (err, password) ->
            return next err if err?
            user.password = password

            #sign the keys - maintained for backwards compatibility
            keys.dhPubSig = crypto.createSign('sha256').update(new Buffer(keys.dhPub)).sign(serverPrivateKey, 'base64')
            keys.dsaPubSig = crypto.createSign('sha256').update(new Buffer(keys.dsaPub)).sign(serverPrivateKey, 'base64')

            #protocol 2 includes username and version in signature
            vbuffer = new Buffer(4)
            vbuffer.writeInt32LE(1, 0)
            keys.serverSig = crypto.createSign('sha256').update(new Buffer(username)).update(vbuffer).update(new Buffer(keys.dhPub)).update(new Buffer(keys.dsaPub)).sign(serverPrivateKey, 'base64')

            logger.debug "#{username}, serverSig: #{keys.serverSig}"

            #user id
            rc.incr "uid", (err, newid) ->
              return next err if err?

              user.id = newid

              cdb.insertPublicKeys username, keys, (err, result) ->
                return next err if err?
                multi = rc.multi()
                multi.hmset "u:#{username}", user
                multi.sadd "u", username
                multi.exec (err,replies) ->
                  return next err if err?
                  logger.warn "#{username} created, uid: #{user.id}, platform: #{platform}, version: #{version}"

                  #now we have a user we can create a session
                  initSession req, res, (err) ->
                    if err?
                      req.session?.destroy()
                      return next(err)

                    req.login username, ->
                      if referrers
                        handleReferrers username, referrers, next
                      else
                        next()

  app.get "/users/:username/exists", setNoCache, (req, res, next) ->
    logger.debug "/users/#{req.params.username}/exists"
    userExistsOrDeleted req.params.username, true, (err, exists) ->
      return next err if err?
      res.send exists

  validateVersion = (req, res, next) ->
    version = req.body.version ? "0:0"
    platform = req.body.platform
    logger.debug "validate platform #{platform}, version: #{version}"

    #don't let them login unless ios version >= 6
    if platform is 'ios'
      versions = version?.split ":"
      #tell them to upgrade
      intVersion = parseInt versions?[0]
      if isNaN intVersion
        return res.send 403
      else
        return res.send 403 if intVersion < 6

    next()


  updatePushIds = (req, res, next) ->
    #add push id

    #ids colon delimited

    gcmId = req.body.gcmId
    apnToken = req.body.apnToken

    logger.debug "received gcmId: #{gcmId} apnToken: #{apnToken}"

    return next() unless gcmId? or apnToken?

    username = req.user

    userKey = "u:" + username
    rcs.hgetall userKey, (err, user) ->
      return next() if err?

      updateGcmId = (callback) ->
        return callback() unless gcmId?

        gcmIds = user.gcmId?.split(":") ? []
        #if it's not in the list, add it
        if (gcmIds.indexOf(gcmId) is -1)

          gcmIds.push gcmId
          newIds =  gcmIds.filter((n) -> return n?.length > 0).join(":")
          logger.debug "adding gcm id #{gcmId} for #{username}, new list: #{newIds}"
          rc.hset userKey, 'gcmId', newIds, (err, result) ->
            logger.error "error setting gcmId for #{username}" if err?
            callback()
        else
          callback()

      updateGcmId ->
        return next() unless apnToken?

        apnTokens = user.apnToken?.split(":") ? []
        #if it's not in the list, add it
        if (apnTokens.indexOf(apnToken) is -1)
          apnTokens.push apnToken
          newTokens =  apnTokens.filter((n) -> return n?.length > 0).join(":")
          logger.debug "adding apn token #{apnToken} for #{username}, new list: #{newTokens}"
          #save mapping from token to username(s) so we can remove it if we get feedback

          #get the current mapping
          rc.hget "apnMap", apnToken, (err, usernameData) ->
            return next() if err?
            usernameList = usernameData

            #if we have a current mapping and the username is not in the list, add it
            if usernameData?
              usernames = usernameData.split(":")
              if (usernames.indexOf(username) is -1)
                usernames.push username
                usernameList = usernames.filter((n) -> return n?.length > 0).join(":")
            else
              usernameList = username

            logger.debug "setting map for apn token #{apnToken} to #{usernameList}"
            multi = rc.multi()
            multi.hset "apnMap", apnToken, usernameList
            multi.hset userKey, 'apnToken', newTokens
            multi.exec (err, results) ->
              logger.error "error setting apn tokens for user #{username}: #{err}" if err?
              next()
        else
          next()


  app.post "/users",
    validateVersion,
    validateUsernamePassword,
    createNewUser,
    passport.authenticate("local"),
    updatePushIds,
    updatePurchaseTokensMiddleware(true),
    (req, res, next) ->
      res.send 201

  #protocol changes
  app.post "/users2",
    validateUsernamePassword,
    createNewUser2,
    passport.authenticate("local"),
    updatePushIds,
    updatePurchaseTokensMiddleware(true),
    (req, res, next) ->
      res.send 201

  #end unauth'd methods
  app.post "/login", validateVersion, initSession, passport.authenticate("local"), updatePushIds, updatePurchaseTokensMiddleware(true), (req, res, next) ->
    username = req.user
    logger.debug "/login post, user #{username}"

    res.send 204

  app.post "/keytoken", setNoCache, (req, res, next) ->
    return res.send 400 unless req.body?.username?
    return res.send 400 unless req.body?.authSig?
    return res.send 400 unless req.body?.password?

    username = req.body.username
    password = req.body.password
    authSig = req.body.authSig
    validateUser username, password, authSig, (err, status, user) ->
      return next err if err?
      return res.send 403 unless user?

      #the user wants to update their key so we will generate a token that the user signs to make sure they're not using a replay attack of some kind
      #get the current version
      rc.hget "u:#{username}", "kv", (err, currkv) ->
        return next err if err?

        #inc key version
        kv = parseInt(currkv, 10) + 1
        generateSecureRandomBytes 'base64',(err, token) ->
          return next err if err?
          rc.set "kt:#{username}", token, (err, result) ->
            return next err if err?
            res.send {keyversion: kv, token: token}

  app.post "/keys", (req, res, next) ->
    logger.debug "/keys"
    return res.send 400 unless req.body?.username?
    return res.send 400 unless req.body?.authSig?
    return res.send 400 unless req.body?.password?
    return next new Error('dh public key required') unless req.body?.dhPub?
    return next new Error('dsa public key required') unless req.body?.dsaPub?
    return next new Error 'key version required' unless req.body?.keyVersion?
    return next new Error 'token signature required' unless req.body?.tokenSig?

    #make sure the key versions match
    username = req.body.username

    kv = req.body.keyVersion
    rc.hget "u:#{username}", "kv",(err, storedkv) ->
      return next err if err?

      newkv = parseInt storedkv, 10
      newkv++
      return next new Error 'key versions do not match' unless newkv is parseInt(kv, 10)

      #todo transaction
      #make sure the tokens match
      rc.get "kt:#{username}", (err, rtoken) ->
        return next new Error 'no keytoken exists' unless rtoken?
        newKeys = {}
        newKeys.version = newkv;
        newKeys.dhPub = req.body.dhPub
        newKeys.dsaPub = req.body.dsaPub

        logger.debug "received token signature: " + req.body.tokenSig
        logger.debug "received auth signature: " + req.body.authSig
        logger.debug "token: " + rtoken

        password = req.body.password

        #validate the signature against the token

        getLatestKeys username, (err, keys) ->
          return next err if err?
          return next new Error "no keys exist for user #{username}" unless keys?

          verified = verifySignature new Buffer(rtoken, 'base64'), new Buffer(password), req.body.tokenSig, keys.dsaPub
          return res.send 403 unless verified

          authSig = req.body.authSig
          validateUser username, password, authSig,(err, status, user) ->
            return next err if err?
            return res.send 403 unless user?

            #delete the token of which there should only be one
            rc.del "kt:#{username}", (err, rdel) ->
              return next err if err?
              return res.send 404 unless rdel is 1

              #sign the keys
              newKeys.dhPubSig = crypto.createSign('sha256').update(new Buffer(newKeys.dhPub)).sign(serverPrivateKey, 'base64')
              newKeys.dsaPubSig = crypto.createSign('sha256').update(new Buffer(newKeys.dsaPub)).sign(serverPrivateKey, 'base64')
              logger.debug "saving keys #{username}, dhPubSig: #{newKeys.dhPubSig}, dsaPubSig: #{newKeys.dsaPubSig}"


              #add the keys to the key set and add revoke message in transaction
              cdb.insertPublicKeys username, newKeys, (err, results) ->
                return next err if err?

                multi = rc.multi()

                #update the key version for user
                userKey = "u:#{username}"
                multi.hset userKey, "kv", newkv

                #if we have a gcm Id or apn token set it as the only one as other devices shouldn't be receiving push messages when they have old keys
                gcmId = req.body.gcmId

                if gcmId?
                  logger.debug "setting gcmid and removing apnToken for #{username}"
                  multi.hset userKey, "gcmId", gcmId
                  multi.hdel userKey, "apnToken"
                else
                  apnToken = req.body.apnToken
                  if apnToken?
                    logger.debug "setting apnToken and removing gcmId for #{username}"
                    multi.hset userKey, "apnToken", apnToken
                    multi.hdel userKey, "gcmId"
                  else
                    #if we were not sent the id by a recent version, blow it away
                    #todo remove this check once we are restricting versions
                    version = req.body.version
                    if version?
                      logger.debug "keys regenerated by client that knows to send version (#{version}), removing gcmid and apnToken from #{username}"
                      multi.hdel userKey, "gcmId"
                      multi.hdel userKey, "apnToken"


                #send revoke message
                multi.exec (err, replies) ->
                  return next err if err?
                  sendRevokeMessages username, kv
                  res.send 201

  app.post "/keys2", (req, res, next) ->
    logger.debug "/keys2"
    return res.send 400 unless req.body?.username?
    return res.send 400 unless req.body?.password?
    return res.send 400 unless req.body?.authSig?
    return res.send 400 unless req.body?.clientSig?
    return next new Error('dh public key required') unless req.body?.dhPub?
    return next new Error('dsa public key required') unless req.body?.dsaPub?


    return next new Error 'key version required' unless req.body?.keyVersion?
    return next new Error 'token signature required' unless req.body?.tokenSig?

    #make sure the key versions match
    username = req.body.username

    kv = req.body.keyVersion

    rc.hget "u:#{username}", "kv",(err, storedkv) ->
      return next err if err?

      oldkv = parseInt kv, 10
      newkv = parseInt storedkv, 10
      newkv++

      return next new Error 'key versions do not match' unless newkv is oldkv

      #todo transaction
      #make sure the tokens match
      rc.get "kt:#{username}", (err, rtoken) ->
        return next new Error 'no keytoken exists' unless rtoken?
        newKeys = {}
        newKeys.version = newkv;
        newKeys.dhPub = req.body.dhPub
        newKeys.dsaPub = req.body.dsaPub

        logger.debug "received token signature: " + req.body.tokenSig
        logger.debug "received auth signature: " + req.body.authSig
        logger.debug "token: " + rtoken

        password = req.body.password

        #validate the signature against the token

        getLatestKeys username, (err, currentKeys) ->
          return next err if err?
          return next new Error "no keys exist for user #{username}" unless currentKeys?


          verified = verifySignature new Buffer(rtoken, 'base64'), new Buffer(password), req.body.tokenSig, currentKeys.dsaPub
          return res.send 403 unless verified

          logger.debug "token signature verified"

          authSig = req.body.authSig
          validateUser username, password, authSig, (err, status, user) ->
            return next err if err?
            return res.send 403 unless user?

            logger.debug "user validated"

            #verify new client signature
            clientSig = req.body.clientSig
            verified = verifyClientSignature username, newkv, newKeys.dhPub, newKeys.dsaPub, clientSig, currentKeys.dsaPub
            return res.send 403 unless verified

            logger.debug "client signature verified"

            #delete the token of which there should only be one
            rc.del "kt:#{username}", (err, rdel) ->
              return next err if err?
              return res.send 404 unless rdel is 1

              #sign the keys protocol v1
              newKeys.dhPubSig = crypto.createSign('sha256').update(new Buffer(newKeys.dhPub)).sign(serverPrivateKey, 'base64')
              newKeys.dsaPubSig = crypto.createSign('sha256').update(new Buffer(newKeys.dsaPub)).sign(serverPrivateKey, 'base64')
              logger.debug "saving keys #{username}, dhPubSig: #{newKeys.dhPubSig}, dsaPubSig: #{newKeys.dsaPubSig}"

              #protocol v2 includes username and version in signature
              vbuffer = new Buffer(4)
              vbuffer.writeInt32LE(newkv, 0)
              newKeys.serverSig = crypto.createSign('sha256').update(new Buffer(username)).update(vbuffer).update(new Buffer(newKeys.dhPub)).update(new Buffer(newKeys.dsaPub)).sign(serverPrivateKey, 'base64')
              newKeys.clientSig = clientSig

              #add the keys to the key set and add revoke message in transaction
              cdb.insertPublicKeys username, newKeys, (err, results) ->
                return next err if err?

                multi = rc.multi()

                #update the key version for user
                userKey = "u:#{username}"
                multi.hset userKey, "kv", newkv

                #if we have a gcm Id or apn token set it as the only one as other devices shouldn't be receiving push messages when they have old keys
                gcmId = req.body.gcmId

                if gcmId?
                  logger.debug "setting gcmid and removing apnToken for #{username}"
                  multi.hset userKey, "gcmId", gcmId
                  multi.hdel userKey, "apnToken"
                else
                  apnToken = req.body.apnToken
                  if apnToken?
                    logger.debug "setting apnToken and removing gcmId for #{username}"
                    multi.hset userKey, "apnToken", apnToken
                    multi.hdel userKey, "gcmId"
                  else
                    #if we were not sent the id by a recent version, blow it away
                    #todo remove this check once we are restricting versions
                    version = req.body.version
                    if version?
                      logger.debug "keys regenerated by client that knows to send version (#{version}), removing gcmid and apnToken from #{username}"
                      multi.hdel userKey, "gcmId"
                      multi.hdel userKey, "apnToken"


                #send revoke message
                multi.exec (err, replies) ->
                  return next err if err?
                  sendRevokeMessages username, kv
                  res.send 201

  app.post "/sigs", ensureAuthenticated, (req,res,next) ->

    return res.send 400 unless req.body?.sigs?
    logger.info "received sigs: #{req.body.sigs}"

    clientsigs = JSON.parse req.body.sigs
    username = req.user

    #get all public keys
    cdb.getPublicKeysSince username, 1, (err, keys) ->
      return next err if err?
      #check counts match

      keyCount = keys?.length
      return res.send 400 unless Object.keys(clientsigs).length is keyCount

      keysObject = {}
      async.each(
        keys
        (key, callback) ->
          keysObject[parseInt(key.version,10)] = key
          callback()
        (err) ->

          serverSigs = {}
          #iterate through keys and check sigs

          async.each(
            keys
            (key, callback) ->
              version = parseInt key.version, 10
              clientsig = clientsigs[key.version]
              previousDsaKey = if version is 1 then key.dsaPub else keysObject[version-1].dsaPub

              logger.info "verifying client sig"
              #validate sigs against stored keys
              verified = verifyClientSignature username, version, key.dhPub, key.dsaPub, clientsig, previousDsaKey
              return callback new Error 'signature check failed' unless verified

              logger.info "client sig verified"
              #generate server sig
              #protocol v2 includes username and version in signature
              vbuffer = new Buffer(4)
              vbuffer.writeInt32LE(version, 0)
              serverSig = crypto.createSign('sha256').update(new Buffer(username)).update(vbuffer).update(new Buffer(key.dhPub)).update(new Buffer(key.dsaPub)).sign(serverPrivateKey, 'base64')
              serverSigs[key.version] = serverSig


              callback()
            (err) ->
              return next err if err?

              #update sigs in db
              cdb.updatePublicKeySignatures username, clientsigs, serverSigs, (err) ->
                return next err if err?
                #update sigs in db
                #update sig flag for user
                rc.hset "u:#{username}", 'sigs', true, (err) ->
                  return next err if err?
                  res.send 201
          )
      )


  app.post "/validate", (req, res, next) ->
    return res.send 400 unless req.body?.username?
    return res.send 400 unless req.body?.password?
    return res.send 400 unless req.body?.authSig?
    username = req.body.username
    password = req.body.password
    authSig = req.body.authSig

    validateUser username, password, authSig, (err, status) ->
      return next err if err?
      res.send status

  app.post "/registergcm", ensureAuthenticated, updatePushIds, (req, res, next) ->
    res.send 204



  inviteUser = (username, friendname, source, callback) ->
    return callback null, false unless friendname?
    #keep running count of autoinvites
    if source?
      logger.debug "#{username} invited #{friendname} via #{source}"
      rc.hincrby "ai", source, 1


    multi = rc.multi()
    #remove you from my blocked set if you're blocked
    multi.srem "b:#{username}", friendname
    multi.sadd "is:#{username}", friendname
    multi.sadd "ir:#{friendname}", username
    #add one to activity count if user not connected
    roomCount = sio.sockets.clients(friendname).length
    logger.debug "room clients for #{friendname}, #{roomCount}"
    if roomCount is 0
      #increment new message count
      multi.hincrby "u:#{friendname}", "ac", 1

    multi.exec (err, results) ->
      return callback err if err?
      invitesCount = results[2]
      #send to room
      if invitesCount > 0
        createAndSendUserControlMessage username, "invited", friendname, null, (err) ->
          return callback err if err?
          createAndSendUserControlMessage friendname, "invite", username, null, (err) ->
            return callback err if err?
            #send push notification
            process.nextTick ->
              sendPushInvite(username, friendname)
            callback null, true
      else
        callback null, false

  sendPushInvite = (username, friendname) ->
    userKey = "u:" + friendname

    rc.hmget userKey, ["gcmId", "apnToken", "ac"], (err, ids) ->
      if err?
        logger.error "inviteUser, " + err
        return

      gcmIds = ids[0]?.split(":")
      apn_tokens = ids[1]?.split(":")

      if gcmIds?.length > 0
        logger.debug "sending gcms for invite"
        gcmmessage = new gcm.Message()
        sender = new gcm.Sender("#{googleApiKey}", {maxSockets: MAX_GCM_SOCKETS})
        gcmmessage.addData "type", "invite"
        gcmmessage.addData "sentfrom", username
        gcmmessage.addData "to", friendname
        gcmmessage.delayWhileIdle = false
        gcmmessage.timeToLive = GCM_TTL
        #gcmmessage.collapseKey = "invite:#{friendname}"

        sender.send gcmmessage, gcmIds, GCM_RETRIES, (err, result) ->
          return logger.error "Error sending invite gcm from: #{username}, to: #{friendname}: #{err}" if err? or not result?
          logger.debug "sent gcm for invite: #{JSON.stringify(result)}"
          if result.failure > 0
            removeGcmIds friendname, gcmIds, result.results

          if result.canonical_ids > 0
            handleCanonicalIds friendname, gcmIds, result.results
      else
        logger.debug "gcmIds not set for #{friendname}"

      if apn_tokens?.length > 0
        logger.debug "sending apns for invite"
        async.each(
          apn_tokens,
          (token, callback) ->
            apnDevice = new apn.Device token
            note = new apn.Notification()

            badgeNum = parseInt ids[2]
            badgeNum = if isNaN(badgeNum) then 0 else badgeNum

            note.badge = badgeNum
            note.sound = "surespot-invite.caf"
            note.alert = { "loc-key": "notification_invite", "loc-args": [friendname, username] }
            apnConnection.pushNotification note, apnDevice
            callback()
          (err) ->
            logger.error "error sending invite apns: #{err}" if err?
        )


      else
        logger.debug "no apn tokens for #{friendname}"

  handleInvite = (req,res,next) ->
    friendname = req.params.username
    username = req.user
    source = req.params.source ? "manual"

    # the caller wants to add himself as a friend
    if friendname is username then return res.send 403

    logger.debug "#{username} inviting #{friendname} to be friends"

    multi = rc.multi()
    #check if friendname has blocked username - 404
    multi.sismember "b:#{friendname}", username

    #if he's deleted me then 404
    multi.sismember "ud:#{username}", friendname

    #if i've previously deleted the user and I invite him now then unmark me as deleted to him
    #multi.srem "ud:#{friendname}", username

    multi.exec (err, results) ->
      return next err if err?
      return res.send 404 if 1 in [results[0],results[1]]

      #see if they are already friends
      isFriend username, friendname, (err, result) ->
        #if they are, do nothing
        if result then res.send 409
        else
          #see if there's already an invite and if so accept automatically
          inviteExists friendname, username, (err, invited) ->
            return next err if err?
            if invited
              deleteInvites username, friendname, (err) ->
                return next err if err?
                createFriendShip username, friendname, (err) ->
                  return next err if err?
                  process.nextTick ->
                    sendPushInviteAccept username, friendname
                    sendPushInviteAccept friendname, username
                  res.send 204
            else
              inviteUser username, friendname, source, (err, inviteSent) ->
                res.send if inviteSent then 204 else 403


  app.post "/invite/:username/:source", ensureAuthenticated, validateUsernameExists, handleInvite
  app.post "/invite/:username", ensureAuthenticated, validateUsernameExists, handleInvite


  createFriendShip = (username, friendname, callback) ->
    logger.debug "#{username} accepted #{friendname}"
    multi = rc.multi()
    multi.sadd "f:#{username}", friendname
    multi.sadd "f:#{friendname}", username
    multi.srem "ud:#{username}", friendname
    multi.srem "ud:#{friendname}", username
    multi.srem "od:#{username}", friendname
    multi.srem "od:#{friendname}", username
    multi.exec (err, results) ->
      return callback new Error("createFriendShip failed for username: " + username + ", friendname" + friendname) if err?
      createAndSendUserControlMessage username, "added", friendname, username, (err) ->
        return callback err if err?
        createAndSendUserControlMessage friendname, "added", username, username, (err) ->
          return callback err if err?
          callback null

  deleteInvites = (username, friendname, callback) ->
    multi = rc.multi()
    multi.srem "ir:#{username}", friendname
    multi.srem "is:#{friendname}", username
    multi.exec (err, results) ->
      return callback new Error("[friend] srem failed for ir:#{username}:#{friendname}") if err?
      callback null

  sendPushInviteAccept = (username, friendname) ->
    userKey = "u:" + friendname

    rc.hmget userKey, ["gcmId", "apnToken", "ac"], (err, ids) ->
      if err?
        logger.error "sendPushInviteAccept, #{err}"
        return

      gcmIds = ids[0]?.split(":")
      apn_tokens = ids[1]?.split(":")

      if gcmIds?.length > 0
        logger.debug "sending gcms for invite response notification #{username} #{friendname}"

        gcmmessage = new gcm.Message()
        sender = new gcm.Sender("#{googleApiKey}", {maxSockets: MAX_GCM_SOCKETS})
        gcmmessage.addData("type", "inviteResponse")
        gcmmessage.addData "sentfrom", username
        gcmmessage.addData "to", friendname
        gcmmessage.addData("response", "accept")
        gcmmessage.delayWhileIdle = false
        gcmmessage.timeToLive = GCM_TTL
        #gcmmessage.collapseKey = "inviteResponse"

        sender.send gcmmessage, gcmIds, GCM_RETRIES, (err, result) ->
          return logger.error "Error sending push invite gcm from: #{username}, to: #{friendname}: #{err}" if err? or not result?
          logger.debug "sendGcm for invite response notification ok #{username} #{friendname}"
          if result.failure > 0
            removeGcmIds friendname, gcmIds, result.results

          if result.canonical_ids > 0
            handleCanonicalIds friendname, gcmIds, result.results

      if apn_tokens?.length > 0
        logger.debug "sending apns for invite response"

        async.each(
          apn_tokens,
          (token, callback) ->
            apnDevice = new apn.Device token
            note = new apn.Notification()

            badgeNum = parseInt ids[2]
            badgeNum = if isNaN(badgeNum) then 0 else badgeNum

            note.badge = badgeNum
            note.sound = "invite-accept.caf"
            note.alert = { "loc-key": "notification_invite_accept", "loc-args": [friendname, username] }
            apnConnection.pushNotification note, apnDevice
            callback()
          (err) ->
            logger.error "error sending invite response apns: #{err}" if err?
        )

      else
        logger.debug "no apn token for #{friendname}"


  app.post '/invites/:username/:action', ensureAuthenticated, validateUsernameExists, (req, res, next) ->
    return next new Error 'action required' unless req.params.action?


    username = req.user
    friendname = req.params.username
    action = req.params.action

    logger.debug "#{username} #{action} #{friendname}"

    #make sure invite exists
    inviteExists friendname, username, (err, result) ->
      return next err if err?
      return res.send 404 if not result

      deleteInvites username, friendname, (err) ->
        return next err if err?
        switch action
          when 'accept'
            createFriendShip username, friendname, (err) ->
              return next err if err?

              process.nextTick ->
                #increment activity counter if not currently connected
                roomCount = sio.sockets.clients(friendname).length
                logger.debug "room clients for #{friendname}, #{roomCount}"
                if roomCount is 0
                  #increment new message count
                  rc.hincrby "u:#{friendname}", "ac", 1, (err, result) ->
                    sendPushInviteAccept(username, friendname)
                else
                    sendPushInviteAccept(username, friendname)
              res.send 204
          when 'ignore'
            createAndSendUserControlMessage friendname, 'ignore', username, null, (err) ->
              return next err if err?
              createAndSendUserControlMessage username, 'ignore', username, null, (err) ->
                return next err if err?
                res.send 204

          when 'block'
            rc.sadd "b:#{username}", friendname, (err, data) ->
              return next err if err?
              createAndSendUserControlMessage friendname, 'ignore', username, null, (err) ->
                return next err if err?
                createAndSendUserControlMessage username, 'ignore', username, null, (err) ->
                  return next err if err?
                  res.send 204

          else return next new Error 'invalid action'

  getFriends = (req, res, next) ->
    username = req.user
    #get users we're friends with
    rc.smembers "f:#{username}", (err, rfriends) ->
      return next err if err?
      friends = []
      return res.send {} unless rfriends?

      cdb.getAllFriendData username, (err, friendDatas) ->
        return next err if err?

        _.each rfriends, (name) ->
          #if we have friend data use it, otherwise create a new friend object
          friend = friendDatas[name]
          if not friend?
            friend = new common.Friend name, 0
          friends.push friend



        #get users that invited us
        rc.smembers "ir:#{username}", (err, invites) ->
          return next err if err?
          _.each invites, (name) -> friends.push new common.Friend name, 32

          #get users that we invited
          rc.smembers "is:#{username}", (err, invited) ->
            return next err if err?
            _.each invited, (name) -> friends.push new common.Friend name, 2

            #get users that deleted us that we haven't deleted
            rc.smembers "ud:#{username}", (err, deleted) ->
              return next err if err?
              _.each deleted, (name) ->

                friend = friends.filter (friend) -> friend.name is name

                if friend.length is 1
                  friend[0].flags += 1
                else
                  friends.push new common.Friend name, 1

              rc.hget "ucmcounters", username, (err, id) ->
                friendstate = {}
                friendstate.userControlId = id ? 0
                friendstate.friends = friends

                sFriendState = JSON.stringify friendstate
                logger.debug ("friendstate: " + sFriendState)
                res.setHeader('Content-Type', 'application/json');
                res.send friendstate

  app.get "/friends", ensureAuthenticated, setNoCache, getFriends

  app.post "/users/delete", (req, res, next) ->
    logger.debug "/users/delete"
    return res.send 400 unless req.body?.username?
    return res.send 400 unless req.body?.authSig?
    return res.send 400 unless req.body?.password?
    return next new Error 'key version required' unless req.body?.keyVersion?
    return next new Error 'token signature required' unless req.body?.tokenSig?


    #make sure the key versions match
    username = req.body.username

    kv = req.body.keyVersion
    logger.debug "signed with keyversion: " + kv
    #todo transaction
    #todo defer sending control messages on socket until multi.exec has occured
    #make sure the tokens match
    rc.get "dt:#{username}", (err, rtoken) ->
      return next new Error 'no delete token' unless rtoken?
      logger.debug "token: " + rtoken

      password = req.body.password

      #validate the signature against the token

      getKeys username, kv, (err, keys) ->
        return next err if err?
        return next new Error "no keys exist for user #{username}" unless keys?

        #verified = crypto.createVerify('sha256').update(token).update(new Buffer(password)).verify(keys.dsaPub, new Buffer(req.body.tokenSig, 'base64'))

        verified = verifySignature new Buffer(rtoken, 'base64'), new Buffer(password), req.body.tokenSig, keys.dsaPub
        return res.send 403 unless verified

        authSig = req.body.authSig
        validateUser username, password, authSig, (err, status, user) ->
          return next(err) if err?
          return res.send 403 unless user?

          #delete the token of which there should only be one
          rc.del "dt:#{username}", (err, rdel) ->
            return next err if err?
            return res.send 404 unless rdel is 1

            multi = rc.multi()

            #delete invites
            multi.del "ir:#{username}"
            multi.del "is:#{username}"
            #tell users that invited me that i'm deleted
            #get users that invited us
            rc.smembers "ir:#{username}", (err, invites) ->
              return next err if err?
              #delete their invites
              async.each(
                invites,
                (name, callback) ->
                  multi.srem "is:#{name}", username

                  #tell them we've been deleted
                  createAndSendUserControlMessage name, "delete", username, username, (err) ->
                    #return callback err if err?
                    callback()
                (err) ->
                  return next err if err?
                  #delete my invites to them
                  rc.smembers "is:#{username}", (err, invited) ->
                    return next err if err?

                    async.each(
                      invited,
                      (name, callback) ->
                        multi.srem "ir:#{name}", username

                        #tell them we've been deleted
                        createAndSendUserControlMessage name, "delete", username, username, (err) ->
                          #return callback err if err?
                          callback()
                      (err) ->
                        return next err if err?

                        #copy data from user's list of friends to list of deleted users friends
                        rc.smembers "f:#{username}", (err, friends) ->
                          return next err if err?

                          addDeletedFriend = (friends, callback) ->
                            if friends.length > 0
                              rc.sadd "d:#{username}", friends, (err, nadded) ->
                                return next err if err?
                                callback()
                            else
                              callback()

                          addDeletedFriend friends, (err) ->
                            return next err if err?

                            #remove me from the global set of users
                            multi.srem "u", username

                            #add me to the global set of deleted users
                            multi.sadd "d", username

                            #delete user data
                            multi.del "u:#{username}"

                            #add user to each friend's set of deleted users
                            async.each(
                              friends,
                              (friend, callback) ->
                                deleteUser username, friend, multi, (err) ->
                                  return callback err if err?

                                  #tell them we've been deleted
                                  createAndSendUserControlMessage friend, "delete", username, username, (err) ->
                                    return callback err if err?
                                    callback()
                              (err) ->
                                return next err if err?
                                createAndSendUserControlMessage username, "revoke", username, "#{parseInt(kv, 10) + 1}", (err) ->
                                  return next err if err?

                                  #if we don't have any friends aww, just blow everything away
                                  nofriends = (callback) ->

                                    if friends.length is 0
                                      #if we deleted someone but they haven't deleted us yet
                                      #this set will be populated
                                      rc.scard "od:#{username}", (err, card) ->
                                        if card is 0
                                          deleteRemainingIdentityData multi, username, callback
                                        else
                                          callback()
                                    else
                                      callback()

                                  nofriends ->
                                    multi.exec (err, replies) ->
                                      return next err if err?
                                      res.send 204)))


  app.put "/users/password", (req, res, next) ->
    logger.debug "/users/password"
    return res.send 400 unless req.body?.username?
    return res.send 400 unless req.body?.authSig?
    return res.send 400 unless req.body?.password?
    return next new Error 'newPassword required' unless req.body?.newPassword?
    return next new Error 'keyVersion required' unless req.body?.keyVersion?
    return next new Error 'tokenSig required' unless req.body?.tokenSig?


    #make sure the key versions match
    username = req.body.username

    kv = req.body.keyVersion
    logger.debug "signed with keyversion: " + kv
    #todo transaction
    #make sure the tokens match
    rc.get "pt:#{username}", (err, rtoken) ->
      return next new Error 'no password token' unless rtoken?
      logger.debug "token: " + rtoken

      password = req.body.password
      newPassword = req.body.newPassword
      #validate the signature against the token

      getKeys username, kv, (err, keys) ->
        return next err if err?
        return next new Error "no keys exist for user #{username}" unless keys?

        verified = verifySignature new Buffer(rtoken, 'base64'), new Buffer(newPassword), req.body.tokenSig, keys.dsaPub
        return res.send 403 unless verified

        authSig = req.body.authSig
        validateUser username, password, authSig, (err, status, user) ->
          return next(err) if err?
          return res.send 403 unless user?

          #delete the token of which there should only be one
          rc.del "pt:#{username}", (err, rdel) ->
            return next err if err?
            return res.send 404 unless rdel is 1

            bcrypt.genSalt 10, 32, (err, salt) ->
              return next err if err?

              bcrypt.hash newPassword, salt, (err, hashedPassword) ->
                return next err if err?
                rc.hset "u:#{username}", "password", hashedPassword, (err, set) ->
                  return next err if err?
                  res.send 204


  app.delete "/friends/:username", ensureAuthenticated, validateUsernameExistsOrDeleted, validateAreFriendsOrDeletedOrInvited, (req, res, next) ->
    username = req.user
    theirUsername = req.params.username

    multi = rc.multi()
    deleteUser username, theirUsername, multi, (err) ->
      return next err if err?

      #tell other connections logged in as us that we deleted someone
      createAndSendUserControlMessage username, "delete", theirUsername, username, (err) ->
        return next err if err?
        #tell them they've been deleted
        createAndSendUserControlMessage theirUsername, "delete", username, username, (err) ->
          return next err if err?
          multi.exec (err, results) ->
            return next err if err?
            res.send 204

  deleteRemainingIdentityData = (multi, username, callback) ->
    logger.debug "deleteRemaingingIdentityData #{username}"
    #cleanup stuff
    #delete message pointers
    multi.del "m:#{username}"
    multi.del "f:#{username}"
    multi.del "is:#{username}"
    multi.del "u:#{username}"
    multi.del "ud:#{username}"
    multi.del "c:#{username}"
    multi.del "od:#{username}"
    multi.hdel "ucmcounters", username
    multi.srem "d", username

    cdb.deleteAll username, (err, results) ->
      logger.error "error deleting all data for #{username}: #{err}" if err?
      callback()

  deleteUser = (username, theirUsername, multi, next) ->
    #check if they've only been invited
    rc.sismember "is:#{username}", theirUsername, (err, isInvited) ->
      return next err if err?
      if isInvited
        deleteInvites theirUsername, username, (err) ->
          return next err if err?
          next()
      else
        room = common.getSpotName username, theirUsername

        #delete the conversation with this user from the set of my conversations
        multi.srem "c:#{username}", room

        cdb.getFriendData username, theirUsername, (err, friend) ->
          logger.error "error getting friend data #{err}" if err?

          if friend?.imageUrl?
            deleteFile friend.imageUrl, "image/"

          cdb.deleteFriendData username, theirUsername, (err, results) ->
            logger.error "error deleting friend data #{err}" if err?


        #todo delete related user control messages

        #if i've been deleted by them this will be populated with their username
        rc.sismember "ud:#{username}", theirUsername, (err, theyHaveDeletedMe) ->
          return next err if err?

          #if we are deleting them and they haven't deleted us already
          if not theyHaveDeletedMe
            #delete our messages with the other user
            #get the latest id
            rc.hget "mcounters", room, (err, id) ->
              logger.debug "deleting messages for #{room}, #{id}"
              return next err if err?
              #handle no id
              deleteMessages = (messageId, callback) ->
                if messageId?
                  deleteAllMessages username, theirUsername, id, (err) ->
                    return callback err if err?
                    callback()
                else
                  callback()

              deleteMessages id, (err) ->
                return next err if err?
                #delete friend association
                multi.srem "f:#{username}", theirUsername
                multi.srem "f:#{theirUsername}", username

                rc.sismember "d", theirUsername, (err, isDeleted) ->
                  return next err if err?
                  if not isDeleted
                    #add them to my deleted users set
                    multi.sadd "od:#{username}", theirUsername
                    #add me to their set of deleted users if they're not deleted
                    multi.sadd "ud:#{theirUsername}", username
                  next()

          #they've already deleted me
          else
            #remove me from their deleted set (if they deleted their identity) (don't use multi so we can check card post removal later)
            rc.srem "d:#{theirUsername}", username, (err, rCount) ->
              return next err if err?

              #if they have been deleted and we are the last person to delete them
              #remove the final pieces of data
              rc.sismember "d", theirUsername, (err, isDeleted) ->
                return next err if err?

                deleteLastUserScraps = (callback) ->

                  if isDeleted
                    rc.scard "d:#{theirUsername}", (err, card) ->
                      return callback err if err?
                      if card is 0
                        deleteRemainingIdentityData multi, theirUsername, callback
                      else
                        callback()
                  else
                    callback()

                deleteLastUserScraps (err) ->
                  return next err if err?

                  rc.hget "mcounters", room, (err, id) ->
                    return next err if err?
                    deleteMessages = (callback) ->
                      if id?
                        deleteAllMessages username, theirUsername, id, (err) ->
                          return callback err if err?
                          callback()
                      else
                        callback()

                    deleteMessages (err) ->
                      return next err if err?

                      cdb.deleteAllControlMessages room, (err, results) ->
                        logger.error "Could not delete spot #{room} control messages" if err?
                        logger.debug "deleteAllControlMessages completed"

                      #delete counters
                      #TODO remove when cassandra bug fixed
                      #multi.hdel "mcmcounters",room

                      #remove message counters for the conversation
                      #multi.hdel "mcounters", room

                      #remove them from my deleted set
                      multi.srem "ud:#{username}", theirUsername

                      #remove me from their deleted set
                      multi.srem "od:#{theirUsername}", username

                      cdb.deleteAllMessages room, (err, results) ->
                        logger.error "Could not delete spot #{room} messages" if err?
                        logger.debug "deleteAllControlMessages completed"
                      next()


  app.post "/logout", ensureAuthenticated, (req, res) ->
    logger.debug "#{req.user} logged out"
    req.logout()
    req.session?.destroy()
    res.send 204


  app.get "/yourmama", (req, res) ->
    phrase = "is niiiice"
    date = new Date().toString()
    redismama = phrase + ":" + date
    rc.set "yourmama", redismama, (err, result) ->
      return res.send 500 if err?
      cdb.insertYourmama phrase, date, (err, results) ->
        return res.send 500 if err?
        res.send redismama


  generateSecureRandomBytes = (encoding, callback) ->
    crypto.randomBytes 32, (err, bytes) ->
      return callback err if err?
      callback null, bytes.toString(encoding)

  generateRandomBytes = (encoding, callback) ->
    crypto.pseudoRandomBytes 16, (err, bytes) ->
      return callback err if err?
      callback null, bytes.toString(encoding)

  comparePassword = (password, dbpassword, callback) ->
    bcrypt.compare password, dbpassword, callback

  getLatestKeys = (username, callback) ->
    rc.hget "u:#{username}", "kv", (err, version) ->
      return callback err if err?
      return callback new Error "no keys exist for user: #{username}" unless version?
      getKeys username, version, callback

  getKeys = (username, version, callback) ->
    cdb.getPublicKeys username, parseInt(version, 10), callback

  verifySignature = (b1, b2, sigString, pubKey) ->
    return false unless b1?.length > 0 && b2?.length > 0 && sigString?.length > 0 && pubKey?.length > 0
    #get the signature
    buffer = new Buffer(sigString, 'base64')

    #random is stored in first 16 bytes
    random = buffer.slice 0, 16
    signature = buffer.slice 16

    return crypto.createVerify('sha256').update(b1).update(b2).update(random).verify(pubKey, signature)


  verifyClientSignature = (username, version, dhPubKey, dsaPubKey, sigString, dsaSigningKey) ->
    return false unless username?.length > 0 && version? && dhPubKey.length > 0 && dsaPubKey.length > 0 && sigString?.length > 0 && dsaSigningKey?.length > 0    #get the signature
    signature = new Buffer(sigString, 'base64')
    vbuffer = new Buffer(4)
    vbuffer.writeInt32LE(version, 0)
    return crypto.createVerify('sha256').update(new Buffer(username)).update(vbuffer).update(new Buffer(dhPubKey)).update(new Buffer(dsaPubKey)).verify(dsaSigningKey, signature)



  validateUser = (username, password, signature, done) ->
    return done(null, 403) if (!checkUser(username) or !checkPassword(password))
    return done(null, 403) if signature?.length < 16
    userKey = "u:" + username
    logger.debug "validating: #{username}"

    multi = rc.multi()
    multi.sismember "u", username
    multi.hgetall userKey
    multi.exec (err, results) ->
      return done(err) if err?
      return done null, 404 unless results[0]
      user = results[1]
      return done null, 404 unless user?.password?
      comparePassword password, user.password, (err, res) ->
        return done err if err?
        return done null, 403 unless res

        #not really worried about replay attacks here as we're using ssl but as extra security the server could send a challenge that the client would sign as we do with key roll
        getLatestKeys username, (err, keys) ->
          return done err if err?
          return done new Error "no keys exist for user #{username}" unless keys?

          verified = verifySignature new Buffer(username), new Buffer(password), signature, keys.dsaPub
          logger.debug "validated, #{username}: #{verified}"

          status = if verified then 204 else 403
          done null, status, if verified then user.username else null


  passport.use new LocalStrategy ({passReqToCallback: true}), (req, username, password, done) ->
    #logger.debug "client ip: #{req.connection.remoteAddress}"
    signature = req.body.authSig
    validateUser username, password, signature, (err, status, vusername) ->
      if err?
        req.session?.destroy()
        return done(err)

      switch status
        when 404
          req.session?.destroy()
          return done null, false, message: "unknown user"
        when 403
          req.session?.destroy()
          return done null, false, message: "invalid password or key"
        when 204 then return done null, vusername
        else
          req.session?.destroy()
          return new Error "unknown validation status: #{status}"

  passport.serializeUser (username, done) ->
    logger.debug "serializeUser, username: " + username
    done null, username

  passport.deserializeUser (username, done) ->
    logger.debug "deserializeUser, user:" + username
    rcs.hget "u:" + username, "username", (err, user) ->
      done err, user


  #apn feedback
  apnFeedbackOptions = {
    batchFeedback: true
    cert: "apn#{env}/cert.pem"
    key: "apn#{env}/key.pem"
  }

  apnFeedback = new apn.Feedback(apnFeedbackOptions)
  apnFeedback.on "feedback", (devices) ->
    devices.forEach (item) ->
      apnToken = item.device.token.toString('hex')
      logger.debug "apnFeedback, token: #{apnToken} time: #{item.time}"
      rc.hget "apnMap", apnToken, (err, usernameList) ->
        if usernameList?
          multi = rc.multi()
          usernames = usernameList.split(":")
          async.each(
            usernames,
            (username, callback) ->
              userKey = "u:" + username
              rcs.hgetall userKey, (err, user) ->
                return callback(err) if err?

                apnTokens = user?.apnToken?.split(":") ? []
                #if it's in the list, remove it
                index = apnTokens.indexOf(apnToken)

                return callback() if index == -1

                apnTokens.splice index, 1
                newTokens = apnTokens.filter((n) -> return n?.length > 0).join(":")

                logger.debug "removing apn token #{apnToken} from #{username}, new list: #{newTokens}"

                #remove mapping
                multi.hdel "apnMap", apnToken

                #set or remove token list
                if newTokens?.length > 0
                  multi.hset userKey, 'apnToken', newTokens
                else
                  multi.hdel userKey, 'apnToken'

                callback()

            (err) ->
              return logger.error "error removing apn token: #{err}" if err?
              multi.exec (err, results) ->
                logger.error "error removing apn tokens for users #{usernameList}: #{err}" if err?
          )

  removeGcmIds = (username, gcmIds, results) ->
    indexesToRemove = []
    #check for errors and remove gcm id from user if so
    _.each(
      results,
    (item, index) ->
      error = item.error
      if error is "NotRegistered" or error is "InvalidRegistration"
        indexesToRemove.push index)

    saveGcms = []
    for i in [0..gcmIds.length] by 1
      if indexesToRemove.indexOf(i) > -1
        logger.debug "removing gcmId #{gcmIds[i]} from user #{username}"
      else
        saveGcms.push gcmIds[i]

    userKey = "u:#{username}"
    if saveGcms?.length > 0
      saveGcmString = saveGcms.filter((n) -> n?.length > 0).join(":")

      if saveGcmString?.length > 0
        logger.debug "setting remaining gcmids #{saveGcmString} for user #{username}"
        rc.hset userKey, 'gcmId', saveGcmString, (err, result) ->
          logger.error "error setting gcmIds for #{username}" if err?
      else
        logger.debug "removing all gcmids for user #{username}"
        rc.hdel userKey, "gcmId", (err, result) ->
          logger.error "error removing gcmIds for #{username}" if err?
    else
      logger.debug "removing all gcmids for user #{username}"
      rc.hdel userKey, "gcmId", (err, result) ->
        logger.error "error removing gcmIds for #{username}" if err?

  handleCanonicalIds = (username, gcmIds, results) ->
    #replace ids with canonical ids
    logger.debug "replacing with canonical ids for user #{username}"
    _.each(
      results,
      (item, index) ->
        newId = item.registration_id
        if newId?
          logger.debug "replacing #{gcmIds[index]} with #{newId} for user #{username}"
          gcmIds[index] = newId)

    userKey = "u:#{username}"
    if gcmIds?.length > 0
      #make sure they are unique
      uniqueIds = _.uniq(gcmIds)
      saveGcmString = uniqueIds.filter((n) -> n?.length > 0).join(":")
      logger.debug "setting gcmids #{saveGcmString} for user #{username}"
      rc.hset userKey, 'gcmId', saveGcmString, (err, result) ->
        logger.error "error setting gcmIds for #{username}" if err?

