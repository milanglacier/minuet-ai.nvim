local root = vim.fn.getcwd()

vim.opt.runtimepath:prepend(root)
package.path = table.concat({
    root .. '/?.lua',
    root .. '/?/init.lua',
    root .. '/lua/?.lua',
    root .. '/lua/?/init.lua',
    root .. '/tests/?.lua',
    root .. '/tests/?/init.lua',
    package.path,
}, ';')

local spec_files = vim.fn.globpath(root .. '/tests', '*_spec.lua', false, true)
table.sort(spec_files)

local cases = {}
for _, file in ipairs(spec_files) do
    local ok, loaded = pcall(dofile, file)
    if not ok then
        error(('failed to load spec %s\n%s'):format(file, loaded))
    end

    for _, case in ipairs(loaded) do
        case.file = file
        table.insert(cases, case)
    end
end

local function writeln(line, opts)
    vim.api.nvim_echo({ { line .. '\n' } }, true, opts or {})
end

local M = {}

function M.run()
    local failures = {}

    writeln(('running %d test(s)'):format(#cases))

    for _, case in ipairs(cases) do
        local ok, err = xpcall(case.run, debug.traceback)
        if ok then
            writeln(('PASS %s'):format(case.name))
        else
            writeln(('FAIL %s'):format(case.name), { err = true })
            table.insert(failures, {
                name = case.name,
                file = case.file,
                err = err,
            })
        end
    end

    if #failures == 0 then
        writeln 'all tests passed'
        vim.cmd 'qa!'
        return
    end

    writeln(('%d test(s) failed'):format(#failures), { err = true })
    for _, failure in ipairs(failures) do
        writeln(('%s (%s)'):format(failure.name, failure.file), { err = true })
        writeln(failure.err, { err = true })
    end

    vim.cmd(('cquit %d'):format(#failures))
end

return M
