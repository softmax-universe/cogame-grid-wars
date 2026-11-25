## Hosted calls must reach the native sidecar without provider credentials.
include "../src/gridwars/llm"

block:
  putEnv("COWORLD_LLM_ENDPOINT", "http://127.0.0.1:9100/")
  putEnv("COWORLD_LLM_MODEL", "anthropic/claude-sonnet-4.6")
  putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "http://retired.invalid")
  putEnv("ANTHROPIC_API_KEY", "local-key-must-not-be-used")
  let client = newLlmClient(128, "claude-haiku-4-5-20251001")
  for slot in 0 .. 1:
    let request = client.requestFor("rules", "private view", slot)
    doAssert request.url == "http://127.0.0.1:9100/v1/messages"
    doAssert request.headers["X-Coworld-Player-Slot"] == $slot
    let body = parseJson(request.body)
    doAssert body["model"].getStr() == "anthropic/claude-sonnet-4.6"
    doAssert not body.hasKey("anthropic_version")
    doAssert not body.hasKey("output_config")
  echo "hosted sidecar routing and seat attribution passed"

block:
  ## Bedrock transport must use a single configured model without silent fallback.
  delEnv("COWORLD_LLM_ENDPOINT")
  delEnv("BEDROCK_MODEL")
  putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "http://127.0.0.1:9200")
  putEnv("AWS_BEARER_TOKEN_BEDROCK", "test-token")
  let client = newLlmClient(128, "claude-haiku-4-5-20251001")
  let initialUrl = client.bedrockUrl()
  for code in [403, 429, 500]:
    var raisedInfra = false
    try:
      discard client.textOf(Response(code: code, body: "Model access is denied"), "", initialUrl)
    except LlmInfraError:
      raisedInfra = true
    doAssert raisedInfra, "expected LlmInfraError for HTTP " & $code
    doAssert client.bedrockUrl() == initialUrl, "bedrock model must not silently switch"
  echo "bedrock single-model and infra error classification passed"
