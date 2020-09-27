redis = require("redis")
rc = redis.createClient()

#rc.auth "x3frgFyLaDH0oPVTMvDJHLUKBz8V+040"
minclient = 0
clients = 50

multi = rc.multi()

clean1up = (max ,i, done) ->
  keys = []
  multi.srem "u", "test#{i}"
  keys.push "f:test#{i}"
  keys.push "is:test#{i}"
  keys.push "ir:test#{i}"
  keys.push "m:test#{i}:test#{i + 1}:id"
  keys.push "m:test#{i}:test#{i + 1}"
  keys.push "c:test#{i}"
  #rc.del keys1, (err, blah) ->
  # return done err if err?
  rc.del keys, (err, blah) ->
    return done err if err?
    if i+1 < max
      clean1up max, i+1, done
    else
      multi.exec (err, results) ->
        return done err if err?
        done()


clean1up clients, 0, ->
  process.exit(0)

