http = require('http')
express = require("express")

oneYear = 31557600000

app = express()
app.configure ->
  app.use express.compress()
  app.use express.logger()
  app.use express["static"](__dirname + "/assets", { maxAge: oneYear})

  app.use (err, req, res, next) ->
    console.log 'error', "middlewareError #{err}"
    res.send err.status or 500

server = http.createServer app
server.listen(8000)


