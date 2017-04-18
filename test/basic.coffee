assert = require 'assert'

R = require '..'
express = require 'express'
expressWs = require 'express-ws'
EventEmitter = require 'events'

"""
class EventEmitter
	constructor: ->
		@_listeners = {}
	
	on: (event, handler) ->
		@_listeners[event] ?= []
		@_listeners[event].push handler
	
	emit: (event, args...) ->
		listeners = @_listeners[event] ? []
		for listener in listeners
			listener(args...)
"""

global.WebSocket = require 'ws'

getRemote = (api, path='/', port=21000, copts={}) ->
	app = express()
	expressWs app
	app.ws path, (socket) ->
		R socket, expose: api
	
	listener = await new Promise (a) ->
		l = app.listen port, -> a l
	
	listener: listener
	remote: (await (R "ws://localhost:#{port}#{path}", copts)).root


describe 'Supports', ->
	local =
		echo: (value) -> "Echo: #{value}"
		member: "I'm a member!"
		getMember: ->
			return @member
		callback: (cb) ->
			cb.call @, 'Data from server!'
		lateCallback: (cb) ->
			setImmediate -> cb 'Late data from server!'
		loopback: (cb) ->
			await(cb('Data from server!')) + "Stuff"
		higherOrder: (cb) ->
			return (arg) -> "Arg: #{arg}. Closured callback: #{await cb()}"
		returnError: ->
			return Error("Foo")
	local.event = new EventEmitter()

	S = (f) ->
		serve(local) (root) ->
			f.apply(root)


	beforeEach ->
		{@listener, @remote} =  await getRemote(local)
		@local = local

	afterEach ->
		@listener.close()
	cmp = (msg, f) -> it msg, ->
		localResult = await f.apply(@local)
		remoteResult = await f.apply(@remote)
		assert.deepEqual remoteResult, localResult, msg
	
	cmp "Simple access", -> @member
	cmp "Simple call", -> @echo "From client!"
	cmp "Bound call", -> @getMember()
	cmp "Higher order", -> @higherOrder(-> "from client callback")("client arg")
	cmp "Error", -> @returnError()
	
	it "Callback", ->
		remote_promise = new Promise (accept) =>
			R.resolve @remote.callback (v) ->
				accept(v)
			return
		
		local_promise = new Promise (accept) =>
			@local.callback (v) ->
				accept(v)
			return
		assert.equal (await remote_promise), (await local_promise)
	
	it "Late callback", ->
		remote_promise = new Promise (accept) =>
			R.resolve @remote.lateCallback (v) ->
				accept(v)
			return
		
		local_promise = new Promise (accept) =>
			@local.lateCallback (v) ->
				accept(v)
			return
		assert.equal (await remote_promise), (await local_promise),
	
	it "Events", ->
		remote_promise = new Promise (accept) =>
			await (@remote.event.on 'event', (event) ->
				assert event == 'remote event'
				accept(event))
			return
		local_promise = new Promise (accept) =>
			@local.event.on 'event', (event) ->
				assert event == 'remote event'
				accept(event)
			return
		await new Promise (a) -> setTimeout a, 0
		@local.event.emit 'event', 'remote event'
		assert.equal (await remote_promise), 'remote event'
		assert.equal (await local_promise), 'remote event'
	

	
