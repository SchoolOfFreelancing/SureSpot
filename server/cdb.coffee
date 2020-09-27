helenus = require 'helenus'
common = require './common'
bunyan = require 'bunyan'
async = require 'async'
pool = null

debugLevel = process.env.SURESPOT_DEBUG_LEVEL ? 'debug'

bunyanStreams = [{
  level: debugLevel
  stream: process.stdout
}]

logger = bunyan.createLogger({
  name: 'surespot'
  streams: bunyanStreams
});

poolIps = process.env.SURESPOT_CASSANDRA_IPS ? '127.0.0.1'
poolIps = poolIps.split ":"

exports.connect = (callback) ->
  pool = new helenus.ConnectionPool(
    hosts: poolIps
    keyspace: 'surespot'
    consistencyLevel: helenus.ConsistencyLevel.QUORUM
    hostPoolSize : 5
  );

  pool.on 'error', (err) ->
    logger.error "cassandra connection pool error:#{err}"

  pool.connect (err, keyspace) ->
    if (err)
      callback err


exports.insertMessage = (message, callback) ->
  logger.debug "cdb.insertMessage"
  spot = common.getSpotName(message.from, message.to)

  params1 = [
    message.to,
    spot,
    message.id,
    message.datetime,
    message.from,
    message.fromVersion,
    message.to,
    message.toVersion,
    message.iv,
    message.data,
    message.mimeType]

  params2 = [
    message.from,
    spot,
    message.id,
    message.datetime,
    message.from,
    message.fromVersion,
    message.to,
    message.toVersion,
    message.iv,
    message.data,
    message.mimeType]


  insert = " INSERT INTO chatmessages (username, spotname, id, datetime, fromuser, fromversion, touser, toversion, iv, data, mimeType"
  values = " VALUES (?, ?, ?, ?, ?,?,?,?,?,?,?"
  if message.dataSize?
    insert += ", datasize) "
    values += ", ?) "
    params1.push message.dataSize
    params2.push message.dataSize

  else
    insert += ") "
    values += ") "

  params = params1.concat(params2)
  cql = "BEGIN BATCH" + insert + values + insert + values + "APPLY BATCH"

  pool.cql cql, params, callback


exports.remapMessages = (results, reverse, asArrayOfJsonStrings) ->
  messages = []
  #map to array of json messages
  results.forEach (row) ->
    message = {}
    row.forEach (name, value, ts, ttl) ->
      switch name
        when 'username','spotname'
          return
        when 'touser'
          message['to'] = value
        when 'fromuser'
          message['from'] = value
        when 'datetime'
          if value?
            message[name] = value.getTime()
        when 'mimetype'
          message['mimeType'] = value
        when 'toversion'
          message['toVersion'] = value
        when 'fromversion'
          message['fromVersion'] = value
        when 'datasize'
          if value?
            message['dataSize'] = value
        else
          if value? then message[name] = value else return

    #insert at begining to reverse order
    #todo change client to handle json object
    if reverse
      messages.unshift if asArrayOfJsonStrings then JSON.stringify(message) else message
    else
      messages.push if asArrayOfJsonStrings then JSON.stringify(message) else message

  return messages


exports.getAllMessages = (username, spot, callback) ->
  #get all messages for a user in a spot
  cql = "select * from chatmessages where username=? and spotname=?;"
  pool.cql cql, [username, spot], (err, results) =>
    if err
      logger.error "error getting all messages for #{username}, spot: #{spot}"
      return callback err
    return callback null, @remapMessages results, false, false

exports.getMessages = (username, spot, count, asArrayOfJsonStrings, callback) ->
  cql = "select * from chatmessages where username=? and spotname=? order by spotname desc limit #{count};"
  pool.cql cql, [username, spot], (err, results) =>
    if err
      logger.error "error getting messages for #{username}, spot: #{spot}, count: #{count}"
      return callback err
    return callback null, @remapMessages results, true, asArrayOfJsonStrings


exports.getMessagesBeforeId = (username, spot, id, asArrayOfJsonStrings, callback) ->
  logger.debug "getMessagesBeforeId, username: #{username}, spot: #{spot}, id: #{id}"
  cql = "select * from chatmessages where username=? and spotname=? and id<? order by spotname desc limit 60;"
  pool.cql cql, [username, spot, id], (err, results) =>
    if err
      logger.error "error getting messages before id for #{username}, spot: #{spot}, id: #{id}"
      return callback err
    return callback null, @remapMessages results, true, asArrayOfJsonStrings


