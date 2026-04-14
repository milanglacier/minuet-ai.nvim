local M = {}

local repo_root = vim.fn.getcwd()

function M.ensure_runtime()
    vim.opt.runtimepath:prepend(repo_root)
    package.path = table.concat({
        repo_root .. '/?.lua',
        repo_root .. '/?/init.lua',
        repo_root .. '/lua/?.lua',
        repo_root .. '/lua/?/init.lua',
        repo_root .. '/tests/?.lua',
        repo_root .. '/tests/?/init.lua',
        package.path,
    }, ';')
end

function M.reset_minuet_modules()
    for name, _ in pairs(package.loaded) do
        if name == 'minuet' or vim.startswith(name, 'minuet.') then
            package.loaded[name] = nil
        end
    end
end

function M.setup_root_config(overrides)
    M.ensure_runtime()
    M.reset_minuet_modules()

    local config = vim.deepcopy(require 'minuet.config')
    local root = {
        config = vim.tbl_deep_extend('force', config, {
            notify = false,
            curl_cmd = 'curl',
        }, overrides or {}),
    }

    package.loaded['minuet'] = root
    return root
end

function M.reload(module_name)
    package.loaded[module_name] = nil
    return require(module_name)
end

function M.create_buffer(lines, cursor)
    local bufnr = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or { '' })

    if cursor then
        vim.api.nvim_win_set_cursor(0, cursor)
    end

    return bufnr
end

function M.delete_buffer(bufnr)
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
end

function M.expect_equal(actual, expected, message)
    if not vim.deep_equal(actual, expected) then
        error(
            (message or 'expected values to be equal')
                .. '\nexpected: '
                .. vim.inspect(expected)
                .. '\nactual: '
                .. vim.inspect(actual),
            2
        )
    end
end

function M.expect_truthy(value, message)
    if not value then
        error(message or 'expected a truthy value', 2)
    end
end

function M.expect_falsy(value, message)
    if value then
        error((message or 'expected a falsy value') .. '\nactual: ' .. vim.inspect(value), 2)
    end
end

function M.expect_match(text, pattern, message)
    if type(text) ~= 'string' or not text:match(pattern) then
        error(
            (message or 'expected string to match pattern')
                .. '\npattern: '
                .. pattern
                .. '\nactual: '
                .. vim.inspect(text),
            2
        )
    end
end

function M.wait_until(predicate, timeout_ms, message)
    local ok = vim.wait(timeout_ms or 1000, predicate, 10)
    if not ok then
        error(message or 'timed out waiting for condition', 2)
    end
end

function M.capture_notifications()
    local original = vim.notify
    local messages = {}

    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level, opts)
        table.insert(messages, {
            msg = msg,
            level = level,
            opts = opts,
        })
    end

    return messages, function()
        vim.notify = original
    end
end

return M
