local M = {}
local utils = require 'minuet.utils'
local uv = vim.uv or vim.loop
---@diagnostic disable-next-line: unused-local
local Job = require 'plenary.job'

-- currently running completion jobs, basically forked curl processes
M.current_jobs = {}

---@param job Job
function M.register_job(job)
    table.insert(M.current_jobs, job)
    utils.notify('Registered completion job', 'debug')
end

---@param job Job
function M.remove_job(job)
    for i, j in ipairs(M.current_jobs) do
        if j.pid == job.pid then
            table.remove(M.current_jobs, i)
            utils.notify('Completion job ' .. job.pid .. ' finished and removed from current_jobs', 'debug')
            break
        end
    end
end

---@param pid number
local function terminate_job(pid)
    if not uv.kill(pid, 15) then -- SIGTERM
        utils.notify('Failed to terminate completion job ' .. pid, 'warn', vim.log.levels.WARN)
        return false
    end

    utils.notify('Terminate completion job ' .. pid, 'debug')

    return true
end

function M.terminate_all_jobs()
    for _, job in ipairs(M.current_jobs) do
        terminate_job(job.pid)
    end

    M.current_jobs = {}
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
    local config = require('minuet').config
    if config.after_cursor_filter_length == 0 then
        return items
    end

    local filter_sequence = utils.make_context_filter_sequence(context, config.after_cursor_filter_length)

    items = vim.tbl_map(function(x)
        return utils.filter_text(x, filter_sequence)
    end, items)

    return items
end

return M
