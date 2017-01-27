_ = require 'underscore-plus'
{Point, Range, CompositeDisposable, Emitter, Disposable} = require 'atom'
{activatePaneItemInAdjacentPane, isActiveEditor} = require './utils'
settings = require './settings'
Grammar = require './grammar'
getFilterSpecForQuery = require './get-filter-spec-for-query'

class PromptGutter
  constructor: (@editor) ->
    @gutter = @editor.addGutter(name: 'narrow-prompt', priority: 100)

    @item = document.createElement('span')
    @item.textContent = " > "

  setToRow: (row) ->
    @marker?.destroy()
    @marker = @editor.markBufferPosition([row, 0])
    @gutter.decorateMarker @marker,
      class: "narrow-ui-selected-row"
      item: @item

  destroy: ->
    @marker?.destroy()

module.exports =
class UI
  # UI static
  # -------------------------
  @uiByEditor: new Map()
  @unregister: (ui) ->
    @uiByEditor.delete(ui.editor)
    @updateWorkspaceClassList()

  @register: (ui) ->
    @uiByEditor.set(ui.editor, ui)
    @updateWorkspaceClassList()

  @get: (editor) ->
    @uiByEditor.get(editor)

  @updateWorkspaceClassList: ->
    atom.views.getView(atom.workspace).classList.toggle('has-narrow', @uiByEditor.size)

  # UI.prototype
  # -------------------------
  autoPreview: false
  preventAutoPreview: false
  preventSyncToProviderEditor: false
  ignoreChangeOnEditor: false
  destroyed: false
  items: []
  itemsByProvider: null # Used to cache result
  lastNarrowQuery: ''

  onDidMoveToPrompt: (fn) -> @emitter.on('did-move-to-prompt', fn)
  emitDidMoveToPrompt: -> @emitter.emit('did-move-to-prompt')
  onDidMoveToItemArea: (fn) -> @emitter.on('did-move-to-item-area', fn)
  emitDidMoveToItemArea: -> @emitter.emit('did-move-to-item-area')

  constructor: (@provider, {@input}={}) ->
    @disposables = new CompositeDisposable
    @emitter = new Emitter
    @autoPreview = settings.get(@provider.getName() + "AutoPreview")

    # Special item used to translate narrow editor row to items without pain
    @promptItem = Object.freeze({_prompt: true, skip: true})
    @itemAreaStart = Object.freeze(new Point(1, 0))

    @providerEditor = @provider.editor

    # Setup narrow-editor
    # -------------------------
    @editor = atom.workspace.buildTextEditor(lineNumberGutterVisible: false)
    # FIXME
    # Opening multiple narrow-editor for same provider get title `undefined`
    # (e.g multiple narrow-editor for lines provider)
    providerDashname = @provider.getDashName()
    @editor.getTitle = -> providerDashname
    @editor.isModified = -> false
    @editor.onDidDestroy(@destroy.bind(this))
    @editorElement = @editor.element
    @editorElement.classList.add('narrow', 'narrow-editor', providerDashname)

    @disposables.add @onDidMoveToItemArea =>
      @vmpActivateNormalMode() if @vmpIsInsertMode()

    @promptGutter = new PromptGutter(@editor)

    @grammar = new Grammar(@editor, includeHeaderRules: @provider.includeHeaderGrammar)
    @disposables.add(@registerCommands())
    @disposables.add(@observeInputChange())
    @disposables.add(@observeCursorPositionChange())

    @disposables.add atom.workspace.onDidStopChangingActivePaneItem (item) =>
      unless item is @editor
        @rowMarker?.destroy()

    if @provider.boundToEditor
      @bindToEditor(@provider.editor)
      @disposables.add @providerEditor.onDidDestroy(@destroy.bind(this))

    @constructor.register(this)
    @disposables.add new Disposable =>
      @constructor.unregister(this)

  start: ->
    activatePaneItemInAdjacentPane(@editor, split: settings.get('directionToOpen'))
    @grammar.activate()
    @setPrompt(@input)
    @moveToPrompt(startInsert: true)
    @refresh()

  getPane: ->
    atom.workspace.paneForItem(@editor)

  isActive: ->
    isActiveEditor(@editor)

  isAtPrompt: ->
    @getPromptRange().containsPoint(@editor.getCursorBufferPosition())

  isAtItemArea: ->
    not @isAtPrompt()

  focus: ->
    pane = @getPane()
    pane.activate()
    pane.activateItem(@editor)

  focusPrompt: ->
    if @isActive() and @isAtPrompt()
      @activateProviderPane()
    else
      @focus() unless @isActive()
      @moveToPrompt(startInsert: true)

  toggleFocus: ->
    if @isActive()
      @activateProviderPane()
    else
      @focus()

  activateProviderPane: ->
    if (pane = @provider.getPane()) and pane.isAlive()
      pane.activate()

  destroy: ->
    return if @destroyed
    @destroyed = true
    @editorSubcriptions?.dispose()
    @disposables.dispose()
    @editor.destroy()
    @activateProviderPane()

    @provider?.destroy?()
    @promptGutter?.destroy()
    @rowMarker?.destroy()

  registerCommands: ->
    atom.commands.add @editorElement,
      'core:confirm': => @confirm()
      'narrow-ui:confirm-keep-open': => @confirm(keepOpen: true)
      'narrow-ui:preview-item': => @preview()
      'narrow-ui:toggle-auto-preview': => @toggleAutoPreview()
      'narrow-ui:refresh-force': => @refresh(force: true, moveToPrompt: true)
      'narrow-ui:move-to-prompt-or-selected-item': => @moveToPromptOrSelectedItem()
      'narrow-ui:move-to-prompt': => @moveToPrompt(startInsert: true)
      'narrow-ui:update-real-file': => @updateRealFile()
      'narrow-ui:focus-back': => @activateProviderPane()

  updateRealFile: ->
    return unless @provider.supportDirectEdit
    return unless @ensureNarrowEditorIsValidState()

    changes = []
    lines = @editor.buffer.getLines()
    for line, row in lines when @isNormalItem(item = @items[row])
      if item._lineHeader?
        line = line[item._lineHeader.length...] # Strip lineHeader

      unless line is item.text
        changes.push({newText: line, item})

    if changes.length
      @provider.updateRealFile(changes)

  moveUpDown: (direction) ->
    if (row = @getRowForSelectedItem()) >= 0
      @withLock => @editor.setCursorBufferPosition([row, 0])

    if @direction is 'down' and @provider.boundToEditor
      # Prevent side scroll of narrow editor
      point = @providerEditor.getCursorBufferPosition()
      if point.isGreaterThanOrEqual(_.last(@items).point)
        return

    @withPreventAutoPreview =>
      switch direction
        when 'up'
          @editor.moveUp()
        when 'down'
          @editor.moveDown()

    @confirm(keepOpen: true)

  nextItem: ->
    @moveUpDown('down')

  previousItem: ->
    @moveUpDown('up')

  isAutoPreview: ->
    if @preventAutoPreview
      false
    else
      @autoPreview

  toggleAutoPreview: ->
    @autoPreview = not @autoPreview
    @preview() if @isAutoPreview()

  getNarrowQuery: ->
    @lastNarrowQuery = @editor.lineTextForBufferRow(0)

  refresh: ({force, moveToPrompt}={}) ->
    if force
      @itemsByProvider = null
    if moveToPrompt
      @moveToPrompt()

    @ignoreChangeOnEditor = true
    # In case prompt accidentaly mutated
    eof = @editor.getEofBufferPosition()
    if eof.isLessThan(@itemAreaStart)
      eof = @setPrompt().end
      @moveToPrompt()

    filterSpec = getFilterSpecForQuery(@getNarrowQuery())

    Promise.resolve(@itemsByProvider ? @provider.getItems()).then (items) =>
      if @provider.supportCacheItems
        @itemsByProvider = items
      items = @provider.filterItems(items, filterSpec)
      @items = [@promptItem, items...]
      @renderItems(items)

      # No need to highlight excluded items
      @grammar.update(filterSpec.include)

      if @isActive()
        @selectItemForRow(@findNormalItem(1, 'next'))
      else
        @syncToProviderEditor() if @provider.boundToEditor
      @ignoreChangeOnEditor = false

  renderItems: (items) ->
    texts = items.map (item) => @provider.viewForItem(item)
    itemArea = new Range(@itemAreaStart, @editor.getEofBufferPosition())
    range = @editor.setTextInBufferRange(itemArea, texts.join("\n"), undo: 'skip')
    @editorLastRow = range.end.row

  ensureNarrowEditorIsValidState: ->
    # Ensure all item have valid line header
    unless @editorLastRow is @editor.getLastBufferRow()
      return false

    if @provider.showLineHeader
      for line, row in @editor.buffer.getLines() when @isNormalItem(item = @items[row])
        return false unless line.startsWith(item._lineHeader)

    true

  observeInputChange: ->
    @editor.buffer.onDidChange ({newRange, oldRange}) =>
      return if @ignoreChangeOnEditor

      promptRange = @getPromptRange()
      onPrompt = (range) -> range.intersectsWith(promptRange)
      notEmptyAndPrompt = (range) -> not range.isEmpty() and onPrompt(range)

      if notEmptyAndPrompt(newRange) or notEmptyAndPrompt(oldRange)
        if @editor.hasMultipleCursors()
          # Destroy cursors on prompt
          for selection in @editor.getSelections() when onPrompt(selection.getBufferRange())
            selection.destroy()
          # Recover query on prompt
          @setPrompt(@lastNarrowQuery)
        else
          @refresh()

  locked: false
  isLocked: -> @locked
  withLock: (fn) ->
    @locked = true
    fn()
    @locked = false

  withPreventAutoPreview: (fn) ->
    @preventAutoPreview = true
    fn()
    @preventAutoPreview = false

  observeCursorPositionChange: ->
    @editor.onDidChangeCursorPosition (event) =>
      return if @isLocked()

      {oldBufferPosition, newBufferPosition, textChanged, cursor} = event
      return if textChanged or
        (not cursor.selection.isEmpty()) or
        (oldBufferPosition.row is newBufferPosition.row)

      newRow = newBufferPosition.row
      oldRow = oldBufferPosition.row

      if newRow is 0 # was at Item area
        @moveToPrompt()
        return

      direction = if newRow > oldRow then 'next' else 'previous'

      row = @findNormalItem(newRow, direction)
      if row? # row might be '0'
        @selectItemForRow(row)
        if row is newRow
          @emitDidMoveToItemArea() if oldRow is 0
        else
          @moveToSelectedItem()
      else
        @moveToPrompt() if direction is 'previous'

      @preview() if @isAutoPreview()

  syncToProviderEditor: ->
    return if @preventSyncToProviderEditor
    # Detect item
    # - cursor position is equal or greather than that item.
    cursorPosition = @providerEditor.getCursorBufferPosition()
    foundItem = null
    for item in @items by -1 when item.point?.isLessThanOrEqual(cursorPosition)
      foundItem = item
      break

    if foundItem?
      @selectItem(item)
    else
      @selectItemForRow(@findNormalItem(1, 'next'))

    @moveToSelectedItem() unless @isActive()

  moveToSelectedItem: ->
    if (row = @getRowForSelectedItem()) >= 0
      oldPosition = @editor.getCursorBufferPosition()
      @withLock =>
        @editor.setCursorBufferPosition([row, oldPosition.column])
        @emitDidMoveToItemArea() if oldPosition.row is 0 # was at prompt

  setRowMarker: (editor, point) ->
    @rowMarker?.destroy()
    @rowMarker = editor.markBufferRange([point, point])
    editor.decorateMarker(@rowMarker, type: 'line', class: 'narrow-result')

  preview: ->
    @preventSyncToProviderEditor = true
    @confirm(keepOpen: true).then ({editor, point}) =>
      if editor.isAlive()
        @setRowMarker(editor, point)
        @focus()
        @preventSyncToProviderEditor = false

  isNormalItem: (item) ->
    item? and not item.skip

  needCloseOnConfirm: ->
    settings.get(@provider.getName() + "CloseOnConfirm")

  confirm: (options={}) ->
    item = @getSelectedItem()
    Promise.resolve(@provider.confirmed(item)).then ({editor, point}) =>
      if not options.keepOpen and @needCloseOnConfirm()
        @editor.destroy()
      {editor, point}

  # Return row
  findNormalItem: (startRow, direction) ->
    maxRow = @items.length - 1
    rows = if direction is 'next'
      [startRow..maxRow]
    else
      [startRow..0]

    for row in rows when @isNormalItem(@items[row])
      return row
    null

  moveToPromptOrSelectedItem: ->
    row = @getRowForSelectedItem()
    if (row is @editor.getCursorBufferPosition().row) or not (row >= 0)
      @moveToPrompt(startInsert: true)
    else
      # move to current item
      @editor.setCursorBufferPosition([row, 0])

  getRowForSelectedItem: ->
    @getRowForItem(@getSelectedItem())

  moveToPrompt: ({startInsert}={}) ->
    @withLock =>
      @editor.setCursorBufferPosition(@getPromptRange().end)
      @vmpActivateInsertMode() if startInsert and @vmpIsNormalMode()
      @emitDidMoveToPrompt()

  getRowForItem: (item) ->
    @items.indexOf(item)

  selectItem: (item) ->
    if (row = @getRowForItem(item)) >= 0
      @selectItemForRow(row)

  selectItemForRow: (row) ->
    item = @items[row]
    if @isNormalItem(item)
      @promptGutter.setToRow(row)
      @selectedItem = item

  getSelectedItem: ->
    @selectedItem

  getPromptRange: ->
    @editor.bufferRangeForBufferRow(0)

  # Return range
  setPrompt: (text='') ->
    if @editor.getLastBufferRow() is 0
      text += "\n"
    @ignoreChangeOnEditor = true
    range = @editor.setTextInBufferRange(@getPromptRange(0), text)
    @ignoreChangeOnEditor = false
    range

  bindToEditor: (editor) ->
    @editorSubcriptions?.dispose()
    @editorSubcriptions = new CompositeDisposable
    @editorSubcriptions.add atom.workspace.onDidStopChangingActivePaneItem (item) =>
      @syncToProviderEditor() if item is editor

    @editorSubcriptions.add editor.onDidStopChanging =>
      # Skip is not activeEditor, important to skip auto-refresh on direct-edit.
      @refresh(force: true) if isActiveEditor(editor)

    @editorSubcriptions.add editor.onDidChangeCursorPosition (event) =>
      if isActiveEditor(editor) and
          (not event.textChanged) and
          (event.oldBufferPosition.row isnt event.newBufferPosition.row)
        @syncToProviderEditor()

  # vim-mode-plus integration
  # -------------------------
  vmpActivateNormalMode: ->
    atom.commands.dispatch(@editorElement, 'vim-mode-plus:activate-normal-mode')

  vmpActivateInsertMode: ->
    atom.commands.dispatch(@editorElement, 'vim-mode-plus:activate-insert-mode')

  vmpIsInsertMode: ->
    @vmpIsEnabled() and @editorElement.classList.contains('insert-mode')

  vmpIsNormalMode: ->
    @vmpIsEnabled() and @editorElement.classList.contains('normal-mode')

  vmpIsEnabled: ->
    @editorElement.classList.contains('vim-mode-plus')
