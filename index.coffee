qs = require 'qs'
axios = require 'axios'

Resolve = Symbol('resolve')

LazyProxy = (path) ->
	new Proxy (->),
		path: path
		get: (target, property, receiver) ->
			if property == Symbol.toPrimitive
				return -> "[LazyProxy to #{path}]"

			if property == GET
				return axios.get(@path).then (r) -> r.data

			return LazyProxy @path + '/' + target
		apply: (target, thisArg, args) ->
			return LazyProxy @path + '!' + qs.stringify(args)

LazyProxy.Resolve = Resolve
LazyProxy.resolve = (p) -> return p[Resolve]

module.exports = LazyProxy

