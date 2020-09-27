exports.getSpotName = (from, to) ->
    if from < to then from + ":" + to else to + ":" + from


exports.getOtherSpotUser = (spot, user) ->
  users = spot.split ":"
  if user == users[0] then return users[1] else return users[0]

exports.Friend = (name, flags, imageUrl, imageVersion, imageIv, aliasData, aliasVersion, aliasIv) ->
  friend = {}
  friend.flags = flags

  if name?
    friend.name = name

  if imageUrl?
    friend.imageUrl = imageUrl

  if imageVersion?
    friend.imageVersion = imageVersion

  if imageIv?
    friend.imageIv = imageIv

  if aliasData?
    friend.aliasData = aliasData

  if aliasVersion?
    friend.aliasVersion = aliasVersion

  if aliasIv
    friend.aliasIv = aliasIv

  return friend

exports.combineMiddleware = (list) ->
  (req, res, next) ->
    (iter = (i) ->
      mid = list[i]
      return next() unless mid
      mid req, res, (err) ->
        return next(err) if err
        iter i + 1
    )(0)

