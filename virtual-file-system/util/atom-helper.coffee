{CompositeDisposable} = require 'atom'

module.exports =
class AtomHelper
  constructor: (@virtualFileSystem) ->
    @handleEvents()

  handleEvents: ->
    body = document.body
    body.classList.add('learn-ide')

    @disposables = new CompositeDisposable

    @disposables.add atom.commands.add body,
      'learn-ide:save': @onLearnSave

    @disposables.add atom.workspace.observeTextEditors (editor) =>
      editor.onDidSave(@onCoreSave)

  configPath: ->
    atom.configDirPath

  package: ->
    # todo: update package name
    atom.packages.getActivePackage('tree-view')

  treeView: ->
    @package()?.mainModule.treeView

  token: ->
    atom.config.get('learn-ide.oauthToken')

  addOpener: (opener) ->
    atom.workspace.addOpener(opener)

  clearProjects: ->
    @initialProjectPaths = atom.project.getPaths()
    @initialProjectPaths.forEach (path) -> atom.project.removePath(path)

  updateProject: (path, directoryExpansionStates) ->
    atom.project.addPath(path)
    @treeView()?.updateRoots(directoryExpansionStates)

  reloadTreeView: (path, pathToSelect) ->
    @treeView()?.entryForPath(path).reload()
    @treeView()?.selectEntryForPath(pathToSelect or path)

  findBuffer: (path) ->
    atom.project.findBufferForPath(path)

  findOrCreateBuffer: (path) ->
    atom.project.bufferForPath(path)

  loading: ->
    atom.notifications.addInfo 'Learn IDE: loading your remote code...',
      detail: """
              This may take a moment, but you likely won't need
              to wait again on this computer.
              """

  onLearnSave: ({target}) =>
    textEditor = atom.workspace.getTextEditors().find (editor) ->
      editor.element is target

    content = new Buffer(textEditor.getText()).toString('base64')
    @virtualFileSystem.learnSave(textEditor.getPath(), content)

  onCoreSave: ({path}) =>
    @findOrCreateBuffer(path).then (textBuffer) =>
      content = new Buffer(textBuffer.getText()).toString('base64')
      @virtualFileSystem.coreSave(path, content)

  save: (path) ->
    textEditor = atom.workspace.getTextEditors().find (editor) ->
      editor.getPath() is path

    if textEditor?
      atom.commands.dispatch(textEditor.element, 'core:save')
