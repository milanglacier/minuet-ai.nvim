local M = {}

function M.notify(msg, minuet_level, vim_level, opts)
    local config = require('minuet').config
    local notify_levels = {
        debug = 0,
        verbose = 1,
        warn = 2,
        error = 3,
    }

    if config.notify and notify_levels[minuet_level] >= notify_levels[config.notify] then
        vim.notify(msg, vim_level, opts)
    end
end

--- Get API key from environment variable or function.
---@param env_var string|function environment variable name or function returning API key
---@return string? API key or nil if not found or invalid
function M.get_api_key(env_var)
    local api_key
    if type(env_var) == 'function' then
        api_key = env_var()
    elseif type(env_var) == 'string' then
        api_key = vim.env[env_var]
    end

    if type(api_key) ~= 'string' or api_key == '' then
        return nil
    end

    return api_key
end

-- referenced from cmp_ai
function M.make_tmp_file(content)
    local tmp_file = os.tmpname()

    local f = io.open(tmp_file, 'w+')
    if f == nil then
        M.notify('Cannot open temporary message file: ' .. tmp_file, 'error', vim.log.levels.ERROR)
        return
    end

    local result, json = pcall(vim.json.encode, content)

    if not result then
        M.notify('Failed to encode completion request data', 'error', vim.log.levels.ERROR)
        return
    end

    f:write(json)
    f:close()

    return tmp_file
end

function M.make_system_prompt(template, n_completion)
    ---- replace the placeholders in the template with the values in the table
    local system_prompt = template.template
    local n_completion_template = template.n_completion_template

    if type(system_prompt) == 'function' then
        system_prompt = system_prompt()
    end

    if type(n_completion_template) == 'function' then
        n_completion_template = n_completion_template()
    end

    if type(n_completion_template) == 'string' and type(n_completion) == 'number' then
        n_completion_template = string.format(n_completion_template, n_completion)
        system_prompt = system_prompt:gsub('{{{n_completion_template}}}', n_completion_template)
    end

    template.template = nil
    template.n_completion_template = nil

    for k, v in pairs(template) do
        if type(v) == 'function' then
            system_prompt = system_prompt:gsub('{{{' .. k .. '}}}', v())
        elseif type(v) == 'string' then
            system_prompt = system_prompt:gsub('{{{' .. k .. '}}}', v)
        end
    end

    ---- remove the placeholders that are not replaced
    system_prompt = system_prompt:gsub('{{{.*}}}', '')

    return system_prompt
end

--- Return val if val is not a function, else call val and return the value
function M.get_or_eval_value(val)
    if type(val) ~= 'function' then
        return val
    end
    return val()
end

---@return string
function M.add_language_comment()
    if vim.bo.ft == nil or vim.bo.ft == '' then
        return ''
    end

    local language_string = 'language: ' .. vim.bo.ft
    local commentstring = vim.bo.commentstring

    if commentstring == nil or commentstring == '' then
        return '# ' .. language_string
    end

    -- Directly replace %s with the comment
    if commentstring:find '%%s' then
        language_string = commentstring:gsub('%%s', language_string)
        return language_string
    end

    -- Fallback to prepending comment if no %s found
    return commentstring .. ' ' .. language_string
end

---@return string
function M.add_tab_comment()
    if vim.bo.ft == nil or vim.bo.ft == '' then
        return ''
    end

    local tab_string
    local tabwidth = vim.bo.softtabstop > 0 and vim.bo.softtabstop or vim.bo.shiftwidth
    local commentstring = vim.bo.commentstring

    if vim.bo.expandtab and tabwidth > 0 then
        tab_string = 'indentation: use ' .. tabwidth .. ' spaces for a tab'
    elseif not vim.bo.expandtab then
        tab_string = 'indentation: use \t for a tab'
    else
        return ''
    end

    if commentstring == nil or commentstring == '' then
        return '# ' .. tab_string
    end

    -- Directly replace %s with the comment
    if commentstring:find '%%s' then
        tab_string = commentstring:gsub('%%s', tab_string)
        return tab_string
    end

    -- Fallback to prepending comment if no %s found
    return commentstring .. ' ' .. tab_string
