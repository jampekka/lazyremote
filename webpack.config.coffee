path = require 'path'

module.exports =
	entry: './test/basic.coffee'
	output:
		path: path.resolve('./test/browser')
		filename: 'tests.mangled.js'
	module:
		rules: [
			(test: /\.coffee$/, loader: 'babel-loader!coffee-loader'),
		]

