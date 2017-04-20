axios = require 'axios'
yaml = require 'js-yaml'
_ = require 'lodash'
urlParse = require 'url-parse'
require('promise-resolve-deep')(Promise)

class RequestOp
	constructor: (@seq, @opcodes) ->

class ResponseOp
	constructor: (@seq, @response, @isError) ->

class GetOp
	constructor: (@name) ->
	handle: (obj) ->
		result = @_handle obj
		return result
	_handle: (obj) ->
		if @name.length == 0
			return obj
		v = obj[@name]
		return v

class CallOp
	constructor: (args) ->
		@args = Array.from args
	handle: (func, context) ->
		args = await Promise.resolveDeep @args
		func.apply context, args

class RemoteError extends Error

Schema = (heap) ->
	types = []
	T = (t) -> types.push t
	T new yaml.Type '!lr-get',
		kind: 'scalar'
		resolve: -> true
		instanceOf: GetOp
		construct: (v) -> new GetOp v
		represent: (v) -> v.name
	
	T new yaml.Type '!lr-call',
		kind: 'mapping'
		resolve: -> true
		instanceOf: CallOp
		construct: (v) ->
			new CallOp v.args
		represent: (v) -> _.assign {}, v
	

	T new yaml.Type '!lr-proxy',
		kind: 'mapping'
		resolve: -> true
		predicate: (v) -> heap.isMyProxy v
		represent: (v) ->
			opcodes: LazyProxy.internals(v).opcodes
		construct: (v) ->
			heap.resolveOpcodes v.opcodes

	
	T new yaml.Type '!lr-request',
		kind: 'mapping'
		resolve: -> true
		instanceOf: RequestOp
		construct: (v) -> new RequestOp v.seq, v.opcodes
		represent: (v) -> _.assign {}, v
	
	T new yaml.Type '!lr-response',
		kind: 'mapping'
		resolve: -> true
		instanceOf: ResponseOp
		construct: (v) -> new ResponseOp v.seq, v.response, v.isError
		represent: (v) -> _.assign {}, v
	
	T new yaml.Type '!lr-function',
		kind: 'mapping'
		resolve: -> true
		predicate: (v) -> typeof(v) == 'function'
		construct: (v) ->
			proxy = heap.getProxyForAddress v.id
			return proxy
		represent: (v) ->
			id: heap.getHeapAddress v
			props: _.assign {}, v
	
	T new yaml.Type '!lr-arguments',
		kind: 'sequence'
		resolve: -> true
		predicate: (v) ->
			Object.prototype.toString.call(v) == '[object Arguments]'
		construct: (v) -> v
		represent: (v) -> Array.from v
	
	# TODO: Could be nicer
	T new yaml.Type '!lr-error',
		kind: 'mapping'
		resolve: -> true
		instanceOf: Error
		construct: (v) ->
			new RemoteError(v.message)
		represent: (v) ->
			message: v.message

	# TODO: Extra dangerous!!
	types.push yaml.DEFAULT_FULL_SCHEMA.explicit...
	return yaml.Schema.create yaml.DEFAULT_FULL_SCHEMA, types

Codec = (heap) ->
	schema = Schema heap

	encode: (obj) ->
		yaml.dump obj,
			schema: schema
			#skipInvalid: true
	decode: (obj) ->
		v = yaml.load(obj, schema: schema)
		v = Promise.resolveDeep v
		return v
		

depth = 0
_Resolve = (result, opcodes=[]) ->
	depth += 1
	prev_result = undefined
	for opcode in opcodes
		new_result = await opcode.handle(result, prev_result)
		prev_result = result
		result = new_result

	depth -= 1
	return result

