-- based on the:
-- https://github.com/olimorris/codecompanion.nvim/discussions/813
local M = {}

function M:init()
    local group = vim.api.nvim_create_augroup("MinuetFidgetHooks", {})

    vim.api.nvim_create_autocmd({ "User" }, {
        pattern = "MinuetRequestStarted",
        group = group,
        callback = function(request)
            local handle = M:create_progress_handle(request)
            M:store_progress_handle(request.data.timestamp, handle)
        end,
    })

    vim.api.nvim_create_autocmd({ "User" }, {
        pattern = "MinuetRequestFinished",
        group = group,
        callback = function(request)
            local handle = M:pop_progress_handle(request.data.timestamp)
            if handle then
                handle.message = "Done"
                handle:finish()
            end
        end,
    })
end

M.handles = {}

function M:store_progress_handle(id, handle)
    M.handles[id] = handle
end

function M:pop_progress_handle(id)
    local handle = M.handles[id]
    M.handles[id] = nil
    return handle
end

function M:create_progress_handle(request)
    local progress = require "fidget.progress"

    return progress.handle.create {
        title = " Requesting completion " .. request.data.name,
        message = "In progress " .. request.data.n_requests .. "...",
        lsp_client = {
            name = request.data.name,
        },
    }
end

return M
