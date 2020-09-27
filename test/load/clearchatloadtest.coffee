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
crypto = require 'crypto'



testkeydir = '../testkeys'
baseUri = "http://localhost:8080"
minclient = 0
maxclient = 199
clients = maxclient - minclient + 1
jars = []
http.globalAgent.maxSockets = 20000




clean = 0

clean1up = (max ,i, done) ->
  keys = []
  keys.push "f:test#{i}"
  keys.push "is:test#{i}"
  keys.push "ir:test#{i}"
  keys.push "m:test#{i}:test#{i + 1}:id"
  keys.push "m:test#{i}:test#{i + 1}"
  keys.push "c:test#{i}"
  keys.push "c:u:test#{i}"
  keys.push "c:u:test#{i}:id"
  #rc.del keys1, (err, blah) ->
  # return done err if err?
  rc.del keys, (err, blah) ->
    return done err if err?
    if i+1 < max
      clean1up max, i+1, done
    else
      done()


cleanup = (done) ->
  #clean1up clients, 0, done

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


loginUsers = (i, key, callback) ->
  j = request.jar()
  jars[i - minclient] = j
  #console.log 'i: ' + i
  login 'test' + i, 'test' + i, j, key, callback, (res, body, cookie) ->
    callback null, cookie

makeLogin = (i, key) ->
  return (callback) ->
    loginUsers i, key, callback

makeConnect = (cookie) ->
  return (callback) ->
    connectChats cookie, callback


connectChats = (cookie, callback) ->
  client = io.connect baseUri, { 'force new connection': true, 'reconnect': false, 'connect timeout':   1200000 }, cookie
  client.on 'connect', ->
    callback null, client

send = (socket, i, callback) ->
  if i % 2 is 0
    jsonMessage = {to: "test" + (i + 1), from: "test#{i}", iv: i, data: "message data", mimeType: "text/plain", toVersion: 1, fromVersion: 1}
    socket.send JSON.stringify(jsonMessage)
    callback null, true
  else
    socket.once "message", (message) ->
      receivedMessage = JSON.parse message
      callback null, receivedMessage.data is 'message data'


makeSend = (socket, i) ->
  return (callback) ->
    send socket, i, callback


friendUser = (i, callback) ->
  request.post
    agent: false
    #maxSockets: 6000
    jar: jars[i - minclient]
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
          jar: jars[(i - minclient + 1)]
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


describe "surespot chat test", () ->
  #before (done) -> cleanup done

  sigs = []
  tasks = []
  cookies = undefined
  sockets = undefined

  it "load sigs", (done) ->
    for i in [minclient..maxclient]
      #priv = fs.readFileSync "testkeys/test#{i}_priv.pem", 'utf-8'
      #pub = fs.readFileSync "testkeys/test#{i}_pub.pem", 'utf-8'
      sig = fs.readFileSync "#{testkeydir}/test#{i}.sig", 'utf-8'
      sigs[i-minclient] = sig
    done()

  it "login #{clients} users", (done) ->
    tasks = []

    #create connect clients tasks
    for i in [minclient..maxclient] by 1
      tasks.push makeLogin i, sigs[i - minclient]

    #execute the tasks which creates the cookie jars
    async.parallel tasks, (err, httpcookies) ->
      if err?
        done err
      else
        cookies = httpcookies
        done()


  it 'friend users', (done) ->
    tasks = []
    for i in [minclient..maxclient] by 2
      tasks.push makeFriendUser i
    async.parallel tasks, (err, callback) ->
      if err
        done err
      else
        done()

  it "connect #{clients} chats", (done) ->
    connects = []
    for cookie in cookies
      connects.push makeConnect(cookie)
    async.parallel connects, (err, clients) ->
      if err?
        done err
      else
        sockets = clients
        done()


  it "send and receive a message", (done) ->
    sends = []
    i = 0
    for socket in sockets
      sends.push makeSend(socket, minclient + i++)

    async.parallel sends,  (err, results) ->
      if err?
        done err
      else
        _.every results, (result) -> result.should.be.true
        done()

  after (done) -> cleanup done


