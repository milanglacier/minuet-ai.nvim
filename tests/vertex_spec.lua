local helpers = require 'tests.helpers'

---@param overrides table?
---@return table
local function load_vertex(overrides)
    helpers.setup_root_config(overrides)
    local vertex = helpers.reload 'minuet.vertex'
    vertex.clear_token_cache()
    return vertex
end

local function make_body()
    return {
        model = 'claude-haiku-4-5',
        max_tokens = 256,
        messages = { { role = 'user', content = 'hello' } },
    }
end

return {
    {
        name = 'vertex.is_enabled only when a project id is configured',
        run = function()
            local vertex = load_vertex()

            helpers.expect_falsy(vertex.is_enabled(nil))
            helpers.expect_falsy(vertex.is_enabled {})
            helpers.expect_falsy(vertex.is_enabled(require('minuet').config.provider_options.claude.vertex))
            helpers.expect_truthy(vertex.is_enabled { project_id = 'my-project' })
        end,
    },
    {
        name = 'vertex.make_request targets the global endpoint and moves the model into the url',
        run = function()
            local vertex = load_vertex()
            local body = make_body()

            local request = vertex.make_request({
                project_id = 'my-project',
                location = 'global',
                access_token = function()
                    return 'test-token'
                end,
            }, body, true)

            helpers.expect_truthy(request)
            helpers.expect_equal(
                request.end_point,
                'https://aiplatform.googleapis.com/v1/projects/my-project/locations/global'
                    .. '/publishers/anthropic/models/claude-haiku-4-5:streamRawPredict'
            )
            helpers.expect_equal(request.headers, {
                ['Content-Type'] = 'application/json',
                ['Authorization'] = 'Bearer test-token',
            })
            helpers.expect_falsy(request.body.model, 'the model must not stay in the request body')
            helpers.expect_equal(request.body.anthropic_version, 'vertex-2023-10-16')
            helpers.expect_equal(request.body.max_tokens, 256)
        end,
    },
    {
        name = 'vertex.make_request uses the regional host and rawPredict without streaming',
        run = function()
            local vertex = load_vertex()

            local request = vertex.make_request({
                project_id = function()
                    return 'my-project'
                end,
                location = 'us-east5',
                access_token = function()
                    return 'test-token'
                end,
            }, make_body(), false)

            helpers.expect_truthy(request)
            helpers.expect_equal(
                request.end_point,
                'https://us-east5-aiplatform.googleapis.com/v1/projects/my-project/locations/us-east5'
                    .. '/publishers/anthropic/models/claude-haiku-4-5:rawPredict'
            )
        end,
    },
    {
        name = 'vertex.make_request reads the access token from an environment variable',
        run = function()
            local vertex = load_vertex()
            local original = vim.env.MINUET_TEST_VERTEX_TOKEN

            local ok, err = xpcall(function()
                vim.env.MINUET_TEST_VERTEX_TOKEN = 'env-token'

                local request = vertex.make_request({
                    project_id = 'my-project',
                    access_token = 'MINUET_TEST_VERTEX_TOKEN',
                }, make_body(), true)

                helpers.expect_truthy(request)
                helpers.expect_equal(request.headers['Authorization'], 'Bearer env-token')
            end, debug.traceback)

            vim.env.MINUET_TEST_VERTEX_TOKEN = original

            if not ok then
                error(err)
            end
        end,
    },
    {
        name = 'vertex.make_request reuses the token produced by token_cmd until it expires',
        run = function()
            local vertex = load_vertex()

            local function request_with_token(token, token_ttl)
                return vertex.make_request({
                    project_id = 'my-project',
                    token_cmd = { 'sh', '-c', 'echo ' .. token },
                    token_ttl = token_ttl,
                }, make_body(), true)
            end

            local first = request_with_token('token-a', 3000)
            helpers.expect_truthy(first)
            helpers.expect_equal(first.headers['Authorization'], 'Bearer token-a')

            local second = request_with_token('token-b', 3000)
            helpers.expect_truthy(second)
            helpers.expect_equal(second.headers['Authorization'], 'Bearer token-a')

            -- An already expired token is fetched again.
            vertex.clear_token_cache()
            local third = request_with_token('token-b', -1)
            helpers.expect_truthy(third)
            helpers.expect_equal(third.headers['Authorization'], 'Bearer token-b')

            local fourth = request_with_token('token-c', -1)
            helpers.expect_truthy(fourth)
            helpers.expect_equal(fourth.headers['Authorization'], 'Bearer token-c')
        end,
    },
    {
        name = 'vertex.make_request reports an error when the project id or the token is missing',
        run = function()
            local vertex = load_vertex { notify = 'error' }
            local messages, restore = helpers.capture_notifications()

            local ok, err = xpcall(function()
                helpers.expect_falsy(vertex.make_request({ project_id = '' }, make_body(), true))
                helpers.expect_falsy(vertex.make_request({
                    project_id = 'my-project',
                    access_token = function()
                        return nil
                    end,
                }, make_body(), true))
                helpers.expect_falsy(vertex.make_request({
                    project_id = 'my-project',
                    token_cmd = { 'sh', '-c', 'exit 1' },
                }, make_body(), true))
            end, debug.traceback)

            restore()

            if not ok then
                error(err)
            end

            helpers.expect_equal(#messages, 3, 'each failure must be reported once')
        end,
    },
    {
        name = 'the claude backend sends completion requests to Vertex AI',
        run = function()
            local recorded = vim.fn.tempname()

            helpers.setup_root_config {
                provider = 'claude',
                curl_cmd = vim.fn.getcwd() .. '/tests/scripts/record_curl_args.sh',
                curl_extra_args = { recorded },
                provider_options = {
                    claude = {
                        model = 'claude-haiku-4-5',
                        vertex = {
                            project_id = 'my-project',
                            location = 'us-east5',
                            access_token = function()
                                return 'test-token'
                            end,
                        },
                    },
                },
            }

            local claude = helpers.reload 'minuet.backends.claude'
            local finished = false

            claude.complete({ lines_before = 'local answer = ', lines_after = '', opts = {} }, function()
                finished = true
            end)

            helpers.wait_until(function()
                return finished
            end, 3000, 'the claude backend did not finish the request')

            local args = vim.fn.readfile(recorded)
            local body = vim.json.decode(table.concat(vim.fn.readfile(recorded .. '.body'), '\n'))
            vim.uv.fs_unlink(recorded)
            vim.uv.fs_unlink(recorded .. '.body')

            helpers.expect_equal(
                args[#args],
                'https://us-east5-aiplatform.googleapis.com/v1/projects/my-project/locations/us-east5'
                    .. '/publishers/anthropic/models/claude-haiku-4-5:streamRawPredict'
            )
            helpers.expect_truthy(
                vim.tbl_contains(args, 'Authorization: Bearer test-token'),
                'the request must carry the Vertex AI access token'
            )
            helpers.expect_falsy(
                vim.iter(args):any(function(arg)
                    return vim.startswith(arg, 'x-api-key')
                end),
                'the request must not carry an Anthropic API key'
            )
            helpers.expect_equal(body.anthropic_version, 'vertex-2023-10-16')
            helpers.expect_falsy(body.model, 'the model must not stay in the request body')
        end,
    },
}
