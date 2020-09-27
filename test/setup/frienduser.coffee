redis = require("redis")
rc = redis.createClient()

friendUser = "f"
userCount = 50


friends = []
for i in [0..userCount]
  friends.push "test#{i}"

rc.sadd "f:#{friendUser}", friends, (err, results) ->
  process.exit()

