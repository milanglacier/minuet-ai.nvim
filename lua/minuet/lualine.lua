local M = require('lualine.component'):extend()

M.processing = false
M.spinner_index = 1
M.n_requests = 1
M.n_finished_requests = 0
M.provider = nil
M.model = nil

local default_options = {
    -- the symbols that are used to create spinner animation
    spinner_symbols = {
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
    },
    -- the name displayed in the lualine. Set to "provider", "model" or "both"
    display_name = 'both',
    -- separator between provider and model name for option "both"
    provider_model_separator = ':',
}

-- Initializer
function M:init(options)
    M.super.init(self, options)
    self.options = vim.tbl_extend('keep', self.options or {}, default_options)
    self.spinner_symbols_len = #self.options.spinner_symbols

    local group = vim.api.nvim_create_augroup('MinuetLualine', { clear = true })

    vim.api.nvim_create_autocmd({ 'User' }, {
        pattern = 'MinuetRequestStartedPre',
        group = group,
        callback = function(request)
            local data = request.data
            self.processing = false
            self.n_requests = data.n_requests
            self.n_finished_requests = 0
            self.provider = data.name
            self.model = data.model
            if self.options.display_name == 'model' then
                self.display_name = self.model
            elseif self.options.display_name == 'provider' then
                self.display_name = self.provider
            else
                self.display_name = self.provider .. self.options.provider_model_separator .. self.model
            end
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
        self.spinner_index = (self.spinner_index % self.spinner_symbols_len) + 1
        local request = string.format('%s: %s/%s', self.display_name, self.n_finished_requests + 1, self.n_requests)
        return request .. ' ' .. self.options.spinner_symbols[self.spinner_index]
    else
        return self.display_name
    end
end

return M
