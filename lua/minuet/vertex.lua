-- Support for reaching Claude through Google Cloud Vertex AI instead of the
-- Anthropic API.

local utils = require 'minuet.utils'

local M = {}

---@class minuet.VertexOptions
---@field project_id? string|fun(): string? The Google Cloud project id, or a function returning it. Vertex AI is used when this is set.
---@field location? string|fun(): string? The Vertex AI location, `global` by default.
---@field access_token? string|fun(): string? The name of an environment variable holding an OAuth access token, or a function returning one.
---@field token_cmd? string[]|fun(): string[] The command run to obtain an OAuth access token when `access_token` is unset.
---@field token_ttl? number How long, in seconds, a token obtained from `token_cmd` is reused.

---@class minuet.VertexRequest
---@field end_point string
---@field headers table<string, string>
---@field body table

-- Vertex AI takes the API version in the request body, where the Anthropic API
-- takes it in the `anthropic-version` header.
local ANTHROPIC_VERSION = 'vertex-2023-10-16'

local DEFAULT_LOCATION = 'global'
local DEFAULT_TOKEN_CMD = { 'gcloud', 'auth', 'print-access-token' }
-- Google access tokens are valid for one hour, so refresh well before that.
local DEFAULT_TOKEN_TTL = 3000
local TOKEN_CMD_TIMEOUT = 5000

-- The access token produced by `token_cmd`, reused until `expires_at`.
---@type { value: string?, expires_at: number }
local cached_token = { value = nil, expires_at = 0 }

---Whether Claude requests should be sent to Vertex AI.
---@param options minuet.VertexOptions?
---@return boolean
function M.is_enabled(options)
    return type(options) == 'table' and options.project_id ~= nil
end

---@param options minuet.VertexOptions
---@return string?
local function get_access_token(options)
    if options.access_token then
        local token = utils.get_api_key(options.access_token)
        if not token then
            utils.notify('Vertex AI access token is not set', 'error', vim.log.levels.ERROR)
        end
        return token
    end

    local now = os.time()
    if cached_token.value and now < cached_token.expires_at then
        return cached_token.value
    end

    local cmd = utils.get_or_eval_value(options.token_cmd) or DEFAULT_TOKEN_CMD
    ---@cast cmd string[]

    -- This blocks the editor until the command returns, which happens once per
    -- `token_ttl` seconds.
    local spawned, result = pcall(function()
        return vim.system(cmd, { text = true }):wait(TOKEN_CMD_TIMEOUT)
    end)

    local token = spawned and result.code == 0 and vim.trim(result.stdout or '') or ''

    if token == '' then
        utils.notify(
            'Failed to get a Vertex AI access token by running: ' .. table.concat(cmd, ' '),
            'error',
            vim.log.levels.ERROR
        )
        return
    end

    cached_token.value = token
    cached_token.expires_at = now + (options.token_ttl or DEFAULT_TOKEN_TTL)

    return token
end

---Build the endpoint, headers, and body of a Vertex AI request. The model name
---moves from the body into the endpoint. Returns nil when the project id or the
---access token cannot be resolved.
---@param options minuet.VertexOptions
---@param body table The Anthropic request body, modified in place.
---@param stream boolean
---@return minuet.VertexRequest?
function M.make_request(options, body, stream)
    local project_id = utils.get_or_eval_value(options.project_id)
    if type(project_id) ~= 'string' or project_id == '' then
        utils.notify('Vertex AI project id is not set', 'error', vim.log.levels.ERROR)
        return
    end

    local model = body.model
    if type(model) ~= 'string' or model == '' then
        utils.notify('Vertex AI requires a model name', 'error', vim.log.levels.ERROR)
        return
    end

    local token = get_access_token(options)
    if not token then
        return
    end

    local location = utils.get_or_eval_value(options.location) or DEFAULT_LOCATION
    local host = location == 'global' and 'aiplatform.googleapis.com'
        or string.format('%s-aiplatform.googleapis.com', location)

    body.model = nil
    body.anthropic_version = ANTHROPIC_VERSION

    return {
        end_point = string.format(
            'https://%s/v1/projects/%s/locations/%s/publishers/anthropic/models/%s:%s',
            host,
            project_id,
            location,
            model,
            stream and 'streamRawPredict' or 'rawPredict'
        ),
        headers = {
            ['Content-Type'] = 'application/json',
            ['Authorization'] = 'Bearer ' .. token,
        },
        body = body,
    }
end

---Forget the cached access token. Used by tests.
function M.clear_token_cache()
    cached_token = { value = nil, expires_at = 0 }
end

return M
