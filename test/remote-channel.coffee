Transport = require "../src/redis-transport"
RemoteChannel = require "../src/remote-channel"
helpers = require "./helpers"
{testify,assert,events} = helpers

make = ->
  
  transport = new Transport
    host: "localhost"
    port: 6379

  transport.events.forward events

  channel = new RemoteChannel
    name: "greeting"
    transport: transport
      
  channel


testify.test "A remote channel", (context) ->

  context.test "can send and receive messages", (context) ->

    sender = make()
    receiver = make()

    listen = receiver.listen()

    listen.on "success", ->

      receiver.on "hello", (message) ->
        context.test "using an 'on' handler", ->
          assert.ok message.content is "Dan"
          receiver.end()
          sender.end()

      sender.send event: "hello", content: "Dan"
    