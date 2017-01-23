_ = require 'underscore-plus'
{Point} = require 'atom'
SearchBase = require './search-base'

module.exports =
class AtomScan extends SearchBase
  indentTextForLineHeader: "  "

  getItems: ->
    if @items?
      @items
    else
      resultsByFilePath = {}

      source = _.escapeRegExp(@options.search)
      if @options.wordOnly
        regexp = ///\b#{source}\b///i
      else
        regexp = ///#{source}///i

      scanPromise = atom.workspace.scan regexp, (result) ->
        if result?.matches?.length
          (resultsByFilePath[result.filePath] ?= []).push(result.matches...)

      scanPromise.then =>
        items = []
        for filePath, results of resultsByFilePath
          header = "# #{filePath}"
          items.push({header, filePath, skip: true})
          rows = []
          for item in results
            filePath = filePath
            text = item.lineText
            point = Point.fromObject(item.range[0])
            if point.row not in rows
              rows.push(point.row) # ensure single item per row
              items.push({filePath, text, point})

        @injectMaxLineTextWidth(items)
        @items = items

  filterItems: (items, regexps) ->
    filterKey = @getFilterKey()
    for regexp in regexps
      items = items.filter (item) ->
        item.skip or regexp.test(item[filterKey])
    items

    normalItems = _.filter(items, (item) -> not item.skip)
    filePaths = _.uniq(_.pluck(normalItems, "filePath"))

    _.filter items, (item) ->
      if item.header?
        item.filePath in filePaths
      else
        true