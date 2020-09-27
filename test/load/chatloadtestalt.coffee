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
rc.select 1

baseUri = "https://www.surespot.me:8080"
minclient = 600
maxclient = 1199
clientnum = maxclient - minclient + 1

http.globalAgent.maxSockets = 20000
jars = []
sigs = []
cookies = []
clients = []

login = (username, password, jar, authSig, done, callback) ->
  request.post
    agent: false
    url: baseUri + "/login"
    jar: jar
    json:
      username: username
      password: password
      authSig: authSig
    (err, res, body) ->
      if err
        done err
      else
        if res.statusCode != 204
          console.log username
        res.statusCode.should.equal 204
        cookie = jar.get({ url: baseUri }).map((c) -> c.name + "=" + c.value).join("; ")
        callback res, body, cookie


loginUsers = (i, callback) ->
  j = request.jar()
  jars[i-minclient] = j
  #console.log 'i: ' + i
  login 'test' + i, 'test' + i, j, sigs[i-minclient], callback, (res, body, cookie) ->
    cookies[i-minclient] = cookie
    j = request.jar()
    jars[i-minclient + 1] = j
    login 'test' + (i + 1), 'test' + (i+1), j, sigs[i-minclient+1], callback, (res, body, cookie) ->
      cookies[i-minclient+1] = cookie
      request.post
        agent: false
        #maxSockets: 6000
        jar: jars[i-minclient]
        url: baseUri + "/invite/test#{(i + 1)}"
        (err, res, body) ->
          if err
            callback err
          else
            if res.statusCode != 204
              console.log "invite failed statusCode#{res.statusCode}, i: " + i
            res.statusCode.should.equal 204
            request.post
              agent: false
              #maxSockets: 6000
              jar: jars[i-minclient + 1]
              url: baseUri + "/invites/test#{i}/accept"
              (err, res, body) ->
                if err
                  callback err
                else
                  if res.statusCode != 204
                    console.log "invite accept failed statusCode#{res.statusCode}, i: " + (i + 1)
                  res.statusCode.should.equal 204
                  callback null

makeLogin = (i) ->
  return (callback) ->
    loginUsers i, callback

friendUser = (i, callback) ->
  request.post
    agent: false
    #maxSockets: 6000
    jar: jars[i-minclient]
    url: baseUri + "/invite/test#{(i + 1)}"
    (err, res, body) ->
      if err
        callback err
      else
        if res.statusCode != 204
          console.log "invite failed statusCode#{res.statusCode}, i: " + i
        res.statusCode.should.equal 204
        request.post
          agent: false
          #maxSockets: 6000
          jar: jars[i-minclient + 1]
          url: baseUri + "/invites/test#{i}/accept"
          (err, res, body) ->
            if err
              callback err
            else
              if res.statusCode != 204
                console.log "invite accept failed statusCode#{res.statusCode}, i: " + (i + 1)
              res.statusCode.should.equal 204
              callback null

makeFriendUser = (i) ->
  return (callback) ->
    friendUser i, callback


makeConnect = (i) ->
  return (callback) ->
    connectChats i, callback


connectChats = (i, callback) ->
  clients[i-minclient] = io.connect baseUri, { 'force new connection': true, 'reconnect': false, 'connect timeout':   120000}, cookies[i-minclient]
  clients[i-minclient].on 'connect', ->
    clients[i-minclient+1] = io.connect baseUri, { 'force new connection': true, 'reconnect': false, 'connect timeout':   120000}, cookies[i-minclient+1]
    clients[i-minclient+1].on 'connect', ->
      clients[i-minclient+1].once "message", (message) ->
        receivedMessage = JSON.parse message
        callback null, receivedMessage.data is 'message data'
      jsonMessage = {to: "test" + (i + 1), from: "test#{i}", iv: i, data: "message data", mimeType: "text/plain"}
      clients[i-minclient].send JSON.stringify(jsonMessage)

describe "surespot chat test", () ->
  it "load sigs", (done) ->
    for i in [minclient..maxclient]
      #priv = fs.readFileSync "testkeys/test#{i}_priv.pem", 'utf-8'
      #pub = fs.readFileSync "testkeys/test#{i}_pub.pem", 'utf-8'
      sig = fs.readFileSync "testkeys/test#{i}.sig", 'utf-8'
      sigs[i-minclient] = sig
    done()

  it "login and friend #{clientnum} users", (done) ->
    tasks = []

    #create connect clientnum tasks
    for i in [minclient..maxclient] by 2
      tasks.push makeLogin i

    #execute the tasks which creates the cookie jars
    async.parallel tasks, (err, callback) ->
      if err?
        done err
      else
        done()

  it "connect #{clientnum} and send a message", (done) ->
    connects = []
    for i in [minclient..maxclient] by 2
      connects.push makeConnect(i)
    async.parallel connects, (err, callback) ->
      if err?
        done err
      else
        #sockets = clientnum
        done()
