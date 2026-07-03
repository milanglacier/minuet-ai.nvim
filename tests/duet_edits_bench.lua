-- Benchmarks the duet edit-recorder hot paths:
--   1. per-keystroke cost: restarting the debounce timer
--   2. per-flush cost: full-buffer snapshot + vim.diff (unified, histogram)
--
-- Run with:
--   nvim --headless -u NONE +"luafile tests/duet_edits_bench.lua" +"qa!"
--
-- Baseline (2026-07-03, 10k lines / 535 KB): timer restart ~0.19 us per
-- keystroke; full flush (get_lines + concat + vim.diff) ~2 ms.

local N = 10000 -- 10k-line file (large; most source files are far smaller)
local lines = {}
for i = 1, N do
    lines[i] = string.format('local function name_%d(a, b) return a + b + %d end', i, i)
end
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)

---@diagnostic disable-next-line: deprecated
local diff = (vim.text and vim.text.diff) or vim.diff

-- baseline capture (what track/flush does)
local t0 = vim.uv.hrtime()
local baseline = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n') .. '\n'
local t1 = vim.uv.hrtime()

-- simulate an edit burst: change 5 scattered lines
for _, i in ipairs { 100, 2500, 5000, 7500, 9900 } do
    vim.api.nvim_buf_set_lines(0, i, i + 1, false, {
        'local function renamed_' .. i .. '(a, b, c) return a * b * c end',
    })
end

local t2 = vim.uv.hrtime()
local current = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n') .. '\n'
local unified = diff(baseline, current, { result_type = 'unified', ctxlen = 3, algorithm = 'histogram' })
local t3 = vim.uv.hrtime()

-- timer restart cost (the per-keystroke operation)
local timer = vim.uv.new_timer()
local t4 = vim.uv.hrtime()
for _ = 1, 1000 do
    timer:stop()
    timer:start(1500, 0, function() end)
end
local t5 = vim.uv.hrtime()
timer:stop()
timer:close()

print(string.format('buffer size: %d lines, %.0f KB', N, #baseline / 1024))
print(string.format('snapshot (get_lines+concat): %.2f ms', (t1 - t0) / 1e6))
print(string.format('flush (snapshot + vim.diff): %.2f ms', (t3 - t2) / 1e6))
print(string.format('timer restart (per keystroke): %.2f us', (t5 - t4) / 1e3 / 1000))
print(string.format('diff output size: %d bytes', #unified))
vim.bo.modified = false -- allow :qa! without E37
