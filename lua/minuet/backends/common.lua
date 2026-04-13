local M = {}
local utils = require 'minuet.utils'

-- Currently running completion jobs, basically forked curl processes.
M.current_jobs = {}

---@param job vim.SystemObj
function M.register_job(job)
    table.insert(M.current_jobs, job)
    utils.notify('Registered completion job', 'debug')
end

---@param job vim.SystemObj
function M.remove_job(job)
    for i, j in ipairs(M.current_jobs) do
        if j.pid == job.pid then
            table.remove(M.current_jobs, i)
            utils.notify('Completion job ' .. job.pid .. ' finished and removed from current_jobs', 'debug')
            break
        end
    end
end

---@param job vim.SystemObj
local function terminate_job(job)
    local ok = pcall(job.kill, job, 'sigterm')
    if not ok then
        utils.notify('Failed to terminate completion job ' .. job.pid, 'warn', vim.log.levels.WARN)
        return false
    end

    utils.notify('Terminate completion job ' .. job.pid, 'debug')

    return true
end

function M.terminate_all_jobs()
    for _, job in ipairs(M.current_jobs) do
        terminate_job(job)
    end

    M.current_jobs = {}
end

---@class minuet.JobHandlers
---@field on_exit fun(job: vim.SystemObj, result: vim.SystemCompleted)
---@field on_spawn_error? fun()

---@param command string
---@param args string[]
---@param handlers minuet.JobHandlers
---@return vim.SystemObj?
function M.start_job(command, args, handlers)
    local cmd = { command }
    vim.list_extend(cmd, args)

    ---@type vim.SystemObj?
    local job
    local ok, result = pcall(
        vim.system,
        cmd,
        { text = true },
        vim.schedule_wrap(function(out)
            if not job then
                return
            end

            M.remove_job(job)
            handlers.on_exit(job, out)
        end)
    )

    if not ok then
        utils.notify('Failed to start completion job: ' .. result, 'error', vim.log.levels.ERROR)
        if handlers.on_spawn_error then
            handlers.on_spawn_error()
        end
        return nil
    end

    job = result
    M.register_job(job)

    return job
end

---@param items_raw string?
---@param provider string
---@return table<string>
function M.parse_completion_items(items_raw, provider)
    local success, items_table = pcall(vim.split, items_raw, '<endCompletion>')
    if not success then
        utils.notify('Failed to parse ' .. provider .. "'s content text", 'error', vim.log.levels.INFO)
        return {}
    end

    return items_table
end

function M.filter_context_sequences_in_items(items, context)
    items = vim.tbl_map(function(x)
        return utils.filter_text(x, context)
    end, items)

    return items
end

---@param str_list string[]
---@return table
function M.create_chat_messages_from_list(str_list)
    local result = {}
    local roles = { 'user', 'assistant' }
    for i, content in ipairs(str_list) do
        table.insert(result, { role = roles[(i - 1) % 2 + 1], content = content })
    end
    return result
end

---@param transform fun(data: { end_point: string, headers: table, body: table })[]?
---@param end_point string
---@param headers table
---@param body table
---@return { end_point: string, headers: table, body: table }
function M.apply_transforms(transform, end_point, headers, body)
    local transformed_data = {
        end_point = end_point,
        headers = headers,
        body = body,
    }

    for _, fun in ipairs(transform or {}) do
        transformed_data = fun(transformed_data)
    end

    return transformed_data
end

return M
