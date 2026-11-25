## Grid Wars game server: implements the Coworld game contract.
##
## Endpoints:
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page (view only)
##   GET /client/renderer.js         - shared arena renderer
##   GET /client/chrome.css          - shared chrome
##   GET /client/assets/<name>       - sprites and fonts
##   WS  /player?slot=N&token=T      - player protocol
##   WS  /global                     - spectator snapshots
##
## There is NO replay route and no replay mode: a recorded episode is played
## by the STATIC wasm bundle the manifest declares
## (`game.replay_viewer.bundle`), which reads the `.replay` file from S3 and
## re-derives every frame in the browser. This server never serves a replay.
##
## Every route is registered BEFORE any catch-all asset route, because
## hosted certification probes /healthz, GET /client/player?slot=0&token=T,
## a bad-token player websocket and GET /client/global before the player
## pods start.
##
## Player protocol (gridwars.player.v3), all JSON text frames:
##   game -> player: {"type":"welcome","protocol":"gridwars.player.v3",...}
##                   {"type":"state",...} redacted to this seat
##                   {"type":"final","scores":[...],...} (or {"type":"final","done":true,"failed":true,"failure":{...}} on abort)
##   game -> player: {"type":"turn","round":N,"observation":str,
##                   "timeout_ms":N}
##   player -> game: {"type":"submission","round":N,"action":{...}}
##                   {"type":"error","round":N,"category":"infrastructure|model_action","kind":str,"reason":str}

import
  std/[json, locks, os, sets, strutils, tables, times],
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  llm, prompts,
  sim

const
  ReplayVersion = 1
  ShutdownGraceSeconds = 20
  RoundReserveSeconds* = 150.0
    ## Checked BEFORE every submission batch. In the pathological case
    ## where player connect ate its whole cap, round 4 or 5 is given up
    ## rather than the entire episode.
  PlayBudgetFraction* = 0.6
    ## Share of the platform's episode timeout spent playing. The rest
    ## covers container start, player connects, and writing the artifacts.

type
  EpisodeFailure = object
    active: bool
    failureClass: string  ## "infrastructure" | "model_action"
    kind: string
    seat: int
    round: int
    reason: string
    rejectedAction: JsonNode

  GameState = object
    selection: PromptSelection
    config: GameConfig
    sim: Sim
    pendingRound: int
    pendingSubmissions: Table[int, Submission]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    failure: EpisodeFailure
    started: bool
    finished: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc policyNamesJson(gs: GameState): JsonNode =
  ## Seats play under anonymous cog aliases; the policy names ride
  ## alongside for the SPECTATOR views only, which render them in place of
  ## the aliases. No prompt ever contains a policy name.
  result = newJArray()
  for player in gs.config.players:
    result.add(%player.name)

proc snapshotJson(gs: GameState): JsonNode =
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  var connected = newJArray()
  for slot in 0 ..< gs.config.tokens.len:
    connected.add(%gs.playerSockets.hasKey(slot))
  result = gs.sim.liveStateJson()
  result["type"] = %"state"
  result["game"] = %"grid-wars"
  result["policyNames"] = gs.policyNamesJson()
  result["events"] = events
  result["started"] = %gs.started
  result["done"] = %gs.sim.done
  result["connected"] = connected

proc broadcastLocked(gs: GameState) =
  ## Callers hold stateLock. Spectators get the whole board; players get
  ## the redacted per-seat state — never another seat's source.
  let payload = $gs.snapshotJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    socket.send($gs.sim.playerStateJson(slot))

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc replayPayload(gs: GameState, results: JsonNode): string =
  var payload = gs.sim.replayJson()
  payload["results"] = results
  $payload

proc recordFailureLocked(gs: var GameState, failureClass, kind: string,
    seat, round: int, reason: string, rejectedAction: JsonNode = nil) =
  ## Callers hold stateLock. Records the first fatal failure that terminates
  ## an unfinished episode unscored.
  if gs.failure.active:
    return
  gs.failure = EpisodeFailure(
    active: true,
    failureClass: failureClass,
    kind: kind,
    seat: seat,
    round: round,
    reason: cleanText(reason, 400),
    rejectedAction: rejectedAction
  )

