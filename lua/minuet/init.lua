local default_config = require 'minuet.config'

local M = {}

function M.setup(config)
    M.config = vim.tbl_deep_extend('force', default_config, config or {})

    if M.config.notify == true then
        vim.notify(
            'Minuet config.notify specs has been updated. Please change true to one of false, "error" or "verbose".',
            vim.log.levels.WAN
        )
        M.config.notify = 'verbose'
    end

    require('cmp').register_source('minuet', require('minuet.source'):new())
end

function M.make_cmp_map()
    local cmp = require 'cmp'
    return cmp.mapping(cmp.mapping.complete {
        config = {
            sources = cmp.config.sources {
                { name = 'minuet' },
            },
            performance = {
                fetching_timeout = M.config.request_timeout,
                -- Increase the fetching timeout here since LLM takes much more
                -- time to respond.
            },
        },
    })
end

return M