end

-- Copied from blink.cmp.Context. Because we might use nvim-cmp instead of
-- blink-cmp, so blink might not be installed, so we create another class here
-- and use it instead.

--- @class minuet.BlinkCmpContext
--- @field line string
--- @field cursor number[]
--- @field bufnr number?

---@param blink_context minuet.BlinkCmpContext?
function M.make_cmp_context(blink_context)
    local self = {}
    local cursor
    if blink_context then
        cursor = blink_context.cursor
        self.cursor_line = blink_context.line
        -- Get buffer number from blink context or default to current buffer
        self.bufnr = blink_context.bufnr or vim.api.nvim_get_current_buf()
    else
        cursor = vim.api.nvim_win_get_cursor(0)
        self.cursor_line = vim.api.nvim_get_current_line()
        self.bufnr = vim.api.nvim_get_current_buf()
    end

    self.cursor = {}
    self.cursor.row = cursor[1]
    self.cursor.col = cursor[2] + 1
    self.cursor.line = self.cursor.row - 1
    -- self.cursor.character = require('cmp.utils.misc').to_utfindex(self.cursor_line, self.cursor.col)
    self.cursor_before_line = string.sub(self.cursor_line, 1, self.cursor.col - 1)
    self.cursor_after_line = string.sub(self.cursor_line, self.cursor.col)
    return self
end

---@class minuet.LSPPositionParams
---@field context {triggerKind: number}
---@field position {character: number, line: number}
---@field textDocument {uri: string}

---@param params minuet.LSPPositionParams
function M.make_cmp_context_from_lsp_params(params)
    local bufnr
    local self = {}
    if params.textDocument.uri == 'file://' then
        bufnr = vim.api.nvim_get_current_buf()
    else
        bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    end

    local row = params.position.line
    local col = math.max(params.position.character, 0)
    self.cursor = {
        row = row,
        line = row,
        col = col,
    }
    self.bufnr = bufnr

    local current_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
    local cursor_before_line = vim.fn.strcharpart(current_line, 0, col)
    local cursor_after_line = vim.fn.strcharpart(current_line, col)

    self.cursor_before_line = cursor_before_line
    self.cursor_after_line = cursor_after_line
    return self
end

--- Get the context around the cursor position for code completion
---@param cmp_context table The completion context object containing cursor position and line info
---@return table Context information with the following fields:
---   - lines_before: string - Text content before cursor, truncated based on context window size
---   - lines_after: string - Text content after cursor, truncated based on context window size
---   - opts: table - Options indicating if context was truncated:
---     - is_incomplete_before: boolean - True if content before cursor was truncated
---     - is_incomplete_after: boolean - True if content after cursor was truncated
function M.get_context(cmp_context)
    local config = require('minuet').config

    local cursor = cmp_context.cursor
    -- Use the buffer number from context, or fall back to current buffer
    local bufnr = cmp_context.bufnr or vim.api.nvim_get_current_buf()
    local lines_before_list = vim.api.nvim_buf_get_lines(bufnr, 0, cursor.line, false)
    local lines_after_list = vim.api.nvim_buf_get_lines(bufnr, cursor.line + 1, -1, false)

    local lines_before = table.concat(lines_before_list, '\n')
    local lines_after = table.concat(lines_after_list, '\n')

    lines_before = lines_before .. '\n' .. cmp_context.cursor_before_line
    lines_after = cmp_context.cursor_after_line .. '\n' .. lines_after

    local n_chars_before = vim.fn.strchars(lines_before)
    local n_chars_after = vim.fn.strchars(lines_after)

    local opts = {
        is_incomplete_before = false,
        is_incomplete_after = false,
    }

    if n_chars_before + n_chars_after > config.context_window then
        -- use some heuristic to decide the context length of before cursor and after cursor
        if n_chars_before < config.context_window * config.context_ratio then
            -- If the context length before cursor does not exceed the maximum
            -- size, we include the full content before the cursor.
            lines_after = vim.fn.strcharpart(lines_after, 0, config.context_window - n_chars_before)
            opts.is_incomplete_after = true
        elseif n_chars_after < config.context_window * (1 - config.context_ratio) then
            -- if the context length after cursor does not exceed the maximum
            -- size, we include the full content after the cursor.
            lines_before = vim.fn.strcharpart(lines_before, n_chars_before + n_chars_after - config.context_window)
            opts.is_incomplete_before = true
        else
            -- at the middle of the file, use the context_ratio to determine the allocation
            lines_after =
                vim.fn.strcharpart(lines_after, 0, math.floor(config.context_window * (1 - config.context_ratio)))

            lines_before = vim.fn.strcharpart(
                lines_before,
                n_chars_before - math.floor(config.context_window * config.context_ratio)
            )

            opts.is_incomplete_before = true
            opts.is_incomplete_after = true
        end
    end

    return {
        lines_before = lines_before,
        lines_after = lines_after,
        opts = opts,
    }
