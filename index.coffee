axios = require 'axios'
yaml = require 'js-yaml'
_ = require 'lodash'
urlParse = require 'url-parse'

class RequestOp
	constructor: (@seq, @opcodes) ->

class ResponseOp
	constructor: (@seq, @response, @isError) ->

class GetOp
	constructor: (@name) ->
	handle: (obj) ->
		if @name.length == 0
			return obj
		v = obj[@name]
		if typeof(v) == 'function'
			v = v.bind(obj)
		return v

class CallOp
	constructor: (@args) ->
	handle: (obj) -> await obj(@args...)


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
		construct: (v) -> new CallOp v.args
		represent: (v) -> _.assign {}, v
	
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

	# TODO: Extra dangerous!!
	types.push yaml.DEFAULT_FULL_SCHEMA.explicit...
	return yaml.Schema.create yaml.DEFAULT_FULL_SCHEMA, types

Codec = (heap) ->
	schema = Schema heap

	encode: (obj) ->
		yaml.dump obj, schema: schema
	decode: (obj) ->
		yaml.load obj, schema: schema

_Resolve = (result, opcodes=[]) ->
	for opcode in opcodes
		result = await opcode.handle(result)
	return result

Remote = (root, socket) ->
	seq = 0
	pending = new Map()
	root =
		root: root
		heap: {}
	handleRequest = (msg) ->
		return false unless msg instanceof RequestOp
		try
			result = await _Resolve(root, msg.opcodes)
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
		msg = decode event.data
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
			return heapAddresses v

		heapSeq += 1
		root.heap[heapSeq] = v
		heapAddresses.set v, String heapSeq
		return String heapSeq
	
	self.getProxyForAddress = (id) ->
		opts = remote: self
		proxy = LazyProxy_ opts, [(new GetOp 'heap'), (new GetOp id)], false, true
		return proxy
		

	{encode, decode} = Codec self
	self.close = -> socket.close()
	return self


ensureSocket = (socket) ->
	if typeof(socket) == 'string'
		socket = new WebSocket socket
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
	opts.autopromise ?= true
	opts.expose ?= {}
	socket = await ensureSocket socket
	opts.remote ?= Remote opts.expose, socket
	return LazyProxy_ opts, [new GetOp 'root'], true



LazyProxy_ = (opts, opcodes, isFirst=false, eagerApply=false) ->
	handler =
		opcodes: opcodes
		opts: opts
		_fetch: -> opts.remote opcodes
		
		get: (target, property, receiver) ->
			# A huge hack! Without this
			# the first object is impossible to return!
			if property == 'then' and isFirst
				isFirst = false
				return undefined

			if property == IsProxy
				return true

			if property == Symbol.toPrimitive
				return -> "[LazyProxy to #{opcodes}]"
			
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
			
			return LazyProxy_ Object.create(@opts), [opcodes..., (new GetOp property)]

		apply: (target, thisArg, args) ->
			proxy = LazyProxy_ Object.create(@opts), [opcodes..., (new CallOp args)]
			if eagerApply
				return proxy[Resolve]
			return proxy
	new Proxy (->), handler

LazyProxy.Resolve = Resolve
LazyProxy.Internals = Internals
LazyProxy.Close = Close
LazyProxy.resolve = (p) -> return p[Resolve]
LazyProxy.close = (p) -> return p[Close]

module.exports = LazyProxy

