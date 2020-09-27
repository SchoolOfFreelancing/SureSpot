#system message tester


gcm = require("node-gcm")
rc = require("redis").createClient()

GCM_TTL = 604800
googleApiKey = process.env.SURESPOT_GOOGLE_API_KEY

sendSystemGCM = (to, gcm_id, title, message) ->
  if gcm_id?.length > 0
    console.log "sending gcm system message"
    gcmmessage = new gcm.Message()
    sender = new gcm.Sender("#{googleApiKey}")
    gcmmessage.addData("type", "system")
    gcmmessage.addData("message", message)
    gcmmessage.addData "tag", "system message test"
    gcmmessage.addData "title", title
    gcmmessage.delayWhileIdle = false
    gcmmessage.timeToLive = GCM_TTL

    regIds = [gcm_id]

    sender.send gcmmessage, regIds, 4, (err, result) ->
      console.log "sendGcm result: #{JSON.stringify(result)}"
      process.exit(0)


sendSystemGCM "lk1", "gcmid" ,"surespot system", "system message test"
sendSystemGCM "lk1", "gcmid" ,"surespot system", "system message test update"