end

---remove the sequence and the rest part from text.
---@param text string?
---@param context { lines_before: string?, lines_after: string? }
---@return string?
function M.filter_text(text, context)
    local config = require('minuet').config

    -- Handle nil values
    if not text or not context then
        return text
    end

    local lines_before = context.lines_before
    local lines_after = context.lines_after

    -- Handle nil context values
    if not lines_before and not lines_after then
        return text
    end

    text = M.remove_spaces_single(text, true)
    lines_before = M.remove_spaces_single(lines_before or '')
    lines_after = M.remove_spaces_single(lines_after or '')

    if not text then
        return
    end

    local filtered_text = text

    -- Filter based on context before cursor (trim from the beginning of completion)
    if lines_before and config.before_cursor_filter_length > 0 then
        local match_before = M.find_longest_match(filtered_text, lines_before)
        local match_len = vim.fn.strchars(match_before)
        if match_before and match_len >= config.before_cursor_filter_length then
            -- Remove the matching part from the beginning of the completion
            filtered_text = vim.fn.strcharpart(filtered_text, match_len)
        end
    end

    -- Filter based on context after cursor (trim from the end of completion)
    if lines_after and config.after_cursor_filter_length > 0 then
        local match_after = M.find_longest_match(lines_after, filtered_text)
        local match_len = vim.fn.strchars(match_after)
        if match_after and match_len >= config.after_cursor_filter_length then
            -- Remove the matching part from the end of the completion
            local text_len = vim.fn.strchars(filtered_text)
            filtered_text = vim.fn.strcharpart(filtered_text, 0, text_len - match_len)
        end
    end

    return filtered_text
end

--- Remove the trailing and leading spaces for a single string item
---@param item string
---@param keep_leading_newline? boolean
---@return string?
function M.remove_spaces_single(item, keep_leading_newline)
    if not item:find '%S' then -- skip entries that contain only whitespace
        return nil
    end

    local start_pattern = keep_leading_newline and '^[ \t]+' or '^%s+'

    -- replace the trailing spaces
    item = item:gsub('%s+$', '')
    -- replace the leading spaces
    item = item:gsub(start_pattern, '')

    return item
end

--- Remove the trailing and leading spaces for each string in the table
---@param items table[string]
---@param keep_leading_newline? boolean
function M.remove_spaces(items, keep_leading_newline)
    local new = {}

    for _, item in ipairs(items) do
        item = M.remove_spaces_single(item, keep_leading_newline)
        if item then
            table.insert(new, item)
        end
    end

    return new
end

