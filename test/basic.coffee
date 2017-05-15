assert = require 'assert'

R = require '..'
#express = require 'express'
#expressWs = require 'express-ws'
EventEmitter = require 'events'

#global.WebSocket = require 'ws'
lodash = require 'lodash'

class MockSocket
	constructor: (@other=null, @latency=10) ->
		Object.defineProperty @, "readyState",
			get: =>
				if @other
					return 1
				else
					return 0
		@onmessage = ->
			console.error "No message handler in mock socket!"
	
	send: (data) ->
		@other.onmessage data: data
		#setTimeout (=> @other.onmessage(data: data)), @latency
		return


getRemote_ = (api, opts={}, copts={}) ->
	path = opts.path ? '/'
	port = opts.port ? 21000
	app = express()
	expressWs app
	app.ws path, (socket) ->
		R socket, expose: api, name: opts.name
	
	listener = await new Promise (a) ->
		l = app.listen port, -> a l
	
	listener: listener
	remote: (await (R "ws://localhost:#{port}#{path}", copts)).root

getRemote = (api, opts={}, copts={}) ->
	server_socket = new MockSocket()
	client_socket = new MockSocket server_socket
	server_socket.other = client_socket
	
	R server_socket, expose: api, name: opts.name
	client = await (R client_socket, copts)

	listener: close: ->
	remote: client.root

class ACustomError extends Error

describe 'Supports', ->
	local =
		echo: (value) -> "Echo: #{value}"
		member: "I'm a member!"
		getMember: ->
			return @member
		callback: (cb) ->
			cb 'Data from server!'
		lateCallback: (cb) ->
			setTimeout (-> cb 'Late data from server!'), 10
			return
		loopback: (cb) ->
			await(cb('Data from server!')) + "Stuff"
		higherOrder: (cb) ->
			return (arg) -> "Arg: #{arg}. Closured callback: #{cb()}"
		returnError: ->
			return Error("Foo")
		throwsString: ->
			throw "Shouldn't do this!"

		throws: ->
			throw new ACustomError('just an error')

		lodash: lodash
		isProxy: (f) ->
			console.log "Stuff", f
			R.isProxy f
		getReturn: (f) -> f()

	nested = ->
	nested.once = (f) ->
		called = false
		console.log f
		(args...) ->
			if called
				return false
			called = true
			return f(args...)
	nested.callback = (cb) ->
		cb "Data from server!"
	nested.value = 'just stuff'
	
	local.nested = nested
		
	local.event = new EventEmitter()

	S = (f) ->
		serve(local) (root) ->
			f.apply(root)


	beforeEach ->
		{@listener, @remote} =  await getRemote(local, {name: 'server'}, {name: 'client'})
		@local = local

	afterEach ->
		@listener.close()
	
	it 'Logging without recursion loop', ->
		console.log @remote

	cmp = (msg, f) -> it msg, ->
		localResult = await f.apply(@local)
		remoteResult = await R.resolve f.apply(@remote)
		assert.deepEqual remoteResult, localResult, msg
	cmp "Simple access", -> @member
	cmp "Simple call", -> @echo "From client!"
	cmp "Bound call", -> @getMember()
	#cmp "Higher order", -> @higherOrder(-> "from client callback")("client arg")
	
	#cmp "Error", -> @returnError()
	it "Callback", ->
		remote_promise = new Promise (accept) =>
			R.resolve @remote.callback (v) ->
				accept(v)
			return
		
		local_promise = new Promise (accept) =>
			@local.callback (v) ->
				accept(v)
			return
		remote_result = await remote_promise
		local_result = await local_promise
		assert.equal remote_result, local_result
	
	###
	it "Late callback", ->
		remote_promise = new Promise (accept) =>
			R.resolve @remote.lateCallback (v) ->
				accept(v)
			return
		
		local_promise = new Promise (accept) =>
			@local.lateCallback (v) ->
				accept(v)
			return
		assert.equal (await remote_promise), (await local_promise)
	###
	
	it "Events", ->
		remote_promise = new Promise (accept) =>
			handler = (event) ->
				assert.equal event, 'remote event'
				accept(event)
			handler = @remote.lodash.throttle handler, 10
			await R.resolve @remote.event.on "event", handler
			return
		
		local_promise = new Promise (accept) =>
			handler = (event) ->
				assert.equal event, 'remote event'
				accept(event)
			handler = @local.lodash.throttle handler, 10
			await R.resolve @local.event.on "event", handler
			return
		await new Promise (a) -> setTimeout a, 100
		@local.event.emit 'event', 'remote event'
		assert.equal (await remote_promise), 'remote event'
		assert.equal (await local_promise), 'remote event'
	it 'Exceptions', ->
		exception = null
		try
			await R.resolve @remote.throws()
		catch exception
		assert exception instanceof Error
		
		exception = null
		try
			await R.resolve @remote.throwsString()
		catch exception
		assert.equal exception, "Shouldn't do this!"
	it "Lodash", ->
		localResult = await @local.callback @local.lodash.throttle (arg) -> arg
		result = await R.resolve @remote.callback @remote.lodash.throttle (arg) -> arg
		assert.equal result, localResult
	it "Raw functions", ->
		cb = -> 'from callback'

		assert await R.resolve @remote.isProxy cb
		assert.equal cb(), await R.resolve @remote.getReturn cb
		
		assert not await R.resolve @remote.isProxy R.purejs cb
		assert.equal cb(), await R.resolve @remote.getReturn R.purejs cb