proc failureJson(gs: GameState): JsonNode =
  let playerName =
    if gs.failure.seat >= 0 and gs.failure.seat < gs.config.players.len:
      gs.config.players[gs.failure.seat].name
    else: ""
  result = %*{
    "failed": true,
    "failure_class": gs.failure.failureClass,
    "kind": gs.failure.kind,
    "seat": gs.failure.seat,
    "player": playerName,
    "round": gs.failure.round,
    "rounds_played": gs.sim.roundsPlayed,
    "reason": gs.failure.reason
  }
  if not gs.failure.rejectedAction.isNil:
    result["rejected_action"] = gs.failure.rejectedAction

proc abortEpisode(runtimeConfig: RuntimeConfig) =
  ## Terminates an unfinished episode cleanly without authoritative gameplay
  ## scores or winner, recording the failure cause to COGAME_PLAYER_FAILURE_URI.
  var failurePayload: JsonNode
  var replayData: string
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    failurePayload = state.failureJson()
    var replayObj = state.sim.replayJson()
    replayObj.delete("results")
    replayObj["failure"] = failurePayload
    replayData = $replayObj

    let finalFrame = %*{
      "type": "final",
      "done": true,
      "failed": true,
      "reason": state.failure.kind,
      "failure": failurePayload
    }
    for slot, socket in state.playerSockets:
      var msg = copy(finalFrame)
      msg["slot"] = %slot
      try:
        socket.send($msg)
      except CatchableError:
        discard
    state.broadcastLocked()

  sleep(300)
  echo "grid-wars: aborting unfinished episode (",
    failurePayload["failure_class"].getStr(), "/",
    failurePayload["kind"].getStr(), "): ",
    failurePayload["reason"].getStr()
  let failureUri = getEnv("COGAME_PLAYER_FAILURE_URI").strip()
  if failureUri.len > 0:
    writeArtifact(failureUri, $failurePayload, "application/json",
      "COGAME_PLAYER_FAILURE_METHOD")
  if runtimeConfig.replayUri.len > 0:
    writeArtifact(runtimeConfig.replayUri, replayData,
      "application/octet-stream", "COGAME_SAVE_REPLAY_METHOD")
  quit(1)

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    results = state.sim.resultsJson()
    replayData = state.replayPayload(results)

    ## Send final frames to players BEFORE writing artifacts: the hosted
    ## worker tears player pods down as soon as results.json exists.
    ## Results carry POLICY names for the platform; the player frame gets
    ## the table aliases instead.
    var aliasNames = newJArray()
    for name in state.sim.names:
      aliasNames.add(%name)
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "tiles": results["tiles"],
      "roundsWon": results["roundsWon"],
      "names": aliasNames,
      "rounds": results["rounds"],
      "reason": results["reason"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  sleep(500)
  echo "grid-wars: writing results and replay"
  writeArtifact(runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD")
  writeArtifact(runtimeConfig.replayUri, replayData,
    "application/octet-stream", "COGAME_SAVE_REPLAY_METHOD")
  ## The certifier pings /global with a 2 s deadline AFTER the player pods
  ## start, and a fast scripted episode would otherwise already be gone.
  echo "grid-wars: artifacts written; serving for ", ShutdownGraceSeconds,
    "s more"
  sleep(ShutdownGraceSeconds * 1000)
  echo "grid-wars: episode complete, shutting down"
  quit(0)

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let connectDeadline = gameStart + config.playerConnectTimeoutSeconds

    while epochTime() < connectDeadline:
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
      if allConnected:
        break
      sleep(200)

    var missingSeat = -1
    withLock stateLock:
      state.started = true
      echo "grid-wars: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      if state.playerSockets.len < config.tokens.len:
        for seat in 0 ..< config.tokens.len:
          if not state.playerSockets.hasKey(seat):
            missingSeat = seat
            break
        state.recordFailureLocked("infrastructure", "player_connect_timeout",
          missingSeat, 0,
          "seat " & $missingSeat & " failed to connect before timeout")
      state.broadcastLocked()
    if missingSeat >= 0:
      abortEpisode(runtimeConfig)

    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    if playDeadline > 0.0:
      echo "grid-wars: episode timeout ", timeoutSeconds.int, "s (",
        (if hostedTimeout.len > 0: "from env" else: "assumed"),
        "); playing until ", (timeoutSeconds * PlayBudgetFraction).int, "s"

    while true:
      var seats: seq[int]
      var currentRound = 0
      var shouldAbort = false
      withLock stateLock:
        if state.sim.done:
          break
        if playDeadline > 0.0 and
            epochTime() + RoundReserveSeconds > playDeadline:
          if state.sim.roundsPlayed == 0:
            state.recordFailureLocked("infrastructure", "episode_timeout",
              -1, state.sim.round,
              "episode deadline reached before any round completed")
            shouldAbort = true
          else:
            echo "grid-wars: episode deadline reached after ",
              state.sim.roundsPlayed, "/", config.rounds,
              " rounds; ending early"
            state.sim.endEarly()
            state.broadcastLocked()
            break
        if not shouldAbort:
          seats = state.sim.pendingSeats()
          currentRound = state.sim.round
          echo "grid-wars: round ", state.sim.round, " of ", config.rounds,
            " at ", (epochTime() - gameStart).int, "s"
      if shouldAbort:
        abortEpisode(runtimeConfig)

      let decisionDeadline = epochTime() +
        config.actionTimeoutSeconds.float
      var waitingSeats: seq[int]
      withLock stateLock:
        state.pendingRound = currentRound
        state.pendingSubmissions.clear()
        for seat in seats:
          if state.playerSockets.hasKey(seat):
            state.playerSockets[seat].send($ %*{
              "type": "turn",
              "round": currentRound,
              "timeout_ms": config.actionTimeoutSeconds * 1000,
              "observation": state.sim.seatObservation(seat),
              "prompt_config": {"promptVariant": $state.selection.variant, "promptSeed": state.selection.seed},
              "prompt_selection": state.selection.selectionMetadata(),
              "system": state.selection.ordinarySystemPrompt()
            })
            waitingSeats.add(seat)
          else:
            state.recordFailureLocked("infrastructure", "player_disconnected",
              seat, currentRound,
              "seat " & $seat & " disconnected before round " & $currentRound)
            shouldAbort = true
            break
      if shouldAbort:
        abortEpisode(runtimeConfig)

      while waitingSeats.len > 0 and epochTime() < decisionDeadline:
        var resolved = 0
        var failedNow = false
        withLock stateLock:
          if state.failure.active:
            failedNow = true
          else:
            for seat in waitingSeats:
              if state.pendingSubmissions.hasKey(seat):
                resolved.inc
              elif not state.playerSockets.hasKey(seat):
                state.recordFailureLocked("infrastructure",
                  "player_disconnected", seat, currentRound,
                  "seat " & $seat & " disconnected during round " &
                  $currentRound)
                failedNow = true
                break
        if failedNow or resolved == waitingSeats.len:
          break
        sleep(20)

      var decisions = newSeq[Submission](seats.len)
      withLock stateLock:
        if not state.failure.active:
          for index, seat in seats:
            if state.pendingSubmissions.hasKey(seat):
              decisions[index] = state.pendingSubmissions[seat]
            else:
              let kind =
                if state.playerSockets.hasKey(seat): "submission_timeout"
                else: "player_disconnected"
              let reason =
                if state.playerSockets.hasKey(seat):
                  "seat " & $seat & " submission timed out in round " &
                  $currentRound
                else:
                  "seat " & $seat & " disconnected in round " & $currentRound
              state.recordFailureLocked("infrastructure", kind, seat,
                currentRound, reason)
              break
        state.pendingRound = -1
        if state.failure.active:
          shouldAbort = true
          if state.failure.seat >= 0 and
              state.playerSockets.hasKey(state.failure.seat):
            try:
              state.playerSockets[state.failure.seat].send($ %*{
                "type": "submission_result",
                "round": currentRound,
                "accepted": false,
                "error": state.failure.reason
              })
            except CatchableError:
              discard
      if shouldAbort:
        abortEpisode(runtimeConfig)

      withLock stateLock:
        for index, seat in seats:
          let decision = decisions[index]
          echo "grid-wars: round ", state.sim.round, " ",
            state.sim.names[seat], " submits ", decision.script.len,
            " lines (", decision.origin, ") at ",
            (epochTime() - gameStart).int, "s"
          try:
            state.sim.submit(seat, decision.script, decision.notes,
              decision.banner, decision.origin)
          except GridWarsError as error:
            state.recordFailureLocked("model_action", "invalid_action", seat,
              currentRound, error.msg, submissionJson(decision))
            shouldAbort = true
            break
        if not shouldAbort:
          state.broadcastLocked()
          for index, seat in seats:
            if state.playerSockets.hasKey(seat):
              let ack = %*{
                "type": "submission_result",
                "round": currentRound,
                "accepted": true,
                "action": submissionJson(decisions[index])
              }
              state.playerSockets[seat].send($ack)
      if shouldAbort:
        abortEpisode(runtimeConfig)

      if not state.sim.done and config.roundDelayMs > 0:
        sleep(config.roundDelayMs)

    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".png"): "image/png"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, dataDir() / name, contentType)

