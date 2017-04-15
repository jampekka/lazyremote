
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
	member: "I'm a member!"
	getMember: ->
		return @member
	callback: (cb) ->
		await(cb('Data from server!')) + "Stuff"
	higherOrder: (cb) ->
		return (arg) -> "Arg: #{arg}. Closured callback: #{await cb()}"


#app = new Koa()
#app.use(KoaMount '/', Expose api)
app = Expose api
server = app.listen PORT, ->
	remote = (await R "ws://localhost:#{PORT}/").root
	console.log "Simple access:", await remote.member
	console.log "Simple call:", await remote.echo "From client"
	console.log "Bound call:", await remote.getMember()
	await remote.callback (msg) -> console.log "Callback: " + msg
	console.log "Higher order:", await remote.higherOrder(-> "from client callback")('client arg')
	
	R.close remote
	@close()
