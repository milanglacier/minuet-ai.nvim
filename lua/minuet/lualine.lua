local M = require('lualine.component'):extend()

M.processing = false
M.spinner_index = 1
M.n_requests = 1
M.n_finished_requests = 0
M.name = nil
M.model = nil

local spinner_symbols = {
    '⠋',
    '⠙',
    '⠹',
    '⠸',
    '⠼',
    '⠴',
    '⠦',
    '⠧',
    '⠇',
    '⠏',
}
local spinner_symbols_len = #spinner_symbols

-- Initializer
function M:init(options)
    M.super.init(self, options)

    local group = vim.api.nvim_create_augroup('MinuetLualine', { clear = true })

    vim.api.nvim_create_autocmd({ 'User' }, {
        pattern = 'MinuetRequestStartedPre',
        group = group,
        callback = function(request)
            local data = request.data
            self.processing = false
            self.n_requests = data.n_requests
            self.n_finished_requests = 0
            self.name = data.name
            self.model = data.model
        end,
    })

    vim.api.nvim_create_autocmd({ 'User' }, {
        pattern = 'MinuetRequestStarted',
        group = group,
        callback = function()
            self.processing = true
        end,
    })

    vim.api.nvim_create_autocmd({ 'User' }, {
        pattern = 'MinuetRequestFinished',
        group = group,
        callback = function()
            self.n_finished_requests = self.n_finished_requests + 1
            if self.n_finished_requests == self.n_requests then
                self.processing = false
            end
        end,
    })
end

-- Function that runs every time statusline is updated
function M:update_status()
    if self.processing then
        self.spinner_index = (self.spinner_index % spinner_symbols_len) + 1
        local request =
            string.format('%s/%s: %s/%s', self.name, self.model, self.n_finished_requests + 1, self.n_requests)
        return request .. ' ' .. spinner_symbols[self.spinner_index]
    else
        if self.name ~= nil and self.model ~= nil then
            return self.name .. '/' .. self.model
        end
    end
end

return M