exports.getMessagesAfterId = (username, spot, id, asArrayOfJsonStrings, callback) ->
  logger.debug "getMessagesAfterId, username: #{username}, spot: #{spot}, id: #{id}"
  if id is -1
    callback null, null
  else
    if id is 0
      this.getMessages username, spot, 30, asArrayOfJsonStrings, callback
    else
      cql = "select * from chatmessages where username=? and spotname=? and id > ? order by spotname desc;"
      pool.cql cql, [username, spot, id], (err, results) =>
        if err
          logger.error "error getting messages after id for #{username}, spot: #{spot}, id: #{id}"
          return callback err
        messages = @remapMessages results, true, asArrayOfJsonStrings
        return callback null, messages





exports.deleteMessage = (deletingUser, fromUser, spot, id) ->
  logger.debug "cdb.deleteMessage, deletingUser: #{deletingUser}, fromUser: #{fromUser} spot: #{spot}, id:#{id}"
  users = spot.split ":"

  #if the deleting user is the user that sent the message delete it in both places
  if deletingUser is fromUser

    cql = "begin batch
           delete from chatmessages where username=? and spotname=? and id = ?
           delete from chatmessages where username=? and spotname=? and id = ?
           apply batch"

    pool.cql cql, [users[0], spot, id, users[1], spot, id], (err, results) =>
      logger.error err if err?
      logger.debug "deleted message, deletingUser: #{deletingUser}, fromUser: #{fromUser} spot: #{spot}, id:#{id}"
  else
    #deleting user was the recipient, just delete it from their messages
    cql = "delete from chatmessages where username=? and spotname=? and id = ?;"
    pool.cql cql, [deletingUser, spot, id], (err, results) =>
      logger.error err if err?
      logger.debug "deleted message, deletingUser: #{deletingUser}, fromUser: #{fromUser} spot: #{spot}, id:#{id}"


exports.deleteMessages = (username, spot, messageIds, callback) ->
  #logger.debug "deleteAllMessages messageIds: #{JSON.stringify(messageIds)}"
  otherUser = common.getOtherSpotUser spot, username

  params = [username, spot]

  #delete all messages for username in spot
  cql = "begin batch
         delete from chatmessages where username=? and spotname=? "

  #delete all username's messages for the other user where ids match
  # add delete statements for my messages in their chat table because we can't use in with ids, or equal with fromuser which can't be in the primary key because it fucks up the other queries
  #https://issues.apache.org/jira/browse/CASSANDRA-6173
  #cheesy as fuck but it'll do for now until we can delete by secondary columns or use < >, or even IN with primary key columns

  for id in messageIds
    cql += "delete from chatmessages where username=? and spotname=? and id = ? "
    params = params.concat([otherUser, spot, id])

  cql += "apply batch"

  #logger.debug "sending cql: #{cql}"
  #logger.debug "params: #{JSON.stringify(params)}"
  pool.cql cql, params, callback


exports.deleteAllMessages = (spot, callback) ->
  logger.debug "deleteAllControlMessages #{spot}"
  users = spot.split ":"

  cql = "begin batch
         delete from chatmessages where username=? and spotname=?
         delete from chatmessages where username=? and spotname=?
         apply batch"

  pool.cql cql, [users[0], spot, users[1], spot], callback



exports.remapMessage = (row) ->
  #map to array of json messages
  message = {}
  row.forEach (name, value, ts, ttl) ->
    switch name
      when 'username','spotname'
        return
      when 'touser'
        message['to'] = value
      when 'fromuser'
        message['from'] = value
      when 'datetime'
        if value?
          message[name] = value.getTime()
      when 'mimetype'
        message['mimeType'] = value
      when 'toversion'
        message['toVersion'] = value
      when 'fromversion'
        message['fromVersion'] = value
      when 'datasize'
        if value?
          message['dataSize'] = value
      else
        if value? then message[name] = value else return

  return message


