redis = require("redis")
helenus = require 'helenus'

rc = redis.createClient()
pool = new helenus.ConnectionPool({host:'127.0.0.1', port:9160, keyspace:'surespot'})

minclient = 3000
maxclient = 9999


clean1up = (max ,i, done) ->
  console.log "cleaning up test#{i}"
  keys = []
  keys.push "f:test#{i}"
  keys.push "is:test#{i}"
  keys.push "ir:test#{i}"
  keys.push "c:test#{i}"

  #rc.del keys1, (err, blah) ->
  # return done err if err?
  multi=rc.multi()
  multi.del keys
  multi.hdel "mcounters", "test#{i}:test#{i+1}"
  multi.hdel "ucmcounters", "test#{i}"
  multi.exec (err, blah) ->
    return done err if err?
    cql = "begin batch
    delete from chatmessages where username = ?
    delete from chatmessages where username = ?
    delete from usercontrolmessages where username = ?
    delete from usercontrolmessages where username = ?
    apply batch"

    pool.cql cql, ["test#{i}", "test#{i+1}", "test#{i}", "test#{i+1}"], (err, results) ->
      if err
        console.log "Error executing cql #{err}" if err?
        done err
      else
        if i+1 < max
          clean1up max, i+1, done
        else
          done()


pool.connect (err,keyspace) ->
  console.log "Error connecting to cassandra #{err}" if err?
  return done err if err?

  clean1up maxclient, minclient, ->
    process.exit(0)

