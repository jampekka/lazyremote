
global.WebSocket = require 'ws'
#global.WebSocket = ->
#	ws = require 'ws'
#
#	for event in ['open', 'close', 'message', 'error']
#		do (event) ->
#			ws["on#{event}"] = addEventListener: (f) -> @on event, f
#	return ws

R = require '..'
_ = require 'lodash'
Koa = require 'koa'
KoaMount = require 'koa-mount'
Expose = require 'lazyremote-koa'

PORT = 12342
api =
	echo: (value) -> "Echo: #{value}"
	callback: (cb) ->
		#console.log "Callback", cb[R.Internals]
		return await(cb('Data from server!')) + "Stuff"


#app = new Koa()
#app.use(KoaMount '/', Expose api)
app = Expose api
server = app.listen PORT, ->
	remote = await R "ws://localhost:#{PORT}/"
	#await remote.callback (v) ->
	#	console.log "From server! #{v}"
	#console.log String(await remote.echo('fooo!'))
	console.log await remote.callback (msg) ->
		console.log "From remote: " + msg
		return "WOW!"
	R.close remote
	@close()
