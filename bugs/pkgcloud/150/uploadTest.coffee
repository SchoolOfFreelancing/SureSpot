request = require 'request'
fs = require("fs")
baseUri = "http://localhost:8000"

r = request.post baseUri + "/images", (err, res, body) ->
  if err
    console.log err

form = r.form()
form.append "image", fs.createReadStream("testImage.png")