## Player-side Claude authoring, GWL reply parsing, and training prompts.
## The game sends each private observation through the ordinary player socket.
##
## Credentials, in order of preference:
##   COWORLD_LLM_ENDPOINT            - hosted sidecar
##   Bedrock bearer token            - local play
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no player credential the bundled prompt policy fails the turn with an
## infrastructure error instead of substituting a fallback warrior.

import
  std/[json, os, strutils, unicode],
  bitworld/runtime,
  curly,
  sim, prompts

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  WarriorDir = currentSourcePath().parentDir().parentDir().parentDir() /
    "data" / "warriors"
  PainterSource* = staticRead(WarriorDir / "painter.gwl")
  BomberSource* = staticRead(WarriorDir / "bomber.gwl")
  SentrySource* = staticRead(WarriorDir / "sentry.gwl")

type
  ScriptKind* = enum
    skNone = "none"
    skPainter = "painter"
    skBomber = "bomber"
    skSentry = "sentry"

  LlmInfraError* = object of GridWarsError
    ## Raised when credentials, transport, or the upstream provider fail
    ## (as opposed to a model-generated invalid or uncompilable action).

  Submission* = object
    script*: seq[string]
    notes*: string      ## "" when the reply carried none
    banner*: string
    origin*: string     ## "llm" | "player" | "scripted"

  LlmTransport = enum
    ltNone, ltSidecar, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string
    sidecarEndpoint: string
    bedrockEndpoint: string
    bedrockModel: string
    bedrockToken: string
    model: string
    maxOutputTokens: int
    disabled*: bool       ## true once credentials are known-unavailable

proc parseScriptKind*(text: string): ScriptKind =
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "painter": skPainter
  of "bomber": skBomber
  of "sentry": skSentry
  else: skNone

proc warriorLines*(kind: ScriptKind): seq[string] =
  let source =
    case kind
    of skBomber: BomberSource
    of skSentry, skNone: SentrySource
    else: PainterSource
  for line in source.splitLines():
    result.add(line)
  while result.len > 0 and result[^1].strip().len == 0:
    discard result.pop()

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "grid-wars llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelId(): string =
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return pinned
  "us.anthropic.claude-haiku-4-5-20251001-v1:0"

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" & client.bedrockModel & "/invoke"

proc newLlmClient*(maxOutputTokens: int, model: string): LlmClient =
  result = LlmClient(model: model, maxOutputTokens: maxOutputTokens)
  let sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip()
  if sidecarEndpoint.len > 0:
    result.transport = ltSidecar
    result.sidecarEndpoint = sidecarEndpoint.strip(chars = {'/'}, leading = false)
    result.model = getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
    result.curl = newCurly()
    return
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModel = bedrockModelId()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "grid-wars llm: bedrock transport, model ",
      result.bedrockModel, ", url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "grid-wars llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "grid-wars llm: no LLM credentials; prompt turns will fail"

# ---- Scripted baselines -----------------------------------------------------

proc cleanText*(text: string, limit: int): string =
  ## Text over the cap is cut at a RUNE boundary with the cut marked, by
  ## the one shared truncation (`cutRunes`, gwl.nim): a byte slice through
  ## a multi-byte character leaves invalid UTF-8 in the replay.
  cutRunes(text.strip(), limit)


proc scriptedSubmission*(kind: ScriptKind): Submission =
  ## A scripted seat submits the SAME fixed warrior every round and never
  ## calls the model.
  Submission(
    script: warriorLines(if kind == skNone: skSentry else: kind),
    origin: "scripted"
  )

proc submissionJson*(submission: Submission): JsonNode =
  ## Complete normal player action, including the source lines.
  %*{"script": submission.script, "notes": submission.notes,
    "banner": submission.banner}

# ---- Prompts ----------------------------------------------------------------

