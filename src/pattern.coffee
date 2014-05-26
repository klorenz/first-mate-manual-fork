_ = require 'underscore-plus'

AllDigitsRegex = /\\\d+/g
CustomCaptureIndexRegex = /\$(\d+)|\${(\d+):\/(downcase|upcase)}/
DigitRegex = /\\\d+/

module.exports =
class Pattern
  constructor: (@grammar, @registry, options={}) ->
    {name, contentName, match, begin, end, patterns} = options
    {captures, beginCaptures, endCaptures, applyEndPatternLast} = options
    {@include, @popRule, @hasBackReferences} = options

    @pushRule = null
    @backReferences = null
    @scopeName = name
    @contentScopeName = contentName

    if match
      if (end or @popRule) and @hasBackReferences ?= DigitRegex.test(match)
        @match = match
      else
        @regexSource = match
      @captures = captures
    else if begin
      @regexSource = begin
      @captures = beginCaptures ? captures
      endPattern = @grammar.createPattern({match: end, captures: endCaptures ? captures, popRule: true})
      @pushRule = @grammar.createRule({@scopeName, @contentScopeName, patterns, endPattern, applyEndPatternLast})

    if @captures?
      for group, capture of @captures
        if capture.patterns?.length > 0 and not capture.rule
          capture.scopeName = @scopeName
          capture.rule = @grammar.createRule(capture)

    @anchored = @hasAnchor()

  getRegex: (firstLine, position, anchorPosition) ->
    if @anchored
      @replaceAnchor(firstLine, position, anchorPosition)
    else
      @regexSource

  hasAnchor: ->
    return false unless @regexSource
    escape = false
    for character in @regexSource
      return true if escape and character in ['A', 'G', 'z']
      escape = not escape and character is '\\'
    false

  replaceAnchor: (firstLine, offset, anchor) ->
    escaped = []
    placeholder = '\uFFFF'
    escape = false
    for character in @regexSource
      if escape
        switch character
          when 'A'
            if firstLine
              escaped.push("\\#{character}")
            else
              escaped.push(placeholder)
          when 'G'
            if offset is anchor
              escaped.push("\\#{character}")
            else
              escaped.push(placeholder)
          when 'z'
            escaped.push('$(?!\n)(?<!\n)')
          else
            escaped.push("\\#{character}")
        escape = false
      else if character is '\\'
        escape = true
      else
        escaped.push(character)

    escaped.join('')

  resolveBackReferences: (line, beginCaptureIndices) ->
    beginCaptures = []

    for {start, end} in beginCaptureIndices
      beginCaptures.push line[start...end]

    resolvedMatch = @match.replace AllDigitsRegex, (match) ->
      index = parseInt(match[1..])
      if beginCaptures[index]?
        _.escapeRegExp(beginCaptures[index])
      else
        "\\#{index}"

    @grammar.createPattern({hasBackReferences: false, match: resolvedMatch, @captures, @popRule})

  ruleForInclude: (baseGrammar, name) ->
    if name[0] == "#"
      @grammar.getRepository()[name[1..]]
    else if name == "$self"
      @grammar.getInitialRule()
    else if name == "$base"
      baseGrammar.getInitialRule()
    else
      @grammar.addIncludedGrammarScope(name)
      @registry.grammarForScopeName(name)?.getInitialRule()

  getIncludedPatterns: (baseGrammar, included) ->
    if @include
      rule = @ruleForInclude(baseGrammar, @include)
      rule?.getIncludedPatterns(baseGrammar, included) ? []
    else
      [this]

  resolveScopeName: (scopeName, line, captureIndices) ->
    resolvedScopeName = scopeName.replace CustomCaptureIndexRegex, (match, index, commandIndex, command) ->
      capture = captureIndices[parseInt(index ? commandIndex)]
      if capture?
        replacement = line.substring(capture.start, capture.end)
        # Remove leading dots that would make the selector invalid
        replacement = replacement.substring(1) while replacement[0] is '.'
        switch command
          when 'downcase' then replacement.toLowerCase()
          when 'upcase'   then replacement.toUpperCase()
          else replacement
      else
        match

  handleMatch: (stack, line, captureIndices, rule, endPatternMatch) ->
    scopes = @grammar.scopesFromStack(stack, rule, endPatternMatch)
    if @scopeName and not @popRule
      scopes.push(@resolveScopeName(@scopeName, line, captureIndices))

    if @captures
      tokens = @getTokensForCaptureIndices(line, _.clone(captureIndices), captureIndices, scopes, stack)
    else
      {start, end} = captureIndices[0]
      zeroLengthMatch = end == start
      if zeroLengthMatch
        tokens = []
      else
        tokens = [@grammar.createToken(line[start...end], scopes)]
    if @pushRule
      ruleToPush = @pushRule.getRuleToPush(line, captureIndices)
      ruleToPush.anchorPosition = captureIndices[0].end
      stack.push(ruleToPush)
    else if @popRule
      stack.pop()

    tokens

  getTokensForCaptureRule: (rule, line, captureStart, captureEnd, scopes, stack) ->
    captureText = line.substring(captureStart, captureEnd)
    {tokens} = rule.grammar.tokenizeLine(captureText, [stack..., rule])
    tokens

  # Get the tokens for the capture indices.
  #
  # line - The string being tokenized.
  # currentCaptureIndices - The current array of capture indices being
  #                         processed into tokens. This method is called
  #                         recursively and this array will be modified inside
  #                         this method.
  # allCaptureIndices - The array of all capture indices, this array will not
  #                     be modified.
  # scopes - An array of scopes.
  # stack - An array of rules.
  #
  # Returns a non-null but possibly empty array of tokens
  getTokensForCaptureIndices: (line, currentCaptureIndices, allCaptureIndices, scopes, stack) ->
    parentCapture = currentCaptureIndices.shift()

    tokens = []
    if scope = @captures[parentCapture.index]?.name
      scopes = scopes.concat(@resolveScopeName(scope, line, allCaptureIndices))

    if captureRule = @captures[parentCapture.index]?.rule
      captureTokens = @getTokensForCaptureRule(captureRule, line, parentCapture.start, parentCapture.end, scopes, stack)
      tokens.push(captureTokens...)
      # Consume child captures
      while currentCaptureIndices.length and currentCaptureIndices[0].start < parentCapture.end
        currentCaptureIndices.shift()
    else
      previousChildCaptureEnd = parentCapture.start
      while currentCaptureIndices.length and currentCaptureIndices[0].start < parentCapture.end
        childCapture = currentCaptureIndices[0]

        emptyCapture = childCapture.end - childCapture.start == 0
        captureHasNoScope = not @captures[childCapture.index]
        if emptyCapture or captureHasNoScope
          currentCaptureIndices.shift()
          continue

        if childCapture.start > previousChildCaptureEnd
          tokens.push(@grammar.createToken(line[previousChildCaptureEnd...childCapture.start], scopes))

        captureTokens = @getTokensForCaptureIndices(line, currentCaptureIndices, allCaptureIndices, scopes, stack)
        tokens.push(captureTokens...)
        previousChildCaptureEnd = childCapture.end

      if parentCapture.end > previousChildCaptureEnd
        tokens.push(@grammar.createToken(line[previousChildCaptureEnd...parentCapture.end], scopes))

    tokens
