{randomKey} = require "key-forge"
{Redis} = require "pirate"
EventChannel = require "./event-channel"
RemoteQueue = require "./remote-queue"
Transport = require "./redis-transport"

class DurableChannel extends EventChannel

  constructor: (options) ->
    super
    
    {@name, @timeoutMonitorFrequency} = options

    unless @name?
      throw new Error "Durable channels cannot be anonymous"

    @timeoutMonitor = null
    @timeoutMonitorFrequency ?= 1000

    @events = new EventChannel

    @adapter = new Redis.Adapter
      events: new EventChannel
      host: options.redis.host
      port: options.redis.port
    @adapter.events.on "ready", => @fire event: "ready"

    @transport = new Transport
      host: options.redis.host
      port: options.redis.port
    @transport.events.forward @events

    @store = null
    @queue = new RemoteQueue
      name: "#{@name}.queue"
      transport: @transport

    @destinationStores = {}
    @destinationQueues = {}

    @monitorTimeouts()

  package: ({content, to, requestId, timeout}) ->
    message = 
      id: randomKey(16)
      requestId: requestId
      from: @name
      to: to
      timeout: timeout
      content: content

  getStore: ->
    return @store if @store?
    
    do @events.serially (go) =>
      go => @adapter.collection "#{@name}.messages"
      go (@store) => @store

  getDestinationStore: (name) ->
    return @destinationStores[name] if @destinationStores[name]?

    do @events.serially (go) =>
      go => @adapter.collection "#{name}.messages"
      go (store) => @destinationStores[name] = store

  getDestinationQueue: (name) ->
    @destinationQueues[name] ?= new RemoteQueue
      name: "#{name}.queue"
      transport: @transport

  setMessageTimeout: (name, channel, id, timeout) ->
    if channel? and id? and timeout?
      @events.source (events) =>
        @adapter.client.zadd(
          ["#{name}.pending", (Date.now() + timeout), "#{channel}::#{id}"], 
          events.callback
        )

  clearMessageTimeout: (name, channel, id) ->
    if id?
      @events.source (events) =>
        @adapter.client.zrem(
          ["#{name}.pending", "#{channel}::#{id}"]
          events.callback
        )

  getMessageTimeout: (name, channel, id) ->
    if id?
      @events.source (events) =>
        @adapter.client.zscore(
          ["#{name}.pending", "#{channel}::#{id}"]
          events.callback
        )

  monitorTimeouts: ->
    loopToMonitor = =>
      do @events.serially (go) =>
        go =>
          @events.source (events) =>
            @adapter.client.zrangebyscore(
              ["#{@name}.pending", 0, Date.now()]
              events.callback
            )
        go (expiredMessages) => 
          return if expiredMessages.length == 0
          @events.source (events) =>
            returned = 0
            for expiredMessage in expiredMessages
              expiredMessageTokens = expiredMessage.split("::")
              _events = @expireMessage(expiredMessageTokens[0], expiredMessageTokens[1])
              _events.on "success", ->
                returned++
                events.emit("success") if returned == expiredMessages.length
              _events.on "error", (err) -> events.emit "error", err
        go => 
          @timeoutMonitor = setTimeout(loopToMonitor, @timeoutMonitorFrequency)

    @timeoutMonitor = setTimeout(loopToMonitor, @timeoutMonitorFrequency)

  expireMessage: (channel, id) ->
    store = null
    message = null
    do @events.serially (go) =>
      go => @getDestinationStore channel
      go (_store) => 
        store = _store
        store.get(id)
      go (_message) => 
        message = _message
      go => @getMessageTimeout @name, channel, id
      go (timeout) =>
        # if reply was sent in the meantime, timeout would have been cleared, we shouldn't fire timeout if it was replied
        return unless timeout?
        do @events.serially (go) =>
          go =>
            if message?
              store.delete id
          go => @clearMessageTimeout @name, channel, id
          go =>
            if message?
              @fire event: "timeout", content: {content: message.content, requestId: message.requestId}

  send: ({content, to, timeout}) ->
    message = @package({content, to, timeout})
    do @events.serially (go) =>
      go => @getDestinationStore(to)
      go (destStore) => destStore.put message.id, message
      go => @setMessageTimeout @name, to, message.id, message.timeout
      go => @getDestinationQueue(to).emit("message", message.id)

  reply: ({message, response, timeout}) ->
    do @events.serially (go) =>
      go => @getStore()
      go (store) => store.get message.requestId
      go (request) =>
        # its possible that this is a reply to a message that already timed out
        return null unless request?
        
        message = @package({content: response, to: request.from, requestId: message.requestId, timeout})
        do @events.serially (go) =>
          go => @clearMessageTimeout(request.from, @name, message.requestId)
          go => @getDestinationStore(request.from)
          go (destStore) => destStore.put(message.id, message)
          go => @setMessageTimeout @name, request.from, message.id, message.timeout
          go => @getDestinationQueue(request.from).emit("message", message.id)

  close: (message) ->
    do @events.serially (go) =>
      go => @getStore()
      go (store) => store.delete message.responseId
      go => @clearMessageTimeout(message.to, message.from, message.responseId)

  listen: ->
    @events.source (events) =>
      @queue.listen().on "success", => 
        messageHandler = (messageId) =>
          store = null
          do @events.serially (go) =>
            go => @getStore()
            go (_store) => 
              store = _store
              store.get messageId
            go (message) =>
              # its possible that this message has already timed out and no longer available in the store
              return null unless message?

              return message unless message.requestId?

              destStore = null
              @events.source (events) =>
                do @events.serially (go) =>
                  go => @getDestinationStore(message.from)
                  go (_destStore) => 
                    destStore = _destStore
                    destStore.get(message.requestId)
                  go (request) =>
                    do @events.serially (go) =>
                      go => 
                        if request?
                          # now that we got the reply, we can delete the original request
                          destStore.delete(message.requestId)
                        else
                          # request has timed out, we should close it as the sender won't receive this message
                          store.delete(messageId)
                      go => 
                        events.emit("success", (if request? then message else null))
            go (message) =>
              if message?
                _message = content: message.content
                _message.from = if message.requestId? then message.to else message.from
                _message.to = if message.requestId? then message.from else message.to
                _message.requestId = if message.requestId? then message.requestId else message.id
                _message.responseId = message.id if message.requestId?
                @fire event: "message", content: _message
            go =>
              @queue.once("message", messageHandler) if @channels["message"]?.handlers?.length > 0

        @superOn ?= @on
        @on = (event, handler) =>
          @superOn event, handler
          if event == "message"
            @queue.once "message", messageHandler

        events.emit "success"

  end: -> 
    clearTimeout @timeoutMonitor
    @adapter.close()
    @queue.end()
    for key,queue of @destinationQueues
      queue.end()

module.exports = DurableChannel