const GwlReference* = """
GWL — the warrior language

A warrior is a program. It runs from the top; wrap your behaviour in
`while true:` or it will run off the end, stop acting and die to the idle
rule. Indentation is 2 spaces per level and is significant. `#` starts a
comment. INTEGERS ONLY — there are no floats, no strings, no tables.

STATEMENTS
  var NAME = EXPR            declare and initialise
  NAME = EXPR                assign
  NAME[EXPR] = EXPR          assign into an array
  if EXPR: / elif EXPR: / else:    with an indented block
  while EXPR:                with break and continue
  for NAME in A ..< B:       also `A .. B` and `for NAME in ARRAY:`
  proc NAME(p1, p2) =        globals visible, parameters by value
  return EXPR                or bare `return`
  discard EXPR               evaluate and drop
  move(dx, dy)  place()  bomb()  wait()      ACTIONS — each ENDS your tick

EXPRESSIONS
  integers, true/false, names, [a, b, c], a[i], calls, ( ), unary - and not,
  and infix  *  div  mod  +  -  ==  !=  <  <=  >  >=  and  or
  with Nim's precedence. `and`/`or` short-circuit. Booleans are a distinct
  type: `if 1:` is a fault. `div`/`mod` also exist as calls: `mod(a, b)`.

BUILTINS
  check(dx, dy)  BOMB (-1) live bomb, CORPSE (-2) corpse, FOG (-3) outside
                 the 9x9 window around you, else the tile owner 1..4 or
                 EMPTY (0)
  who(dx, dy)    the id 1..4 of the LIVING warrior standing there, else 0;
                 FOG outside the window
  x()  y()       your coordinates, 0..29
  tiles()  energy()  tick()
  alive(id)      1 if warrior id is alive, else 0
  rand(n)        0..n-1 from your own seeded stream; n <= 0 is a fault
  abs(a)  min(a,b)  max(a,b)  len(a)  xor(a,b)  shl(a,b)  shr(a,b)

CONSTANTS
  BOMB -1, CORPSE -2, FOG -3, EMPTY 0, ID (your warrior id), gridSize 30,
  MAXFUSE 5, BOMBCOST (the energy a bomb costs this episode)

ACTIONS
  move(dx, dy) is ONE STEP: dx and dy are each -1, 0 or 1 and not both 0.
  Any other offset is an ILLEGAL action: the tick is spent and nothing
  happens. place() claims the cell you stand on. bomb() plants a bomb on
  the cell you stand on; it is refused if you cannot afford it or a bomb is
  already there. wait() does nothing. Executing an action SUSPENDS your
  program there; next tick it resumes on the next line.

LIMITS
  at most 120 lines, 4000 characters, 4000 AST
  nodes, 32 procs, blocks nested 8 deep; at most 2000 VM instructions per
  tick (running out is a STALL: the tick counts as wait() and you resume
  where you were), call depth 64, 4096 live array elements.

FAULTS kill your warrior on the spot, with the line number reported back to
you: divide or modulo by zero, an array index out of range, an undefined
variable or proc, a wrong argument count, a type mismatch, call depth
exceeded, the allocation limit, rand(n <= 0), integer overflow. An illegal
move, a refused bomb, a blocked move and a stall are NOT faults.
"""

const TickOrder* = """
TICK RESOLUTION ORDER, every tick:
  1. Priority rotates: seats (0+t) mod 4, (1+t) mod 4, ... — no seat has a
     structural first-mover advantage; all ties resolve in that order.
  2. Decision pass. Every living warrior runs until it reaches an action or
     spends its instruction budget. THE BOARD IS NOT MUTATED IN THIS PASS:
     every check/who in tick t reads the board as it stood at the end of
     tick t-1, for everyone.
  3. Bomb pass, 4. Place pass, 5. Move pass — in priority order. A move is
     BLOCKED (you stay put) by a live bomb, a corpse, or a living warrior,
     including one that moved there earlier in this same pass.
  6. Fuses tick down. 7. Bombs at fuse 0 detonate: the bomb's cell plus its
     four orthogonal neighbours, wrapping. Every blast cell is SCORCHED
     (its owner reset, its bomb consumed) and every warrior in it dies.
     Bombs caught in a blast join the same wave — chain reactions resolve
     to closure.
  8. Idle: 50 ticks without changing cell kills you.
  9. Faults kill.
 10. A dead warrior's tiles all revert to unclaimed, immediately.
     Survivors gain 1 + tiles div 60 energy, capped at 60.
 11. The round ends at the tick horizon, or when one warrior is left, or
     when none is.
"""

