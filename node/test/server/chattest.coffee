request = require("request")
assert = require("assert")
should = require("should")
redis = require("redis")
util = require("util")
fs = require("fs")
io = require 'socket.io-client'
crypto = require 'crypto'
dcrypt = require 'dcrypt'
async = require 'async'
rc = redis.createClient()
port = 443
baseUri = "https://localhost:" + port
jar1 = undefined
jar2 = undefined
cookie1 = undefined
cookie2 = undefined

cleanup = (done) ->
  keys = [
    "users:test0",
    "users:test1",
    "friends:test0",
    "friends:test1",
    "invites:test0",
    "invited:test0",
    "invites:test1",
    "invited:test1",
    "test0:test1:id",
    "messages:test0:test1",
    "conversations:test1",
    "conversations:test0",
    "keyversion:test0",
    "keys:test0:1",
    "keyversion:test1",
    "keys:test1:1",
    "control:message:test0:test1",
    "control:message:test0:test1:id"
    "control:user:test0",
    "control:user:test1",
    "control:user:test0:id",
    "control:user:test1:id"
    "users"]
  rc.del keys, (err, data) ->
    if err
      done err
    else
      done()


login = (username, password, jar, authSig, done, callback) ->
  request.post
    url: baseUri + "/login"
    jar: jar
    json:
      username: username
      password: password
      authSig: authSig
    (err, res, body) ->
      if err
        done err
      else
        cookie = jar.get({ url: baseUri }).map((c) -> c.name + "=" + c.value).join("; ")
        callback res, body, cookie

signup = (username, password, jar, dhPub, dsaPub, authSig, done, callback) ->
  request.post
    url: baseUri + "/users"
    jar: jar
    json:
      username: username
      password: password
      dhPub: dhPub
      dsaPub: dsaPub
      authSig: authSig
    (err, res, body) ->
      if err
        done err
      else
        cookie = jar.get({ url: baseUri }).map((c) -> c.name + "=" + c.value).join("; ")
        callback res, body, cookie

generateKey = (i, callback) ->
  ecdsa = new dcrypt.keypair.newECDSA 'secp521r1'
  ecdh = new dcrypt.keypair.newECDSA 'secp521r1'

  random = crypto.randomBytes 16

  dsaPubSig =
    crypto
      .createSign('sha256')
      .update(new Buffer("test#{i}"))
      .update(new Buffer("test#{i}"))
      .update(random)
      .sign(ecdsa.pem_priv, 'base64')

  sig = Buffer.concat([random, new Buffer(dsaPubSig, 'base64')]).toString('base64')

  callback null, {
  ecdsa: ecdsa
  ecdh: ecdh
  sig: sig
  }


makeKeys = (i) ->
  return (callback) ->
    generateKey i, callback

createKeys = (number, done) ->
  keys = []
  for i in [0..number]
    keys.push makeKeys(i)

  async.parallel keys, (err, results) ->
    if err?
      done err
    else
      done null, results


describe "surespot chat test", () ->
  keys = undefined
  before (done) ->
    createKeys 2, (err, keyss) ->
      keys = keyss
      cleanup done

  client = undefined
  client1 = undefined
  jsonMessage = {type: "message", to: "test0", toVersion: "1", from: "test1", fromVersion: "1", iv: 1, data: "message data", mimeType: "text/plain"}

  it 'client 1 connect', (done) ->
    jar1 = request.jar()
    signup 'test0', 'test0', jar1, keys[0].ecdh.pem_pub, keys[0].ecdsa.pem_pub, keys[0].sig, done, (res, body, cookie) ->
      client = io.connect baseUri, { 'force new connection': true}, cookie
      cookie1 = cookie
      client.once 'connect', ->
        done()

  it 'client 2 connect', (done) ->
    jar2 = request.jar()
    signup 'test1', 'test1', jar2, keys[1].ecdh.pem_pub, keys[1].ecdsa.pem_pub, keys[1].sig, done, (res, body, cookie) ->
      client1 = io.connect baseUri, { 'force new connection': true}, cookie
      cookie2 = cookie
      client1.once 'connect', ->
        done()

