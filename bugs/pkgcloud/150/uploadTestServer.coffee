http = require('http')
express = require("express")
formidable = require 'formidable'
pkgcloud = require 'pkgcloud'
stream = require 'readable-stream'
rc = require('redis').createClient()

rackspaceApiKey = ""
rackspaceImageContainer = "test"

rackspace = pkgcloud.storage.createClient {provider: 'rackspace', username: '', apiKey: rackspaceApiKey}

app = express()
app.configure ->
  app.use app.router
  app.use (err, req, res, next) ->
    console.log 'error', "middlewareError #{err}"
    res.send err.status or 500

server = http.createServer app
server.listen(8000)

app.post "/images", (req, res, next) ->
  form = new formidable.IncomingForm()
  form.onPart = (part) ->
    return form.handlePart part unless part.filename?
    path = "testImage.png"
    #rc.incr 'something', (err, incr) ->
    console.log "received part: #{part.filename}, uploading to rackspace at: #{path}"
    part.pipe rackspace.upload {container: rackspaceImageContainer, remote: path}, (err) ->
      #todo send messageerror on socket
      return console.log err if err?
      console.log 'uploaded completed'
      res.send 204

    console.log 'stream piped'

  form.on 'error', (err) ->
    next new Error err

  form.on 'end', ->
    console.log 'form end'

  form.parse req