exports.getMessage = (username, room, id, callback) ->
  cql = "select * from chatmessages where username=? and spotname=? and id = ?;"
  pool.cql cql, [username, room, id], (err, results) =>
    if err
      logger.error "error getting message for #{username}, spot: #{room}, id: #{id}"
      return callback err
    if results.length < 1
      return callback null, null
    if results.length > 1
      return callback new Error 'getMessages unexpected results.length > 1'
    return callback null, @remapMessage results[0]


exports.updateMessageShareable = (room, id, bShareable, callback) ->
  users = room.split ":"
  cql = "begin batch
         update chatmessages set shareable = ? where username=? and spotname=? and id = ?
         update chatmessages set shareable = ? where username=? and spotname=? and id = ?
         apply batch"

  pool.cql cql, [bShareable, users[0], room, id, bShareable, users[1], room, id], (err, results) =>
    return callback err if err?
    callback()


#message control message stuff

exports.remapControlMessages = (results, reverse, asArrayOfJsonStrings) ->
  messages = []
  #map to array of json messages
  results.forEach (row) ->
    message = {}
    row.forEach (name, value, ts, ttl) ->
      switch name
        when 'username','spotname'
          return
        when 'fromuser'
          message['from'] = value
        else
          if value? then message[name] = value else return

    #insert at begining to reverse order
    if reverse
      messages.unshift if asArrayOfJsonStrings then JSON.stringify(message) else message
    else
      messages.push if asArrayOfJsonStrings then JSON.stringify(message) else message

  return messages

exports.getControlMessages = (username, room, count, asArrayOfJsonStrings, callback) ->
  cql = "select * from messagecontrolmessages where username=? and spotname=? order by spotname desc limit #{count};"
  pool.cql cql, [username, room], (err, results) =>
    if err
      logger.error "error getting message control messages for #{username}, room: #{room}, count: #{count}"
      return callback err
    return callback null, @remapControlMessages results, true, asArrayOfJsonStrings


exports.getControlMessagesAfterId = (username, spot, id, asArrayOfJsonStrings, callback) ->
  logger.debug "getControlMessagesAfterId, username: #{username}, spot: #{spot}, id: #{id}"
  if id is -1
    callback null, null
  else
    if id is 0
      this.getControlMessages username, spot, 60, asArrayOfJsonStrings, callback
    else
      cql = "select * from messagecontrolmessages where username=? and spotname=? and id > ? order by spotname desc;"
      pool.cql cql, [username, spot, id], (err, results) =>
        if err
          logger.error "error getting message control messages for #{username}, spot: #{spot}, id: #{id}"
          return callback err
        messages = @remapControlMessages results, true, asArrayOfJsonStrings
        return callback null, messages

exports.insertMessageControlMessage = (spot, message, callback) ->
  #denormalize using username as partition key so all retrieval for a user
  #occurs on the same node as we are going to be pulling multiple
  users = spot.split ":"
  cql =
    "BEGIN BATCH
          INSERT INTO messagecontrolmessages (username, spotname, id, type, action, data, moredata, fromuser)
          VALUES (?,?,?,?,?,?,?,?)
          INSERT INTO messagecontrolmessages (username, spotname, id, type, action, data, moredata, fromuser)
          VALUES (?,?,?,?,?,?,?,?)
          APPLY BATCH"

  #logger.debug "sending cql #{cql}"

  pool.cql cql, [
    users[0],
    spot,
    message.id,
    message.type,
    message.action,
    message.data,
    message.moredata,
    message.from,
    users[1],
    spot,
    message.id,
    message.type,
    message.action,
    message.data,
    message.moredata,
    message.from
  ], callback



exports.deleteControlMessages = (spot, messageIds, callback) ->
  #logger.debug "deleteAllMessages messageIds: #{JSON.stringify(messageIds)}"
  users = spot.split ":"

  #delete control messages for username in spot by id
  cql = "begin batch "
  params = [];

  #delete all username'scontrol messages for the user where ids match
  # add delete statements for my messages in their chat table because we can't use in with ids, or equal with fromuser which can't be in the primary key because it fucks up the other queries
  #https://issues.apache.org/jira/browse/CASSANDRA-6173
  #cheesy as fuck but it'll do for now until we can delete by secondary columns or use < >, or even IN with primary key columns
  for id in messageIds
    cql += "delete from messagecontrolmessages where username=? and spotname=? and id = ? "
    params = params.concat([users[0], spot, id])
    cql += "delete from messagecontrolmessages where username=? and spotname=? and id = ? "
    params = params.concat([users[1], spot, id])

  cql += "apply batch"

  #logger.debug "sending cql: #{cql}"
  #logger.debug "params: #{JSON.stringify(params)}"
  pool.cql cql, params, callback