#  it 'should not be able to send a message to a non friend', (done) ->
#    #server will disconnect you!
#    client.once 'disconnect', ->
#      done()
#    client.send JSON.stringify jsonMessage


  it 'invite user should emit invite and invited user control messages', (done) ->
    clientReceived = false
    client1Received = false
    client1.once 'control', (data) ->
      receivedControlMessage = JSON.parse data
      receivedControlMessage.type.should.equal 'user'
      receivedControlMessage.action.should.equal 'invited'
      receivedControlMessage.data.should.equal 'test0'
      should.not.exist receivedControlMessage.localid
      should.not.exist receivedControlMessage.moredata
      client1Received = true
      done() if clientReceived


    client.once 'control', (data) ->
      receivedControlMessage = JSON.parse data
      receivedControlMessage.type.should.equal 'user'
      receivedControlMessage.action.should.equal 'invite'
      receivedControlMessage.data.should.equal 'test1'
      should.not.exist receivedControlMessage.localid
      should.not.exist receivedControlMessage.moredata
      clientReceived = true
      done() if client1Received


    request.post
      jar: jar2
      url: baseUri + "/invite/test0"
      (err, res, body) ->
        if err
          done err

  it 'accept invite should emit added user control messages', (done) ->
    clientReceived = false
    client1Received = false
    client1.once 'control', (data) ->
      receivedControlMessage = JSON.parse data
      receivedControlMessage.type.should.equal 'user'
      receivedControlMessage.action.should.equal 'added'
      receivedControlMessage.data.should.equal 'test0'
      should.not.exist receivedControlMessage.localid
      should.not.exist receivedControlMessage.moredata
      should.not.exist receivedControlMessage.from
      client1Received = true
      done() if clientReceived


    client.once 'control', (data) ->
      receivedControlMessage = JSON.parse data
      receivedControlMessage.type.should.equal 'user'
      receivedControlMessage.action.should.equal 'added'
      receivedControlMessage.data.should.equal 'test1'
      should.not.exist receivedControlMessage.localid
      should.not.exist receivedControlMessage.moredata
      should.not.exist receivedControlMessage.from
      clientReceived = true
      done() if client1Received

    request.post
      jar: jar1
      url: baseUri + "/invites/test1/accept"
      (err, res, body) ->
        if err
          done err

  it 'should have created 2 user control messages', (done) ->
    request.get
      jar: jar1
      url: baseUri + "/latestids/0"
      (err, res, body) ->
        if err
          done err
        else
          res.statusCode.should.equal 200
          messageData = JSON.parse(body)

          controlData = messageData.userControlMessages
          controlData.length.should.equal 2
          receivedControlMessage = JSON.parse(controlData[0])
          receivedControlMessage.type.should.equal "user"
          receivedControlMessage.action.should.equal "invite"
          receivedControlMessage.data.should.equal "test1"
          receivedControlMessage.id.should.equal 1
          should.not.exist receivedControlMessage.localid
          should.not.exist receivedControlMessage.moredata
          should.not.exist receivedControlMessage.from



          receivedControlMessage = JSON.parse(controlData[1])
          receivedControlMessage.type.should.equal "user"
          receivedControlMessage.action.should.equal "added"
          receivedControlMessage.data.should.equal "test1"
          receivedControlMessage.id.should.equal 2

          should.not.exist receivedControlMessage.localid
          should.not.exist receivedControlMessage.moredata
          should.not.exist receivedControlMessage.from
          done()


  it 'should be able to send a message to a friend', (done) ->
    client1.once 'message', (receivedMessage) ->
      receivedMessage = JSON.parse receivedMessage
      receivedMessage.to.should.equal jsonMessage.to
      receivedMessage.id.should.equal 1
      receivedMessage.from.should.equal jsonMessage.from
      receivedMessage.data.should.equal jsonMessage.data
      receivedMessage.mimeType.should.equal jsonMessage.mimeType
      receivedMessage.iv.should.equal jsonMessage.iv
      done()


    jsonMessage.from = "test0"
    jsonMessage.to = "test1"
    client.send JSON.stringify(jsonMessage)

  it 'should be able to delete received message', (done) ->
    deleteControlMessage = {}
    deleteControlMessage.type = 'message'
    deleteControlMessage.action = 'delete'
    deleteControlMessage.localid = 1
    deleteControlMessage.data = "test0:test1"
    deleteControlMessage.moredata = 1
    deleteControlMessage.from = "test1"

    client1.once 'control', (data) ->
      receivedControlMessage = JSON.parse data
      receivedControlMessage.type.should.equal deleteControlMessage.type
      receivedControlMessage.action.should.equal deleteControlMessage.action
      receivedControlMessage.localid.should.equal deleteControlMessage.localid
      receivedControlMessage.data.should.equal deleteControlMessage.data
      receivedControlMessage.moredata.should.equal deleteControlMessage.moredata
      receivedControlMessage.from.should.equal deleteControlMessage.from
      done()

    client1.emit 'control', JSON.stringify(deleteControlMessage)

  it 'deleted received message should not be returned', (done) ->
      #get the message to see if it's been marked as deleted
    request.get
      jar: jar1
      url: baseUri + "/messagedata/test1/0/0"
      (err, res, body) ->
        if err
          done err
        else
          messageData = JSON.parse(body)
          messageData.messages.should.not.exist
          done()


  it 'should be able to delete sent message', (done) ->
    deleteControlMessage = {}
    deleteControlMessage.type = 'message'
    deleteControlMessage.action = 'delete'
    deleteControlMessage.localid = 2
    deleteControlMessage.data = "test0:test1"
    deleteControlMessage.moredata = 1
    deleteControlMessage.from = "test0"

    client.once 'control', (data) ->
      receivedControlMessage = JSON.parse data
      receivedControlMessage.type.should.equal deleteControlMessage.type
      receivedControlMessage.action.should.equal deleteControlMessage.action
      receivedControlMessage.localid.should.equal deleteControlMessage.localid
      receivedControlMessage.data.should.equal deleteControlMessage.data
      receivedControlMessage.moredata.should.equal deleteControlMessage.moredata
      receivedControlMessage.from.should.equal deleteControlMessage.from
      done()

    client.emit 'control', JSON.stringify(deleteControlMessage)


  it 'deleted sent message should not be returned from the server', (done) ->
    #get the message to see if it's been marked as deleted
    request.get
      jar: jar1
      url: baseUri + "/messagedata/test1/0/0"
      (err, res, body) ->
        if err
          done err
        else
          messageData = JSON.parse(body)
          messageData.messages.should.not.exist
          done()

  it 'sending 3 messages then asking for messages after the 2nd messages should return 1 message with the correct id, and 2 delete control messages for the prior deletes', (done) ->

    jsonMessage.from = "test0"
    jsonMessage.to = "test1"
    jsonMessage.iv = 2
    #id 2
    client.send JSON.stringify(jsonMessage)
    #id 3
    jsonMessage.iv = 3
    client.send JSON.stringify(jsonMessage)
    #id 4
    jsonMessage.iv = 4
    client.send JSON.stringify(jsonMessage)
    request.get
      jar: jar1
      url: baseUri + "/messagedata/test1/3/0"
      (err, res, body) ->
        if err
          done err
        else
          res.statusCode.should.equal 200
          messageData = JSON.parse(body)

          messages = messageData.messages
          messages.length.should.equal 1
          receivedMessage = JSON.parse(messages[0])
          receivedMessage.to.should.equal jsonMessage.to
          receivedMessage.id.should.equal 4
          receivedMessage.from.should.equal jsonMessage.from
          receivedMessage.data.should.equal jsonMessage.data
          receivedMessage.mimeType.should.equal jsonMessage.mimeType
          receivedMessage.iv.should.equal 4


          controlData = messageData.controlMessages
          controlData.length.should.equal 2
          receivedControlMessage = JSON.parse(controlData[0])
          receivedControlMessage.type.should.equal "message"
          receivedControlMessage.action.should.equal "delete"
          receivedControlMessage.localid.should.equal 1
          receivedControlMessage.data.should.equal "test0:test1"
          receivedControlMessage.moredata.should.equal 1
          receivedControlMessage.from.should.equal "test1"
          receivedControlMessage.id.should.equal 1


          receivedControlMessage = JSON.parse(controlData[1])
          receivedControlMessage.type.should.equal "message"
          receivedControlMessage.action.should.equal "delete"
          receivedControlMessage.localid.should.equal 2
          receivedControlMessage.data.should.equal "test0:test1"
          receivedControlMessage.moredata.should.equal 1
          receivedControlMessage.from.should.equal "test0"
          receivedControlMessage.id.should.equal 2
          done()


  it 'resending message should not create new message', (done) ->
    client1.once 'message', (receivedMessage) ->
      receivedMessage = JSON.parse receivedMessage
      receivedMessage.id.should.equal 4


      done()


    jsonMessage.from = "test0"
    jsonMessage.to = "test1"
    jsonMessage.resendId = 3
    client.send JSON.stringify(jsonMessage)


  it 'resending control message should not create new message', (done) ->
    client1.once 'control', (receivedMessage) ->
      receivedMessage = JSON.parse receivedMessage
      receivedMessage.id.should.equal 2

      request.get
        jar: jar1
        url: baseUri + "/messagedata/test1/-1/0"
        (err, res, body) ->
          if err
            done err
          else
            res.statusCode.should.equal 200
            messageData = JSON.parse(body)


            controlData = messageData.controlMessages
            controlData.length.should.equal 2
            receivedControlMessage = JSON.parse(controlData[0])
            receivedControlMessage.type.should.equal "message"
            receivedControlMessage.action.should.equal "delete"
            receivedControlMessage.localid.should.equal 1
            receivedControlMessage.data.should.equal "test0:test1"
            receivedControlMessage.moredata.should.equal 1
            receivedControlMessage.from.should.equal "test1"
            receivedControlMessage.id.should.equal 1


            receivedControlMessage = JSON.parse(controlData[1])
            receivedControlMessage.type.should.equal receivedMessage.type
            receivedControlMessage.action.should.equal receivedMessage.action
            receivedControlMessage.localid.should.equal receivedMessage.localid
            receivedControlMessage.data.should.equal receivedMessage.data
            receivedControlMessage.moredata.should.equal receivedMessage.moredata
            receivedControlMessage.from.should.equal receivedMessage.from
            receivedControlMessage.id.should.equal receivedMessage.id
            done()

    deleteControlMessage = {}
    deleteControlMessage.type = 'message'
    deleteControlMessage.action = 'delete'
    deleteControlMessage.localid = 2
    deleteControlMessage.data = "test0:test1"
    deleteControlMessage.moredata = 1
    deleteControlMessage.from = "test0"
    deleteControlMessage.resendId = 0
    client.emit 'control', JSON.stringify(deleteControlMessage)



  after (done) ->
    client.disconnect()
    client1.disconnect()
    cleanup done