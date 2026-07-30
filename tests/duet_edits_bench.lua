-- Benchmarks the duet edit recorder's main resource costs:
--   1. per-change debounce and autocmd callback overhead
--   2. temp-file snapshot write and end-to-end async flush latency for
--      sparse and bulk edits (write pending file + external diff + record)
--   3. Lua heap retained by per-buffer tracking state (paths and ticks; the
--      snapshot text itself lives on disk, not the Lua heap)
--
-- Run from the repository root with:
--   nvim --headless -u NONE -i NONE --cmd "set noswapfile" \
--     +"luafile tests/duet_edits_bench.lua" +"qa!"

local api = vim.api

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
local function benchmark_flush_patterns(line_count)
    local helpers = require 'tests.helpers'
    helpers.setup_root_config {
        duet = {
            recent_edits = {
                -- Never let the bounded wait truncate a measured flush or
                -- leak an in-flight diff into the next measurement.
                flush_timeout = 30000,
                -- Keep even the full-replacement diff as an event so the
                -- measurement covers the entire record path.
                max_event_chars = 1e9,
                max_total_chars = 1e9,
                max_buffer_size = 2000000,
            },
        },
    }
    local edits = require 'minuet.duet.edits'

    local bufnr = api.nvim_create_buf(true, false)
    local original = make_source_lines(line_count)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, original)
    local buffer_bytes = api.nvim_buf_get_offset(bufnr, api.nvim_buf_line_count(bufnr))

    local snapshot_path = vim.fn.tempname()
    local started = vim.uv.hrtime()
    vim.fn.writefile(api.nvim_buf_get_lines(bufnr, 0, -1, false), snapshot_path, 'S')
    local write_ms = (vim.uv.hrtime() - started) / 1e6
    vim.uv.fs_unlink(snapshot_path)

    edits.track(bufnr)

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

    started = vim.uv.hrtime()
    edits.flush(bufnr, { wait = true })
    local sparse_ms = (vim.uv.hrtime() - started) / 1e6
    local events = edits.get_events()
    local sparse_bytes = #events > 0 and #events[#events].diff or 0

    local replacement = {}
    for i = 1, line_count do
        replacement[i] = string.format('local function replaced_%d(a, b) return a * b * %d end', i, i)
    end
    api.nvim_buf_set_lines(bufnr, 0, -1, false, replacement)

    started = vim.uv.hrtime()
    edits.flush(bufnr, { wait = true })
    local replacement_ms = (vim.uv.hrtime() - started) / 1e6
    events = edits.get_events()
    local replacement_bytes = #events > 0 and #events[#events].diff or 0

    print(
        string.format(
            '%5d lines, %4.0f KB: snapshot write %.2f ms; sparse flush %.2f ms (%d-byte diff);'
                .. ' full replacement flush %.2f ms (%.2f MB diff)',
            line_count,
            buffer_bytes / 1024,
            write_ms,
            sparse_ms,
            sparse_bytes,
            replacement_ms,
            replacement_bytes / 1024 / 1024
        )
    )

    edits.reset()
    api.nvim_buf_delete(bufnr, { force = true })
end

local function benchmark_change_callback()
    local helpers = require 'tests.helpers'
    helpers.setup_root_config {
        duet = {
            recent_edits = {
                enabled = true,
                debounce = 60000,
            },
        },
    }

    local edits = require 'minuet.duet.edits'
    edits.setup()

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
    api.nvim_del_augroup_by_name 'MinuetDuetEdits'
end

local function benchmark_tracking_memory()
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
    local tracking_heap_kb = heap_after_tracking - heap_after_buffers

    print(string.format('buffers: %d x %.0f KB', #buffers, buffer_bytes / 1024))
    print(string.format('Lua heap retained by edit tracking state: %.2f KB', tracking_heap_kb))
    print(
        string.format('retained per buffer: %.2f KB (snapshot text lives in temp files)', tracking_heap_kb / #buffers)
    )

    edits.reset()
    for _, bufnr in ipairs(buffers) do
        api.nvim_buf_delete(bufnr, { force = true })
    end
end

print 'Snapshot and flush latency'
for _, line_count in ipairs { 2000, 10000, 18000 } do
    benchmark_flush_patterns(line_count)
end

print '\nChange callback'
benchmark_change_callback()

print '\nTracking state memory'
benchmark_tracking_memory()
