local M = require('lualine.component'):extend()

M.processing = false
M.spinner_index = 1
M.n_requests = 1
M.n_finished_requests = 0
M.name = 'unknown'

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
local spinner_symbols_len = 10

-- Initializer
function M:init(options)
    M.super.init(self, options)

    local group = vim.api.nvim_create_augroup('MinuetHooks', {})

    vim.api.nvim_create_autocmd({ 'User' }, {
        pattern = 'MinuetRequest*',
        group = group,
        callback = function(request)
            local data = request.data

            if request.match == 'MinuetRequestInit' then
                self.processing = false
                self.n_requests = data.n_requests
                self.n_finished_requests = 0
                self.name = data.name or data.provider
            elseif request.match == 'MinuetRequestStarted' then
                self.processing = true
            elseif request.match == 'MinuetRequestFinished' then
                self.n_finished_requests = self.n_finished_requests + 1
                if self.n_finished_requests == self.n_requests then
                    self.processing = false
                end
            end
        end,
    })
end

-- Function that runs every time statusline is updated
function M:update_status()
    if self.processing then
        self.spinner_index = (self.spinner_index % spinner_symbols_len) + 1
        local request = string.format('%s: %s/%s', self.name, self.n_finished_requests + 1, self.n_requests)
        return request .. ' ' .. spinner_symbols[self.spinner_index]
    else
        return nil
    end
end

return M
