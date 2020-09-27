###

  db migration script
  copyright 2fours LLC
  written by Adam Patacchiola adam@2fours.com

###
env = process.env.SURESPOT_ENV ? 'Local' # one of "Local","Stage", "Prod"
async = require 'async'
_ = require 'underscore'
cdb = require '../cdb'
common = require '../common'

#constants
USERNAME_LENGTH = 20
CONTROL_MESSAGE_HISTORY = 100
MAX_MESSAGE_LENGTH = 500000
MAX_HTTP_REQUEST_LENGTH = 500000
NUM_CORES =  parseInt(process.env.SURESPOT_CORES) ? 4
GCM_TTL = 604800

oneYear = 31536000000
oneDay = 86400

#config

#rate limit to MESSAGE_RATE_LIMIT_RATE / MESSAGE_RATE_LIMIT_SECS (seconds) (allows us to get request specific on top of iptables)
RATE_LIMITING_MESSAGE=process.env.SURESPOT_RATE_LIMITING_MESSAGE is "true"
RATE_LIMIT_BUCKET_MESSAGE = process.env.SURESPOT_RATE_LIMIT_BUCKET_MESSAGE ? 5
RATE_LIMIT_SECS_MESSAGE = process.env.SURESPOT_RATE_LIMIT_SECS_MESSAGE ? 10
RATE_LIMIT_RATE_MESSAGE = process.env.SURESPOT_RATE_LIMIT_RATE_MESSAGE ? 100

MESSAGES_PER_USER = process.env.SURESPOT_MESSAGES_PER_USER ? 500
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
redisSentinelPort = parseInt(process.env.SURESPOT_REDIS_SENTINEL_PORT) ? 6379
redisSentinelHostname = process.env.SURESPOT_REDIS_SENTINEL_HOSTNAME ? "127.0.0.1"
redisPassword = process.env.SURESPOT_REDIS_PASSWORD ? null
useRedisSentinel = process.env.SURESPOT_USE_REDIS_SENTINEL is "true"
bindAddress = process.env.SURESPOT_BIND_ADDRESS ? "0.0.0.0"
dontUseSSL = process.env.SURESPOT_DONT_USE_SSL is "true"
apnGateway = process.env.SURESPOT_APN_GATEWAY
useSSL = not dontUseSSL

http = if useSSL then require 'https' else require 'http'


sio = undefined
sessionStore = undefined
rc = undefined
rcs = undefined
pub = undefined
sub = undefined
redback = undefined
client = undefined
client2 = undefined
app = undefined
ssloptions = undefined
oauth2Client = undefined
iapClient = undefined

cdb.connect (err) ->
  if err?
    console.log 'could not connect to cassandra'
    process.exit(1)



redis = undefined
if useRedisSentinel
  redis = require 'redis-sentinel-client'
else
  #use forked redis
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

rc = createRedisClient database, redisSentinelPort, redisSentinelHostname, redisPassword

#migrate active users
rc.smembers "u", (err, users) ->
  console.log "error #{err}" && process.exit(10) if err?
  console.log "migrating users"
  for user in users
    do (user) ->
      console.log "migrating user #{user}"
      #insert messages for both users
      #get conversations
      rc.smembers "c:#{user}", (err, conversations) ->
        console.log "error #{err}" && process.exit(10) if err?
        for c in conversations
          do (c) ->
            #copy counter
            rc.get "cm:#{c}:id", (err, counter) ->
              console.log "error #{err}" && process.exit(10) if err?
              console.log "#{c} cm counter: #{counter}"
              if counter?
                console.log "moving #{c} cm counter to hash"
                rc.hset "mcmcounters", "#{c}", counter, (err, d) ->
                  console.log "error #{err}" && process.exit(10) if err?
                  rc.del "cm:#{c}:id", (err, d) ->
                    console.log "error #{err}" && process.exit(10) if err?

              #move control messages
              console.log "moving control messages cm:#{c}"

              rc.zrange "cm:#{c}", 0,  -1, (err, messages) ->
                console.log "error #{err}" && process.exit(10) if err?
                #insert messages into cassandra
                for m in messages
                  do(m) ->
                    message = JSON.parse(m)

                    console.log "inserting message to cassandra #{m}"
                    cdb.insertMessageControlMessage c, message, (err, result) ->
                      console.log "error #{err}" && process.exit(10) if err?

                #                    console.log "inserted message to cassandra"
                console.log "deleting control messages cm:#{c}"
                rc.del "cm:#{c}", (err, result) ->
                  console.log "error #{err}" && process.exit(10) if err?
                return
        return
  return