exports.deleteAllControlMessages = (spot, callback) ->
  logger.debug "deleteAllControlMessages #{spot}"
  users = spot.split ":"
  cql = "begin batch
         delete from messagecontrolmessages where username=? and spotname=?
         delete from messagecontrolmessages where username=? and spotname=?
         apply batch"

  pool.cql cql, [users[0], spot, users[1], spot], callback

#user control message stuff

exports.insertUserControlMessage = (username, message, callback) ->
  #denormalize using username as partition key so all retrieval for a user
  #occurs on the same node as we are going to be pulling multiple

  params = [
    username,
    message.id,
    message.type,
    message.action,
    message.data
  ]



  insert = "INSERT INTO usercontrolmessages (username, id, type, action, data"
  values = "VALUES (?,?,?,?,?"
  if message.moredata?
    insert += ", moredata) "
    values += ", ?);"
    #store moredata object as json string in case of friend image data
    if message.action is 'friendImage' or message.action is 'friendAlias' and message.moredata?
      message.moredata = JSON.stringify(message.moredata)

    params.push message.moredata

  else
    insert += ") "
    values += ");"

  cql = insert + values;

  #logger.debug "sending cql #{cql}"

  pool.cql cql, params, callback

exports.remapUserControlMessages = (results, reverse, asArrayOfJsonStrings) ->
  messages = []
  #map to array of json messages
  results.forEach (row) ->
    message = {}
    row.forEach (name, value, ts, ttl) ->
      switch name
        when 'username'
          return
        else
          if value? then message[name] = value else return


    #parse json if it's friendImage
    if (message.action is 'friendImage' or message.action is 'friendAlias') and message.moredata?
      message.moredata = JSON.parse(message.moredata)

    #insert at begining to reverse order
    if reverse
      messages.unshift if asArrayOfJsonStrings then JSON.stringify(message) else message
    else
      messages.push if asArrayOfJsonStrings then JSON.stringify(message) else message

  return messages

exports.getUserControlMessages = (username, count, asArrayOfJsonStrings, callback) ->
  cql = "select * from usercontrolmessages where username=? order by id desc limit #{count};"
  pool.cql cql, [username], (err, results) =>
    if err
      logger.error "error getting user control messages for #{username}, count: #{count}"
      return callback err
    return callback null, @remapUserControlMessages results, true, asArrayOfJsonStrings

exports.getUserControlMessagesAfterId = (username, id, asArrayOfJsonStrings, callback) ->
  logger.debug "getUserControlMessagesAfterId, username: #{username}, id: #{id}"
  if id is -1
    callback null, null
  else
    if id is 0
      this.getUserControlMessages username, 20, asArrayOfJsonStrings, callback
    else
      cql = "select * from usercontrolmessages where username=? and id > ? order by id desc;"
      pool.cql cql, [username, id], (err, results) =>
        if err
          logger.error "error getting user control messages for #{username}, id: #{id}"
          return callback err
        messages = @remapUserControlMessages results, true, asArrayOfJsonStrings
        return callback null, messages


exports.deleteUserControlMessages = (username, messageIds, callback) ->
  #logger.debug "deleteAllMessages messageIds: #{JSON.stringify(messageIds)}"

  #delete user control messages for username by id
  cql = "begin batch "
  params = [];

  #delete all username'scontrol messages for the user where ids match
  # add delete statements for my messages in their chat table because we can't use in with ids, or equal with fromuser which can't be in the primary key because it fucks up the other queries
  #https://issues.apache.org/jira/browse/CASSANDRA-6173
  #cheesy as fuck but it'll do for now until we can delete by secondary columns or use < >, or even IN with primary key columns
  for id in messageIds
    cql += "delete from usercontrolmessages where username=? and id = ? "
    params = params.concat([username, id])

  cql += "apply batch"

  #logger.debug "sending cql: #{cql}"
  #logger.debug "params: #{JSON.stringify(params)}"
  pool.cql cql, params, callback