Remote = (root, socket, name='') ->
	seq = 0
	pending = new Map()
	root =
		root: root
		heap: {}
	handleRequest = (msg) ->
		return false unless msg instanceof RequestOp
		try
			result = await self.resolveOpcodes(msg.opcodes)
			socket.send encode new ResponseOp msg.seq, result, false
		catch error
			socket.send encode new ResponseOp msg.seq, error, true
		return true
	
	handleResponse = (msg) ->
		return false unless msg instanceof ResponseOp
		unless pending.has msg.seq
			console.error "Response to non-pending call seq #{msg.seq}"
			return true
		p = pending.get msg.seq
		pending.delete msg.seq
		if msg.isError
			p.reject msg.response
		else
			p.accept msg.response
		return true

	socket.onmessage = (event) ->
		handled = 0
		msg = await decode event.data
		handled += await handleRequest msg
		handled += await handleResponse msg
		if not handled
			console.error "Unknown request", msg
	
	self = (opcodes) -> new Promise (accept, reject) ->
		seq += 1
		pending.set seq,
			accept: accept
			reject: reject
		socket.send encode new RequestOp seq, opcodes
	
	
	heapSeq = 0
	heapAddresses = new Map()
	self.getHeapAddress = (v) ->
		if heapAddresses.has v
			return heapAddresses.get v

		heapSeq += 1
		root.heap[heapSeq] = v
		heapAddresses.set v, String heapSeq
		return String heapSeq
	
	self.getProxyForAddress = (id) ->
		opts = remote: self
		proxy = LazyProxy_ opts, [(new GetOp 'heap'), (new GetOp id)], true
		return proxy
	
	self.resolveOpcodes = (opcodes) ->
		result = await _Resolve root, opcodes
		return result

	self.isMyProxy = (obj) ->
		return false unless LazyProxy.isProxy obj
		return LazyProxy.internals(obj).opts.remote == self
	
	self.remote_name = name
	{encode, decode} = Codec self
	self.close = -> socket.close()
	return self


ensureSocket = (socket) ->
	if typeof(socket) == 'string'
		url = urlParse socket
		if url.protocol == 'http:'
			url.set 'protocol', 'ws:'
		if url.protocol == 'https:'
			url.set 'protocol', 'wss:'
		socket = new WebSocket url.href
	if socket.readyState == 1
		return Promise.resolve socket
	if socket.readyState == 0
		return new Promise (accept, reject) ->
			socket.onopen = -> accept(socket)
			socket.onerror = reject
	return Promise.reject("Socket in bad state #{socket.readyState}")

Resolve = Symbol('resolve')
Internals = Symbol('internals')
Close = Symbol('close')
IsProxy = Symbol('isProxy')

LazyProxy = (socket, opts={}) ->
	opts.autopromise ?= false
	opts.expose ?= {}
	socket = await ensureSocket socket
	opts.remote ?= Remote opts.expose, socket, opts.name

	return root: LazyProxy_ opts, [new GetOp 'root'], false

util = require 'util'
if util.inspect.defaultOptions
	util.inspect.defaultOptions.customInspect = false

opcode_path = (opcodes) ->
	p = ""
	for code in opcodes
		if code instanceof GetOp
			p += ".#{code.name}"
		else if code instanceof CallOp
			args = typeof (code.args)
			p += "(#{args})"
	return p


LazyProxy_ = (opts, opcodes, eagerApply=false) ->
	handler =
		opcodes: opcodes
		opts: opts
		_fetch: -> opts.remote opcodes
		
		get: (target, property, receiver) ->
			if property == 'call'
				return (thisArg, args...) =>
					@apply(@, thisArg, args)
			
			if property == 'apply'
				return (thisArg, args...) =>
					@apply(@, thisArg, args)

			if property == '_isBuffer'
				return false

			if property == 'then'
				return

			if property == IsProxy
				return true

			if property == Symbol.toPrimitive
				return -> "[LazyProxy to #{opcode_path opcodes}]"
			
			if property == Internals
				return @

			if property == Resolve
				return @_fetch()

			if property == Close
				return opts.remote.close()

			if @opts.autopromise and property == 'then'
				p = @_fetch()
				return p.then.bind p
			
			if typeof(property) == 'symbol'
				return target[property]
			
			return LazyProxy_ Object.create(@opts), [opcodes..., (new GetOp property)], eagerApply

		apply: (target, thisArg, args) ->
			proxy = LazyProxy_ Object.create(@opts), [opcodes..., (new CallOp Array.from(args))], eagerApply
			if eagerApply
				return LazyProxy.resolve proxy
			return proxy
	new Proxy (->), handler

LazyProxy.Resolve = Resolve
LazyProxy.Internals = Internals
LazyProxy.Close = Close
LazyProxy.IsProxy = IsProxy
LazyProxy.resolve = (p) -> Reflect.get p, Resolve
LazyProxy.close = (p) -> Reflect.get p, Close
LazyProxy.isProxy = (p) ->
	try
		return (Reflect.get p, IsProxy)?
	catch
		return false
LazyProxy.internals = (p) -> Reflect.get p, Internals

module.exports = LazyProxy

