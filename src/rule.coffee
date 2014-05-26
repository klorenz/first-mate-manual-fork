_ = require 'underscore-plus'

Scanner = require './scanner'

module.exports =
class Rule
  constructor: (@grammar, @registry, {@scopeName, @contentScopeName, patterns, @endPattern, @applyEndPatternLast}={}) ->
    @patterns = []
    for pattern in patterns ? []
      @patterns.push(@grammar.createPattern(pattern)) unless pattern.disabled

    if @endPattern and not @endPattern.hasBackReferences
      if @applyEndPatternLast
        @patterns.push(@endPattern)
      else
        @patterns.unshift(@endPattern)

    @scannersByBaseGrammarName = {}
    @createEndPattern = null
    @anchorPosition = -1

  getIncludedPatterns: (baseGrammar, included=[]) ->
    return [] if _.include(included, this)

    included = included.concat([this])
    allPatterns = []
    for pattern in @patterns
      allPatterns.push(pattern.getIncludedPatterns(baseGrammar, included)...)
    allPatterns

  clearAnchorPosition: -> @anchorPosition = -1

  getScanner: (baseGrammar) ->
    return scanner if scanner = @scannersByBaseGrammarName[baseGrammar.name]

    patterns = @getIncludedPatterns(baseGrammar)
    scanner = new Scanner(patterns)
    @scannersByBaseGrammarName[baseGrammar.name] = scanner
    scanner

  scanInjections: (ruleStack, line, position, firstLine) ->
    baseGrammar = ruleStack[0].grammar
    if injections = baseGrammar.injections
      for scanner in injections.getScanners(ruleStack)
        result = scanner.findNextMatch(line, firstLine, position, @anchorPosition)
        return result if result?

  normalizeCaptureIndices: (line, captureIndices) ->
    lineLength = line.length
    for capture in captureIndices
      capture.end = Math.min(capture.end, lineLength)
      capture.start = Math.min(capture.start, lineLength)

  findNextMatch: (ruleStack, line, position, firstLine) ->
    lineWithNewline = "#{line}\n"
    baseGrammar = ruleStack[0].grammar
    results = []

    scanner = @getScanner(baseGrammar)
    if result = scanner.findNextMatch(lineWithNewline, firstLine, position, @anchorPosition)
      results.push(result)

    if result = @scanInjections(ruleStack, lineWithNewline, position, firstLine)
      results.push(result)

    scopes = null
    for injectionGrammar in @registry.injectionGrammars
      continue if injectionGrammar is @grammar
      continue if injectionGrammar is baseGrammar
      scopes ?= @grammar.scopesFromStack(ruleStack)
      if injectionGrammar.injectionSelector.matches(scopes)
        scanner = injectionGrammar.getInitialRule().getScanner(injectionGrammar, position, firstLine)
        if result = scanner.findNextMatch(lineWithNewline, firstLine, position, @anchorPosition)
          results.push(result)

    if results.length > 1
      _.min results, (result) =>
        @normalizeCaptureIndices(line, result.captureIndices)
        result.captureIndices[0].start
    else if results.length is 1
      [result] = results
      @normalizeCaptureIndices(line, result.captureIndices)
      result

  getNextTokens: (ruleStack, line, position, firstLine) ->
    result = @findNextMatch(ruleStack, line, position, firstLine)
    return null unless result?

    {index, captureIndices, scanner} = result
    [firstCapture] = captureIndices
    endPatternMatch = @endPattern is scanner.patterns[index]
    nextTokens = scanner.handleMatch(result, ruleStack, line, this, endPatternMatch)
    {nextTokens, tokensStartPosition: firstCapture.start, tokensEndPosition: firstCapture.end}

  getRuleToPush: (line, beginPatternCaptureIndices) ->
    if @endPattern.hasBackReferences
      rule = @grammar.createRule({@scopeName, @contentScopeName})
      rule.endPattern = @endPattern.resolveBackReferences(line, beginPatternCaptureIndices)
      rule.patterns = [rule.endPattern, @patterns...]
      rule
    else
      this