-- Find the longest string that is a prefix of A and a suffix of B. The
-- function iterates from the longest possible match length downwards for
-- efficiency.  If A or B are not strings, it returns an empty string.
---@param a string?
---@param b string?
function M.find_longest_match(a, b)
    -- Ensure both inputs are strings to avoid errors.
    if type(a) ~= 'string' or type(b) ~= 'string' then
        return ''
    end

    -- The longest possible match is limited by the shorter of the two strings.
    local max_len = math.min(#a, #b)

    -- Iterate downwards from the maximum possible length to 1.
    -- This is more efficient because the first match we find will be the longest one.
    for len = max_len, 1, -1 do
        -- Extract the prefix from string 'a'.
        local prefix_a = string.sub(a, 1, len)

        -- Extract the suffix from string 'b'.
        -- Negative indices in string.sub count from the end of the string.
        local suffix_b = string.sub(b, -len)

        -- If the prefix of 'a' matches the suffix of 'b', we've found our longest match.
        if prefix_a == suffix_b then
            return prefix_a
        end
    end

    -- If the loop completes without finding any match, return an empty string.
    return ''
end

--- If the last word of b is not a substring of the first word of a,
--- And it there are no trailing spaces for b and no leading spaces for a,
--- prepend the last word of b to a.
---@param a string?
---@param b string?
---@return string?
function M.prepend_to_complete_word(a, b)
    if not a or not b then
        return a
    end

    local last_word_b = b:match '[%w_-]+$'
    local first_word_a = a:match '^[%w_-]+'

    if last_word_b and first_word_a and not first_word_a:find(last_word_b, 1, true) then
        a = last_word_b .. a
    end

    return a
end

---Adjust indentation of lines based on direction
---@param lines string The string containing the lines to adjust
---@param ref_line string The reference line used to adjust identation
---@param direction "+" | "-" "+" for adding, "-" for removing
---@return string Lines Adjusted lines
function M.adjust_indentation(lines, ref_line, direction)
    local indentation = string.match(ref_line or '', '^%s*') or ''

    ---@diagnostic disable-next-line:cast-local-type
    lines = vim.split(lines, '\n')
    local new_lines = {}

    for _, line in ipairs(lines) do
        if direction == '+' then
            table.insert(new_lines, indentation .. line)
        elseif direction == '-' then
            -- Remove indentation if it exists at the start of the line
            if line:sub(1, #ref_line) == indentation then
                line = line:sub(#ref_line + 1)
            end
            table.insert(new_lines, line)
        end
    end

    return table.concat(new_lines, '\n')
end

---@param context table
---@param template table
---@return string[]
function M.make_chat_llm_shot(context, template)
    local inputs = template.template
    if type(inputs) == 'string' then
        inputs = { inputs }
    end
    local context_before_cursor = context.lines_before
    local context_after_cursor = context.lines_after
    local opts = context.opts

    -- Store the template value before clearing it
    template.template = nil
    local results = {}

    for _, input in ipairs(inputs) do
        local parts = {}
        local last_pos = 1
        while true do
            local start_pos, end_pos = input:find('{{{.-}}}', last_pos)
            if not start_pos then
                -- Add the remaining part of the string
                table.insert(parts, input:sub(last_pos))
                break
            end

            -- Add the text before the placeholder
            table.insert(parts, input:sub(last_pos, start_pos - 1))

            -- Extract placeholder key
            local key = input:sub(start_pos + 3, end_pos - 3)

            -- Get the replacement value if it exists
            if template[key] then
                local value = template[key](context_before_cursor, context_after_cursor, opts)
                table.insert(parts, value)
            end

            last_pos = end_pos + 1
        end

        local result = table.concat(parts)
        table.insert(results, result)
    end

    return results
end

function M.no_stream_decode(response, exit_code, data_file, provider, get_text_fn)
    os.remove(data_file)

    if exit_code ~= 0 then
        if exit_code == 28 then
            M.notify('Request timed out.', 'warn', vim.log.levels.WARN)
        else
            M.notify(string.format('Request failed with exit code %d', exit_code), 'error', vim.log.levels.ERROR)
        end
        return
    end

    local result = table.concat(response:result(), '\n')
    local success, json = pcall(vim.json.decode, result)
    if not success then
        if result ~= '' then
            M.notify(
                'Failed to parse ' .. provider .. ' API response as json: ' .. vim.inspect(result),
                'error',
                vim.log.levels.INFO
            )
        end
        return
    end

    local result_str

    success, result_str = pcall(get_text_fn, json)

    if not success or not result_str or result_str == '' then
        if result:find 'error' then
            M.notify(provider .. ' returns error: ' .. vim.inspect(result), 'error', vim.log.levels.INFO)
        else
            M.notify(provider .. ' returns no text: ' .. vim.inspect(json), 'verbose', vim.log.levels.INFO)
        end
        return
    end

    return result_str
end

function M.stream_decode(response, exit_code, data_file, provider, get_text_fn)
    os.remove(data_file)

    if not (exit_code == 28 or exit_code == 0) then
        M.notify(string.format('Request failed with exit code %d', exit_code), 'error', vim.log.levels.ERROR)
        return
    end

    local result = {}
    local responses = response:result()

    for _, line in ipairs(responses) do
        local success, json, text

        line = line:gsub('^data:', '')
        success, json = pcall(vim.json.decode, line)
        if not success then
            goto continue
        end

        success, text = pcall(get_text_fn, json)
        if not success then
            goto continue
        end

        if type(text) == 'string' and text ~= '' then
            table.insert(result, text)
        end
        ::continue::
    end

    local result_str = #result > 0 and table.concat(result) or nil

    if not result_str then
        local notified_on_error = false
        for _, line in ipairs(responses) do
            if line:find 'error' then
                M.notify(
                    provider .. ' returns error on streaming: ' .. vim.inspect(responses),
                    'error',
                    vim.log.levels.INFO
                )

                notified_on_error = true

                break
            end
        end

        if not notified_on_error then
            M.notify(
                provider .. ' returns no text on streaming: ' .. vim.inspect(responses),
                'verbose',
                vim.log.levels.INFO
            )
        end
        return
    end

    return result_str
end

M.add_single_line_entry = function(list)
    local newlist = {}

    for _, item in ipairs(list) do
        if type(item) == 'string' then
            -- single line completion item should be preferred.
            table.insert(newlist, item)
            table.insert(newlist, 1, vim.split(item, '\n')[1])
        end
    end

    return newlist
end

--- dedup the items in a list
M.list_dedup = function(list)
    local hash = {}
    local items_cleaned = {}
    for _, item in ipairs(list) do
        if type(item) == 'string' and not hash[item] then
            hash[item] = true
            table.insert(items_cleaned, item)
        end
    end
    return items_cleaned
end

---@class minuet.EventData
---@field provider string the name of the provider
---@field name string the name of the subprovider for openai-compatible and openai-fim-compatible
---@field model string the model name used during this event
---@field n_requests number the number of requests launched during this event
---@field request_idx? number the index of the current request
---@field timestamp number the timestamp of the event at MminuetRequestStartedPre

---@param event string The minuet event to run
---@param opts minuet.EventData The minuet data event
function M.run_event(event, opts)
    opts = opts or {}
    vim.api.nvim_exec_autocmds('User', { pattern = event, data = opts })
end

---@param end_point string
---@param headers table<string, string>
---@param data_file string
---@return string[]
function M.make_curl_args(end_point, headers, data_file)
    local config = require('minuet').config
    local args = {
        '-L',
        end_point,
    }
    for k, v in pairs(headers) do
        table.insert(args, '-H')
        table.insert(args, k .. ': ' .. v)
    end
    table.insert(args, '--max-time')
    table.insert(args, tostring(config.request_timeout))
    table.insert(args, '-d')
    table.insert(args, '@' .. data_file)

    if config.proxy then
        table.insert(args, '--proxy')
        table.insert(args, config.proxy)
    end

    return args
end

--- Check if Minuet should be allowed to trigger
--- Calls the user-defined enabled callbacks if configured
---@return boolean should_trigger Whether minuet is allowed to trigger
function M.should_trigger()
    local config = require('minuet').config

    -- If no callback is configured, always trigger
    if not config.enabled or #config.enabled == 0 then
        return true
    end

    -- Reduce the user's callbacks
    local trigger = true
    for i, callback in ipairs(config.enabled) do
        local ok, result = pcall(callback)
        if not ok then
            M.notify('Error in enabled callback: ' .. tostring(result), 'error', vim.log.levels.ERROR)
            trigger = false
            break
        end
        if not result then
            M.notify(
                string.format('should_trigger check: callback N%d, result=%s', i, tostring(result)),
                'debug',
                vim.log.levels.DEBUG
            )
            trigger = false
            break
        end
    end

    return trigger
end

return M