exports.deleteAllUserControlMessages = (username, callback) ->
  logger.debug "deleteAllUserControlMessages #{username}"
  cql = "delete from usercontrolmessages where username=?;"
  pool.cql cql, [username], callback

exports.deleteAll = (username, callback) ->
  logger.debug "deleteAll #{username}"
  cql = "begin batch
         delete from chatmessages where username = ?
         delete from messageControlmessages where username = ?
         delete from usercontrolmessages where username = ?
         delete from publickeys where username = ?
         delete from frienddata where username = ?
         apply batch"
  pool.cql cql, [username, username, username, username, username], callback



#public keys
exports.insertPublicKeys = (username, keys, callback) ->
  params = [
    username,
    keys.version,
    keys.dhPub,
    keys.dhPubSig,
    keys.dsaPub,
    keys.dsaPubSig
  ]

  insert = "INSERT INTO publickeys (username, version, dhPub, dhPubSig, dsaPub, dsaPubSig"
  values = "VALUES (?,?,?,?,?,?"

  if keys.clientSig?

    insert += ",clientSig,serverSig) "
    values += ",?,?);"
    params.push keys.clientSig, keys.serverSig
  else

    insert += ") "
    values += ");"

  cql = insert + values
  #logger.debug "sending cql #{cql}"

  pool.cql cql, params, (err, results) ->
    if err?
      logger.error "error inserting public keys for #{username}, version: #{keys.version}"
    callback(err,results)


exports.remapPublicKey= (results) ->
  keys = {}
  #map to array of json messages
  results.forEach (row) ->

    row.forEach (name, value, ts, ttl) ->
      switch name
        when 'dhpub'
          keys['dhPub'] = value
        when 'dhpubsig'
          keys['dhPubSig'] = value
        when 'dsapub'
          keys['dsaPub'] = value
        when 'dsapubsig'
          keys['dsaPubSig'] = value
        when 'version'
          keys['version'] = "#{value}"
        when 'serversig'
          if value? then keys['serverSig'] = value else return
        when 'clientsig'
          if value? then keys['clientSig'] = value else return
        when 'username'
          return
        else
          if value? then keys[name] = value else return

  return keys

exports.remapPublicKeys = (results) ->
  keys = []
  #map to array of json messages
  results.forEach (row) ->
    key = {}
    row.forEach (name, value, ts, ttl) ->
      switch name
        when 'dhpub'
          key['dhPub'] = value
        when 'dhpubsig'
          key['dhPubSig'] = value
        when 'dsapub'
          key['dsaPub'] = value
        when 'dsapubsig'
          key['dsaPubSig'] = value
        when 'version'
          key['version'] = "#{value}"
        when 'serversig'
          if value? then key['serverSig'] = value else return
        when 'clientsig'
          if value? then key['clientSig'] = value else return
        else
          return
    keys.push key

  return keys



exports.getPublicKeys = (username, version, callback) ->
  logger.debug "getPublicKeys username: #{username}, version: #{version}"
  cql = "select * from publickeys where username=? and version=?;"
  pool.cql cql, [username,version], (err, results) =>
    if err?
      logger.error "error getting public keys for #{username}, version: #{version}"
      return callback err
    return callback null, @remapPublicKey results

exports.getPublicKeysSince = (username, version, callback) ->
  logger.debug "getPublicKeySince username: #{username}, version: #{version}"
  cql = "select * from publickeys where username=? and version>=?;"
  pool.cql cql, [username,version], (err, results) =>
    if err?
      logger.error "error getting public keys for #{username} since version: #{version}"
      return callback err
    #logger.debug "cdb.getPublicKeysSince: #{JSON.stringify(results)}"
    return callback null, @remapPublicKeys results

exports.updatePublicKeySignatures = (username, clientsigs, serversigs, callback) ->
  cql = "update publickeys set clientsig = ?, serversig = ? where username = ? and version = ?;";
  #iterate through sigs and update

  async.each(
    Object.keys(clientsigs)
    (version, callback) ->
      clientsig = clientsigs[version]
      serversig = serversigs[version]

      pool.cql cql, [clientsig, serversig, username, parseInt(version,10)], (err, results) =>
        if err?
          logger.error "error updating public key signatures for #{username}, version: #{version}"
          return callback err
        callback()
    (err) ->
      return callback err if err?
      callback()
  )


