fs = require 'fs-plus'
_ = require 'underscore-plus'
shell = require 'shell'
_path = require 'path'
convert = require './util/path-converter'
AtomHelper = require './util/atom-helper'
FileSystemNode = require './file-system-node'
ShellAdapter = require './adapters/shell-adapter'
FSAdapter = require './adapters/fs-adapter'
SingleSocket = require 'single-socket'

require('dotenv').config
  path: _path.join(__dirname, '../.env'),
  silent: true

WS_SERVER_URL = (->
  config = _.defaults
    host: process.env['IDE_WS_HOST']
    port: process.env['IDE_WS_PORT']
    path: process.env['IDE_WS_PATH']
  ,
    host: 'ile.learn.co',
    port: 443,
    path: 'go_fs_server'
    protocol: 'wss'

  if config.port isnt 443
    config.protocol = 'ws'

  {protocol, host, port, path} = config

  "#{protocol}://#{host}:#{port}/#{path}"
)()

class VirtualFileSystem
  constructor: ->
    @atomHelper = new AtomHelper(this)
    @fs = new FSAdapter(this)
    @shell = new ShellAdapter(this)
    @projectNode = new FileSystemNode({})

    @setLocalPaths()

    @atomHelper.clearProjects()

    @connect()
    @addOpener()

  setLocalPaths: ->
    @localRoot = _path.join(@atomHelper.configPath(), '.learn-ide')
    @logDirectory = _path.join(@localRoot, 'var', 'log')
    @receivedLog = _path.join(@logDirectory, 'received')
    @sentLog = _path.join(@logDirectory, 'sent')
    convert.configure({@localRoot})

    fs.makeTreeSync(@logDirectory)

  connect: ->
    messageCallbacks =
      init: @onRecievedInit
      sync: @onRecievedSync
      open: @onRecievedFetchOrOpen
      fetch: @onRecievedFetchOrOpen
      change: @onRecievedChange
      rescue: @onRecievedRescue

    @websocket = new SingleSocket "#{WS_SERVER_URL}?token=#{@atomHelper.token()}",
      onopen: =>
        @send {command: 'init'}
      onmessage: (message) =>
        fs.appendFileSync(@receivedLog, "\n#{new Date}: #{message}")

        try
          {type, data} = JSON.parse(message)
          console.log 'RECEIVED:', type
        catch err
          console.log 'ERROR PARSING MESSAGE:', message, err

        messageCallbacks[type]?(data)
      onerror: (err) ->
        console.error 'ERROR:', err
      onclose: (event) ->
        console.log 'CLOSED:', event

  addOpener: ->
    @atomHelper.addOpener (uri) =>
      if @hasPath(uri) and not fs.existsSync(uri)
        @open(uri)

  serialize: ->
    @projectNode.serialize()

  activate: (@activationState) ->
    # TODO: need to handle undefined obj on first start up
    virtualProject = @activationState.virtualProject || {}
    @projectNode = new FileSystemNode(virtualProject)

    if not @projectNode.path?
      return @atomHelper.loading()

    @atomHelper.updateProject(@projectNode.localPath(), @expansionState())

  expansionState: ->
    @activationState?.directoryExpansionStates

  send: (msg) ->
    convertedMsg = {}

    for own key, value of msg
      if typeof value is 'string' and value.startsWith(@localRoot)
        convertedMsg[key] = convert.localToRemote(value)
      else
        convertedMsg[key] = value

    console.log 'SEND:', convertedMsg
    payload = JSON.stringify(convertedMsg)
    fs.appendFileSync(@sentLog, "\n#{new Date}: #{payload}")
    @websocket.send payload

  # -------------------
  # onmessage callbacks
  # -------------------

  onRecievedInit: ({virtualFile}) =>
    @projectNode = new FileSystemNode(virtualFile)
    @atomHelper.updateProject(@projectNode.localPath(), @expansionState())
    @sync(@projectNode.path)

  onRecievedSync: ({path, pathAttributes}) =>
    console.log 'SYNC:', path
    node = @getNode(path)
    localPath = node.localPath()

    node.traverse (entry) ->
      entry.setDigest(pathAttributes[entry.path])

    if fs.existsSync(localPath)
      remotePaths = node.map (e) -> e.localPath()
      localPaths = fs.listTreeSync(localPath)
      pathsToRemove = _.difference(localPaths, remotePaths)
      pathsToRemove.forEach (path) -> shell.moveItemToTrash(path)

    node.findPathsToSync().then (paths) => @fetch(paths)

  onRecievedChange: ({event, path, virtualFile}) =>
    node =
      switch event
        when 'moved_from', 'delete'
          @projectNode.remove(path)
        when 'moved_to', 'create'
          @projectNode.add(virtualFile)
        when 'modify'
          @projectNode.update(virtualFile)
        else
          console.log 'UNKNOWN CHANGE:', event, path

    if node?
      parent = node.parent
      @atomHelper.reloadTreeView(parent.localPath(), node.localPath())
      # TODO: sync again?
      # @sync(parent.path)

  onRecievedFetchOrOpen: ({path, content}) =>
    # TODO: preserve full stats
    node = @getNode(path)
    node.setContent(content)

    stats = node.stats
    if stats.isDirectory()
      return fs.makeTreeSync(node.localPath())

    mode = stats.mode
    textBuffer = @atomHelper.findBuffer(node.localPath())
    if textBuffer?
      fs.writeFileSync(node.localPath(), node.buffer(), {mode})
      textBuffer.updateCachedDiskContentsSync()
      textBuffer.reload()
    else
      fs.writeFile(node.localPath(), node.buffer(), {mode})

  onRecievedRescue: ({message, backtrace}) ->
    console.log 'RESCUE:', message, backtrace

  # ------------------
  # File introspection
  # ------------------

  getNode: (path) ->
    @projectNode.get(path)

  hasPath: (path) ->
    @projectNode.has(path)

  isDirectory: (path) ->
    @stat(path).isDirectory()

  isFile: (path) ->
    @stat(path).isFile()

  isSymbolicLink: (path) ->
    @stat(path).isSymbolicLink()

  list: (path, extension) ->
    @getNode(path).list(extension)

  lstat: (path) ->
    # TODO: lstat
    @stat(path)

  read: (path) ->
    @getNode(path)

  readdir: (path) ->
    @getNode(path).entries()

  realpath: (path) ->
    # TODO: realpath
    path

  stat: (path) ->
    @getNode(path)?.stats

  # ---------------
  # File operations
  # ---------------

  cp: (source, destination) ->
    @send {command: 'cp', source, destination}

  mv: (source, destination) ->
    @send {command: 'mv', source, destination}

  mkdirp: (path) ->
    @send {command: 'mkdirp', path}

  touch: (path) ->
    @send {command: 'touch', path}

  trash: (path) ->
    @send {command: 'trash', path}

  sync: (path) ->
    @send {command: 'sync', path}

  open: (path) ->
    @send {command: 'open', path}

  fetch: (paths) ->
    @send {command: 'fetch', paths}

  save: (path) ->
    @atomHelper.findOrCreateBuffer(path).then (textBuffer) =>
      content = new Buffer(textBuffer.getText()).toString('base64')
      @send {command: 'save', path, content}

module.exports = new VirtualFileSystem