proc systemPrompt*(sim: Sim, seat: int, selection: PromptSelection): string =
  result.add(selection.trainingIntroduction(sim.names[seat] & ", warrior id " & $(seat + 1) &
    " (" & ColorNames[seat] & ")") & "\n\n")
  result.add(selection.rulesBriefing())
  result.add("\n" & TickOrder & "\n" & GwlReference & "\n")
  result.add("""
OUTPUT FORMAT: reply with ONLY one JSON object, nothing else — no analysis,
no explanation, no markdown fences, no text before or after the object.
Your reply must begin with the character { and end with }. "script" must be
an ARRAY OF LINES (each element one source line, indentation preserved as
leading spaces). Keep scripts compact (~15-50 lines) and notes concise (1-2
sentences) so your JSON reply never truncates; hard caps are 120 lines and 4000 source characters, 600-character notes, and 80-character banner. Your
program must be a complete warrior: wrap behaviour in `while true:` so it
does not run off the end and die to the idle rule.

  {"script": ["var dx = 1", "var dy = 0", "while true:", "  place()",
   "  move(dx, dy)"],
   "notes": "private reminder for next round",
   "banner": "one line spectators see"}
""")

proc operatorBlock*(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  result.add(sim.seatObservation(seat))
  result.add(operatorBlock(prompt))
  result.add("Reply with ONLY {\"script\": [\"line\", \"line\", ...], " &
    "\"notes\": \"…\", \"banner\": \"…\"}. Keep scripts compact (~15-50 " &
    "lines) and notes brief (1-2 sentences) so your JSON never truncates " &
    "(hard caps: " & $MaxScriptLines & " lines of " & $MaxLineChars &
    " characters, notes " & $MaxNotesLen & " characters, banner " &
    $MaxBannerLen & " characters).")

# ---- Reply parsing ----------------------------------------------------------

proc stripOuterFence(text: string): string =
  ## Drops a leading UTF-8 BOM and at most one ordinary outer Markdown code
  ## fence (plain or `json`-tagged). Rejects unsupported fence tags or text
  ## outside the fence.
  result = strutils.strip(text)
  if result.len >= 3 and result[0 .. 2] == "\xEF\xBB\xBF":
    result = strutils.strip(result[3 .. ^1])
  if result.startsWith("```"):
    let firstBreak = result.find('\n')
    if firstBreak < 0:
      raise newException(GridWarsError,
        "unterminated markdown fence in response")
    let tag = result[3 ..< firstBreak].strip().toLowerAscii()
    if tag.len > 0 and tag != "json":
      raise newException(GridWarsError,
        "unsupported markdown fence language tag: " & tag)
    let body = result[firstBreak + 1 .. ^1]
    if not body.endsWith("```"):
      raise newException(GridWarsError,
        "trailing text after closing markdown fence")
    let inner = body[0 ..< body.len - 3]
    let beforeClose = inner.strip(leading = false, chars = {' ', '\t', '\r'})
    if beforeClose.len > 0 and beforeClose[^1] != '\n':
      raise newException(GridWarsError,
        "closing markdown fence must be on its own line")
    result = inner.strip()

proc extractJsonObject*(text: string): JsonNode =
  ## Parses exactly one JSON object, bare or inside a single ordinary outer
  ## Markdown code fence (JSON-tagged or plain). Rejects surrounding prose,
  ## extra JSON objects, and non-object JSON values.
  let cleaned = stripOuterFence(text)
  if cleaned.len == 0:
    raise newException(GridWarsError, "empty JSON response")
  try:
    result = parseJson(cleaned)
  except JsonParsingError:
    let head = cutRunes(cleaned.replace("\n", " "), 160)
    raise newException(GridWarsError,
      "invalid JSON object in response: " & head)
  if result.kind != JObject:
    raise newException(GridWarsError, "response JSON must be an object")

proc normaliseScript*(node: JsonNode): seq[string] =
  ## Validates the canonical array-of-lines `script` field.
  if node.isNil or node.kind == JNull:
    raise newException(GridWarsError, "no script in response")
  if node.kind != JArray:
    raise newException(GridWarsError,
      "script must be an array of source lines")
  for item in node:
    if item.kind != JString:
      raise newException(GridWarsError,
        "script must be an array of source lines")
    let line = item.getStr()
    if '\n' in line:
      raise newException(GridWarsError,
        "script array elements must be single source lines")
    var text = line.replace("\t", "  ").replace("\r", "")
    while text.len > 0 and text[^1] == ' ':
      text.setLen(text.len - 1)
    result.add(text)
  while result.len > 0 and result[^1].strip().len == 0:
    discard result.pop()
  if result.len == 0:
    raise newException(GridWarsError, "the script is empty")

proc parseSubmission*(payload: JsonNode): Submission =
  if payload.isNil or payload.kind != JObject:
    raise newException(GridWarsError, "submission action must be a JSON object")
  for key, _ in payload.pairs:
    if key notin ["script", "notes", "banner"]:
      raise newException(GridWarsError, "unexpected submission field: " & key)
  if payload.hasKey("notes"):
    if payload["notes"].kind != JString:
      raise newException(GridWarsError, "notes must be a string")
    let notes = payload["notes"].getStr().strip()
    if notes.runeLen > MaxNotesLen:
      raise newException(GridWarsError,
        "notes exceeds maximum length of " & $MaxNotesLen & " characters")
    result.notes = notes
  if payload.hasKey("banner"):
    if payload["banner"].kind != JString:
      raise newException(GridWarsError, "banner must be a string")
    let rawBanner = payload["banner"].getStr()
    if '\n' in rawBanner or '\r' in rawBanner:
      raise newException(GridWarsError, "banner must be a single line")
    let banner = rawBanner.strip()
    if banner.runeLen > MaxBannerLen:
      raise newException(GridWarsError,
        "banner exceeds maximum length of " & $MaxBannerLen & " characters")
    result.banner = banner
  result.script = normaliseScript(payload{"script"})
  result.origin = "llm"
  discard compile(result.script)

# ---- Transport --------------------------------------------------------------

proc requestFor(client: LlmClient, system, user: string, slot: int):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  if client.transport == ltSidecar and slot >= 0:
    headers["X-Coworld-Player-Slot"] = $slot
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  elif client.transport == ltSidecar:
    body["model"] = %client.model
    headers["anthropic-version"] = AnthropicVersion
    result.url = client.sidecarEndpoint & "/v1/messages"
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string): string =
  if error.len > 0:
    raise newException(LlmInfraError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = cutRunes(response.body, 400)
    client.disabled = true
    raise newException(LlmInfraError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = cutRunes(response.body, 300)
    raise newException(LlmInfraError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LlmInfraError, "provider error " & $response.code &
      ": " & cutRunes(response.body, 300))
  var payload: JsonNode
  try:
    payload = parseJson(response.body)
  except CatchableError as err:
    raise newException(LlmInfraError,
      "provider returned invalid JSON: " & err.msg)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(GridWarsError, "model refusal")
  if not payload.hasKey("content") or payload["content"].kind != JArray:
    raise newException(LlmInfraError, "provider response missing content array")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(GridWarsError, "reply cut off at max_tokens before " &
      "any JSON: " & cutRunes(result, 160).replace("\n", " "))

proc nativeSystemPrompt*(selection: PromptSelection): string =
  selection.nativeIntroduction() & " " &
    "Survive, claim territory, and use the visible rules below. Reply only " &
    "with JSON containing script as an array of lines, notes, and banner.\n\n" &
    selection.rulesBriefing() & "\n" & TickOrder & "\n" & GwlReference

const OrdinaryReference = staticRead("../../docs/warrior-language.md")

proc ordinarySystemPrompt*(selection: PromptSelection): string =
  selection.ordinaryIntroduction() & "\n\n" & selection.rulesBriefing() & "\n" &
    OrdinaryReference

proc choosePromptSubmission*(client: LlmClient, observation, prompt: string,
    timeoutSeconds, slot: int, selection: PromptSelection): Submission =
  let system = selection.nativeSystemPrompt()
  let user = observation & "\n" & operatorBlock(prompt) &
    "\nReply with ONLY {\"script\": [\"GWL line\", ...], " &
    "\"notes\": \"\", \"banner\": \"\"}. Keep scripts compact (~15-50 lines) " &
    "and notes brief so your JSON never truncates; loop with `while true:` " &
    "and compile under the GWL rules."
  var request = client.requestFor(system, user, -1)
  if client.transport == ltSidecar:
    request.headers["x-coworld-player-slot"] = $slot
  var response: Response
  try:
    response = client.curl.post(request.url, request.headers, request.body,
      timeoutSeconds)
  except CatchableError as err:
    raise newException(LlmInfraError, "llm transport: " & err.msg)
  parseSubmission(extractJsonObject(client.textOf(response, "", request.url)))
