-- Benchmarks the duet edit recorder's main resource costs:
--   1. per-change debounce and autocmd callback overhead
--   2. full-buffer snapshot and diff latency for sparse and bulk edits
--   3. Lua heap retained by per-buffer baselines
--
-- Run from the repository root with:
--   nvim --headless -u NONE -i NONE --cmd "set noswapfile" \
--     +"luafile tests/duet_edits_bench.lua" +"qa!"

local api = vim.api

---@diagnostic disable-next-line: deprecated
local diff = (vim.text and vim.text.diff) or vim.diff

---@param bufnr integer
---@return string
local function snapshot(bufnr)
    return table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n') .. '\n'
end

---@param line_count integer
---@return string[]
local function make_source_lines(line_count)
    local lines = {}
    for i = 1, line_count do
        lines[i] = string.format('local function name_%d(a, b) return a + b + %d end', i, i)
    end
    return lines
end

---@param line_count integer
local function benchmark_diff_patterns(line_count)
    local bufnr = api.nvim_create_buf(true, false)
    local original = make_source_lines(line_count)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, original)
    local baseline = snapshot(bufnr)

    for _, i in ipairs {
        10,
        math.floor(line_count / 4),
        math.floor(line_count / 2),
        math.floor(line_count * 3 / 4),
        line_count - 10,
    } do
        api.nvim_buf_set_lines(bufnr, i, i + 1, false, {
            'local function renamed_' .. i .. '(a, b, c) return a * b * c end',
        })
    end

    local started = vim.uv.hrtime()
    local current = snapshot(bufnr)
    local sparse_diff = diff(baseline, current, {
        result_type = 'unified',
        ctxlen = 3,
        algorithm = 'histogram',
    })
    local sparse_ms = (vim.uv.hrtime() - started) / 1e6

    local replacement = {}
    for i = 1, line_count do
        replacement[i] = string.format('local function replaced_%d(a, b) return a * b * %d end', i, i)
    end
    api.nvim_buf_set_lines(bufnr, 0, -1, false, replacement)

    started = vim.uv.hrtime()
    current = snapshot(bufnr)
    local replacement_diff = diff(baseline, current, {
        result_type = 'unified',
        ctxlen = 3,
        algorithm = 'histogram',
    })
    local replacement_ms = (vim.uv.hrtime() - started) / 1e6

    print(
        string.format(
            '%5d lines, %4.0f KB: sparse %.2f ms (%d-byte diff); full replacement %.2f ms (%.2f MB diff)',
            line_count,
            #baseline / 1024,
            sparse_ms,
            #sparse_diff,
            replacement_ms,
            #replacement_diff / 1024 / 1024
        )
    )

    api.nvim_buf_delete(bufnr, { force = true })
end

local function benchmark_change_callback()
    local helpers = require 'tests.helpers'
    helpers.setup_root_config {
        duet = {
            recent_edits = {
                debounce = 60000,
            },
        },
    }

    local edits = require 'minuet.duet.edits'
    local group = api.nvim_create_augroup('MinuetDuetHotpathBench', { clear = true })
    edits.setup(group)

    local timer = vim.uv.new_timer()
    local iterations = 100000
    local started = vim.uv.hrtime()
    for _ = 1, iterations do
        timer:stop()
        timer:start(60000, 0, function() end)
    end
    local timer_us = (vim.uv.hrtime() - started) / 1e3 / iterations
    timer:stop()
    timer:close()

    collectgarbage 'collect'
    started = vim.uv.hrtime()
    for _ = 1, iterations do
        api.nvim_exec_autocmds('TextChangedI', { buffer = 0 })
    end
    local callback_us = (vim.uv.hrtime() - started) / 1e3 / iterations

    collectgarbage 'collect'
    local heap_before = collectgarbage 'count'
    collectgarbage 'stop'
    for _ = 1, iterations do
        api.nvim_exec_autocmds('TextChangedI', { buffer = 0 })
    end
    local heap_before_gc = collectgarbage 'count'
    collectgarbage 'restart'
    collectgarbage 'collect'

    print(string.format('timer restart: %.2f us/event', timer_us))
    print(string.format('full TextChangedI recorder callback: %.2f us/event', callback_us))
    local callback_allocated_kb = heap_before_gc - heap_before
    print(
        string.format(
            'callback allocations with GC paused: %.2f MB total (%.0f bytes/event; reclaimed)',
            callback_allocated_kb / 1024,
            callback_allocated_kb * 1024 / iterations
        )
    )

    edits.reset()
    api.nvim_del_augroup_by_id(group)
end

local function benchmark_baseline_memory()
    local helpers = require 'tests.helpers'
    helpers.setup_root_config {
        duet = {
            recent_edits = {
                max_buffer_size = 1000000,
            },
        },
    }

    local edits = require 'minuet.duet.edits'
    local buffers = {}
    local repeated_text = string.rep('x', 890)

    for buffer_index = 1, 20 do
        local bufnr = api.nvim_create_buf(true, false)
        local lines = {}
        for line_index = 1, 1000 do
            lines[line_index] = repeated_text .. string.format('%04d:%04d', buffer_index, line_index)
        end
        api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        table.insert(buffers, bufnr)
    end

    collectgarbage 'collect'
    local heap_after_buffers = collectgarbage 'count'
    for _, bufnr in ipairs(buffers) do
        edits.track(bufnr)
    end
    collectgarbage 'collect'
    local heap_after_tracking = collectgarbage 'count'

    local first = buffers[1]
    local buffer_bytes = api.nvim_buf_get_offset(first, api.nvim_buf_line_count(first))
    local baseline_heap_kb = heap_after_tracking - heap_after_buffers

    print(string.format('buffers: %d x %.0f KB', #buffers, buffer_bytes / 1024))
    print(string.format('Lua heap retained by edit baselines: %.2f MB', baseline_heap_kb / 1024))
    print(string.format('retained baseline per buffer: %.0f KB', baseline_heap_kb / #buffers))

    edits.reset()
    for _, bufnr in ipairs(buffers) do
        api.nvim_buf_delete(bufnr, { force = true })
    end
end

print 'Diff latency'
for _, line_count in ipairs { 2000, 10000, 18000 } do
    benchmark_diff_patterns(line_count)
end

print '\nChange callback'
benchmark_change_callback()

print '\nBaseline memory'
benchmark_baseline_memory()