exports.deletePublicKeys = (username, callback) ->
  logger.debug "deletePublicKeys #{username}"
  cql = "delete from publickeys where username=?;"
  pool.cql cql, [username], callback


#friend data
exports.insertFriendImageData = (username, friendname, url, version, iv, callback) ->
  if username? and friendname? and url? and version? and iv?
    cql =
      "INSERT INTO frienddata (username, friendname, imageUrl, imageVersion, imageIv)
                   VALUES (?,?,?,?,?);"

    #logger.debug "sending cql #{cql}"

    pool.cql cql, [
      username,
      friendname,
      url,
      version,
      iv
    ], (err, results) ->
      if err?
        logger.error "error inserting friend image data for username: #{username}, friendname: #{friendname}"
      callback(err,results)
  else
    callback()

exports.insertFriendAliasData = (username, friendname, data, version, iv, callback) ->

  if username? and friendname? and data? and version? and iv?
    cql =
      "INSERT INTO frienddata (username, friendname, aliasData, aliasVersion, aliasIv)
                   VALUES (?,?,?,?,?);"

    #logger.debug "sending cql #{cql}"

    pool.cql cql, [
      username,
      friendname,
      data,
      version,
      iv
    ], (err, results) ->
      if err?
        logger.error "error inserting friend alias data for username: #{username}, friendname: #{friendname}"
      callback(err,results)
  else
    callback()


exports.deleteFriendAliasData = (username, friendname, callback) ->

  if username? and friendname?
    cql =
      "DELETE aliasdata, aliasversion, aliasiv FROM frienddata WHERE username = ? AND friendname = ?;"

    #logger.debug "sending cql #{cql}"

    pool.cql cql, [
      username,
      friendname
    ], (err, results) ->
      if err?
        logger.error "error deleting friend alias data for username: #{username}, friendname: #{friendname}: #{err}"
      callback(err,results)
  else
    callback()


exports.deleteFriendImageData = (username, friendname, callback) ->

  if username? and friendname?
    cql =
      "DELETE imageurl, imageversion, imageiv FROM frienddata WHERE username = ? AND friendname = ?;"

    #logger.debug "sending cql #{cql}"

    pool.cql cql, [
      username,
      friendname
    ], (err, results) ->
      if err?
        logger.error "error deleting friend image data for username: #{username}, friendname: #{friendname}: #{err}"
      callback(err,results)
  else
    callback()



exports.remapFriendData = (row) ->
  friend = new common.Friend null, 0

  row.forEach (name, value, ts, ttl) ->
    switch name
      when 'friendname'
        friend['name'] = value
      when 'imageurl'
        if value?
          friend['imageUrl'] = value
      when 'imageversion'
        if value?
          friend['imageVersion'] = value
      when 'imageiv'
        if value?
          friend['imageIv'] = value
      when 'aliasdata'
        if value?
          friend['aliasData'] = value
      when 'aliasversion'
        if value?
          friend['aliasVersion'] = value
      when 'aliasiv'
        if value?
          friend['aliasIv'] = value

      else
        return

  return friend

exports.remapFriendDatas = (results) ->
  friendDatas = {}
  #map to array of json messages
  results.forEach (row) ->
    friend = new common.Friend null, 0
    row.forEach (name, value, ts, ttl) ->
      switch name
        when 'friendname'
          friend['name'] = value
        when 'imageurl'
          if value?
            friend['imageUrl'] = value
        when 'imageversion'
          if value?
            friend['imageVersion'] = value
        when 'imageiv'
          if value?
            friend['imageIv'] = value
        when 'aliasdata'
          if value?
            friend['aliasData'] = value
        when 'aliasversion'
          if value?
            friend['aliasVersion'] = value
        when 'aliasiv'
          if value?
            friend['aliasIv'] = value

        else
          return

    friendDatas[friend['name']] = friend

  return friendDatas



exports.getFriendData = (username, friendname, callback) ->
  logger.debug "getFriendData, username: #{username}, friendname: #{friendname}"
  cql = "select * from frienddata where username=? and friendname = ?;"
  pool.cql cql, [username, friendname], (err, results) =>
    if err
      logger.error "error getting frienddata for username: #{username}"
      return callback err
    if results.length < 1
      return callback null, null
    if results.length > 1
      return callback new Error 'getFriendData unexpected results.length > 1'
    return callback null, @remapFriendData results[0]


