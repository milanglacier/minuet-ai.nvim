local M = {}
local config = require('minuet').config

function M.notify(msg, minuet_level, vim_level, opts)
    local notify_levels = {
        verbose = 0,
        warn = 1,
        error = 2,
    }

    if config.notify and notify_levels[minuet_level] >= notify_levels[config.notify] then
        vim.notify(msg, vim_level, opts)
    end
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

function M.add_language_comment()
    if vim.bo.ft == nil or vim.bo.ft == '' then
        return ''
    end

    if vim.bo.commentstring == nil or vim.bo.commentstring == '' then
        return '# language: ' .. vim.bo.ft
    end

    -- escape % in comment string
    local commentstring = vim.bo.commentstring:gsub('^%% ', '%%%% '):gsub('%%$', '%%%%')

    return string.format(commentstring, string.format('language: %s', vim.bo.ft))
end

function M.add_tab_comment()
    if vim.bo.ft == nil or vim.bo.ft == '' then
        return ''
    end

    local tab_comment

    if vim.bo.expandtab and vim.bo.softtabstop > 0 then
        tab_comment = 'indentation: use ' .. vim.bo.softtabstop .. ' spaces for a tab'

        if vim.bo.commentstring == nil or vim.bo.commentstring == '' then
            return '# ' .. tab_comment
        end

        local commentstring = vim.bo.commentstring:gsub('^%% ', '%%%% '):gsub('%%$', '%%%%')

        return string.format(commentstring, tab_comment)
    end

    if not vim.bo.expandtab then
        tab_comment = 'indentation: use \t for a tab'
        if vim.bo.commentstring == nil or vim.bo.commentstring == '' then
            return '# ' .. tab_comment
        end

        local commentstring = vim.bo.commentstring:gsub('^%% ', '%%%% '):gsub('%%$', '%%%%')

        return string.format(commentstring, tab_comment)
    end

    return ''
end

-- Copied from blink.cmp.Context. Because we might use nvim-cmp instead of
-- blink-cmp, so blink might not be installed, so we create another class here
-- and use it instead.

--- @class blinkCmpContext
--- @field line string
--- @field cursor number[]

---@param blink_context blinkCmpContext?
function M.make_cmp_context(blink_context)
    local self = {}
    local cursor
    if blink_context then
        cursor = blink_context.cursor
        self.cursor_line = blink_context.line
    else
        cursor = vim.api.nvim_win_get_cursor(0)
        self.cursor_line = vim.api.nvim_get_current_line()
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

function M.get_context(cmp_context)
    local cursor = cmp_context.cursor
    local lines_before_list = vim.api.nvim_buf_get_lines(0, 0, cursor.line, false)
    local lines_after_list = vim.api.nvim_buf_get_lines(0, cursor.line + 1, -1, false)

    local lines_before = table.concat(lines_before_list, '\n')
    local lines_after = table.concat(lines_after_list, '\n')

    lines_before = lines_before .. '\n' .. cmp_context.cursor_before_line
    lines_after = cmp_context.cursor_after_line .. '\n' .. lines_after

    local n_chars_before = vim.fn.strchars(lines_before)
    local n_chars_after = vim.fn.strchars(lines_after)

    if n_chars_before + n_chars_after > config.context_window then
        -- use some heuristic to decide the context length of before cursor and after cursor
        if n_chars_before < config.context_window * config.context_ratio then
            -- If the context length before cursor does not exceed the maximum
            -- size, we include the full content before the cursor.
            lines_after = vim.fn.strcharpart(lines_after, 0, config.context_window - n_chars_before)
        elseif n_chars_after < config.context_window * (1 - config.context_ratio) then
            -- if the context length after cursor does not exceed the maximum
            -- size, we include the full content after the cursor.
            lines_before = vim.fn.strcharpart(lines_before, n_chars_before + n_chars_after - config.context_window)
        else
            -- at the middle of the file, use the context_ratio to determine the allocation
            lines_after =
                vim.fn.strcharpart(lines_after, 0, math.floor(config.context_window * (1 - config.context_ratio)))

            lines_before = vim.fn.strcharpart(
                lines_before,
                n_chars_before - math.floor(config.context_window * config.context_ratio)
            )
        end
    end

    return {
        lines_before = lines_before,
        lines_after = lines_after,
    }
end

function M.make_context_filter_sequence(context, length)
    if not context then
        return
    end

    -- remove leading whitespaces
    context = context:gsub('^%s+', '')

    if vim.fn.strchars(context) < length then
        return
    end

    context = vim.fn.strcharpart(context, 0, length)

    -- remove trailing whitespaces
    context = context:gsub('%s+$', '')

    return context
end

---remove the sequence and the rest part from text.
---@param text string?
---@param sequence string?
---@return string?
function M.filter_text(text, sequence)
    if not sequence or not text then
        return text
    end

    if sequence == '' then
        return text
    end
    -- use plain match
    local start = string.find(text, sequence, 1, true)
    if not start then
        return text
    end
    return string.sub(text, 1, start - 1)
end

--- Remove the trailing and leading spaces for each string in the table
---@param items_table table[string]
function M.remove_spaces(items_table)
    local new = {}

    for _, item in ipairs(items_table) do
        if item:find '%S' then -- only include entries that contains non-whitespace
            -- replace the trailing spaces
            item = item:gsub('%s+$', '')
            -- replace the leading spaces
            item = item:gsub('^%s+', '')
            table.insert(new, item)
        end
    end

    return new
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

function M.make_chat_llm_shot(context_before_cursor, context_after_cursor)
    local language = M.add_language_comment()
    local tab = M.add_tab_comment()

    local context = language
        .. '\n'
        .. tab
        .. '\n'
        .. '<contextAfterCursor>'
        .. '\n'
        .. context_after_cursor
        .. '\n'
        .. '<contextBeforeCursor>'
        .. '\n'
        .. context_before_cursor
        .. '<cursorPosition>'

    return context
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
        M.notify('Failed to parse ' .. provider .. ' API response as json', 'error', vim.log.levels.INFO)
        return
    end

    local result_str

    success, result_str = pcall(get_text_fn, json)

    if not success or not result_str then
        M.notify(provider .. ' returns no text: ' .. vim.inspect(json), 'verbose', vim.log.levels.INFO)
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
        M.notify(provider .. ' returns no text on streaming: ' .. vim.inspect(responses), 'verbose', vim.log.levels.INFO)
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

return M