proc rendererHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "renderer.js",
      "application/javascript; charset=utf-8")

proc chromeCssHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "chrome.css", "text/css; charset=utf-8")

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "grid-wars: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "gridwars.player.v3",
        "slot": slot,
        "name": state.sim.names[slot],
        "id": slot + 1,
        "rounds": state.config.rounds,
        "ticks": state.config.ticks
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.snapshotJson())

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering
      ## them itself; the platform's certifier pings /global to check the
      ## game is alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "submission":
          let round = payload["round"].getInt()
          withLock stateLock:
            if round == state.pendingRound and
                not state.pendingSubmissions.hasKey(slot) and
                not state.failure.active:
              let action = payload{"action"}
              try:
                if action.isNil or action.kind != JObject:
                  raise newException(GridWarsError,
                    "submission action must be an object")
                let source = payload{"source"}.getStr("player")
                if source notin ["player", "scripted"]:
                  raise newException(GridWarsError,
                    "unknown submission source: " & source)
                var submission = parseSubmission(action)
                submission.origin = source
                state.pendingSubmissions[slot] = submission
              except GwlCompileError as error:
                echo "grid-wars: seat ", slot, " submission compile error: ", error.msg
                state.recordFailureLocked("model_action", "compile_error",
                  slot, round, error.msg, action)
              except CatchableError as error:
                echo "grid-wars: seat ", slot, " submission rejected: ", error.msg
                state.recordFailureLocked("model_action", "invalid_action",
                  slot, round, error.msg, action)
        of "error":
          let round = payload{"round"}.getInt(state.pendingRound)
          let rawCategory = payload{"category"}.getStr("infrastructure")
          let category =
            if rawCategory in ["infrastructure", "model_action"]: rawCategory
            else: "infrastructure"
          let kind = payload{"kind"}.getStr("player_error")
          let reason = payload{"reason"}.getStr("player reported error")
          withLock stateLock:
            if not state.failure.active:
              echo "grid-wars: seat ", slot, " reported ", category, "/",
                kind, " in round ", round, ": ", reason
              state.recordFailureLocked(category, kind, slot, round, reason)
        else:
          discard
      except CatchableError as error:
        echo "grid-wars: bad player frame from seat ", slot, ": ", error.msg
        withLock stateLock:
          if state.pendingRound >= 0 and not state.failure.active:
            state.recordFailureLocked("model_action", "protocol_error",
              slot, state.pendingRound, "malformed player frame: " & error.msg)
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)

proc buildRouter(): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/renderer.js", rendererHandler)
  result.get("/client/chrome.css", chromeCssHandler)
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/player", playerUpgradeHandler)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(GridWarsError, "tokens and players must align")
  state.config = config
  state.selection = promptSelection(if runtimeConfig.config.len > 0: parseJson(runtimeConfig.config) else: newJObject())
  state.sim = initSim(config)
  state.pendingRound = -1
  state.pendingSubmissions = initTable[int, Submission]()

  let router = buildRouter()
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "grid-wars: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