exports.getAllFriendData = (username, callback) ->
  logger.debug "getAllFriendData, username: #{username}"
  cql = "select * from frienddata where username=?;"
  pool.cql cql, [username], (err, results) =>
    if err
      logger.error "error getting all frienddata for username: #{username}"
      return callback err
    return callback null, @remapFriendDatas results

exports.deleteFriendData = (username, friendname, callback) ->
  logger.debug "deleteFriendData, username: #{username}, friendname: #{friendname}"
  cql = "delete from frienddata where username=? and friendname = ?;"
  pool.cql cql, [username, friendname], callback


#your mama
exports.insertYourmama = (ymis, time, callback) ->
  cql = "INSERT INTO yourmama (is, datetime) VALUES (?, ?);"
  pool.cql cql, [ymis, time], (err, results) ->
    if err?
      logger.error "error with yourmama: #{err}"
    callback(err,results)



#migration crap
exports.migrateInsertMessage = (message, callback) ->
  logger.debug "insertMessage id: #{message.id}"
  spot = common.getSpotName(message.from, message.to)

  cql =
    "BEGIN BATCH
      INSERT INTO chatmessages (username, spotname, id, datetime, fromuser, fromversion, touser, toversion, iv, data, mimeType, datasize, shareable)
      VALUES (?, ?, ?, ?, ?,?,?,?,?,?,?,?,? )
      INSERT INTO chatmessages (username, spotname, id, datetime, fromuser, fromversion, touser, toversion, iv, data, mimeType, datasize, shareable)
      VALUES (?, ?, ?, ?, ?,?,?,?,?,?,?,?,? )
      APPLY BATCH"



  pool.cql cql, [
    message.to,
    spot,
    message.id,
    message.datetime,
    message.from,
    message.fromVersion,
    message.to,
    message.toVersion,
    message.iv,
    message.data,
    message.mimeType,
    message.dataSize,
    message.shareable,

    message.from,
    spot,
    message.id,
    message.datetime,
    message.from,
    message.fromVersion,
    message.to,
    message.toVersion,
    message.iv,
    message.data,
    message.mimeType,
    message.dataSize,
    message.shareable,
  ], callback



exports.migrateDeleteMessages = (username, spot, messageIds, callback) ->
  params = []
  logger.debug "deleting #{username} #{spot}"

  #delete all username's messages for the other user where ids match
  # add delete statements for my messages in their chat table because we can't use in with ids, or equal with fromuser which can't be in the primary key because it fucks up the other queries
  #https://issues.apache.org/jira/browse/CASSANDRA-6173
  #cheesy as fuck but it'll do for now until we can delete by secondary columns or use < >, or even IN with primary key columns
  cql = "begin batch "

  for id in messageIds
    cql += "delete from chatmessages where username=? and spotname=? and id = ? "
    params = params.concat([username, spot, parseInt(id)])

  cql += "apply batch"

  #logger.debug "sending cql: #{cql}"
  #logger.debug "params: #{JSON.stringify(params)}"
  pool.cql cql, params, (err, results) ->
    logger.debug "err: #{err}" if err?
    logger.debug "results: #{results}"
    callback err, results

exports.migrateInsertPublicKeys = (username, keys, callback) ->
  cql =
    "INSERT INTO publickeys (username, version, dhPub, dhPubSig, dsaPub, dsaPubSig)
             VALUES (?,?,?,?,?,?);"

  #logger.debug "sending cql #{cql}"

  pool.cql cql, [
    username,
    parseInt(keys.version),
    keys.dhPub,
    keys.dhPubSig,
    keys.dsaPub,
    keys.dsaPubSig
  ], callback

exports.migrateInsertFriendImageData = (username, friendname, key, value, callback) ->

  cql =
    "INSERT INTO frienddata (username, friendname, #{key}) VALUES (?,?,?);"

  #logger.debug "sending cql #{cql}"

  pool.cql cql, [
    username,
    friendname,
    value
  ], (err, results) ->
    if err?
      logger.error "error inserting friend image data for username: #{username}, friendname: #{friendname}"
    callback(err,results)
