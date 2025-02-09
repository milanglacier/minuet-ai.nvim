local M = {}

function M.notify_breaking_change_only_once(message, filename, date)
    ---@diagnostic disable-next-line
    local file = vim.fs.joinpath(vim.fn.stdpath 'cache', 'minuet-' .. filename .. '-' .. date)

    if vim.fn.filereadable(file) == 1 then
        return
    end

    vim.notify(
        'Please confirm that you have fully read the documentation (yes/no).'
            .. '\nThis notification will only appear once after you choose "yes".\n'
            .. message
            .. ' as of '
            .. date,
        vim.log.levels.WARN
    )

    vim.defer_fn(function()
        vim.ui.select({
            1,
            2,
        }, {
            prompt = message,
            format_item = function(item)
                local format = {
                    'Yes, I have understand what is happening here.\nNotification will not be sent again.',
                    'No, Please send the notification again after relaunch.',
                }
                return format[item]
            end,
        }, function(choice)
            if choice == 1 then
                local f = io.open(file, 'w')
                if not f then
                    vim.notify('Cannot open temporary message file: ' .. file, vim.log.levels.ERROR)
                    return
                end
                f:close()
            end
        end)
    end, 500)
end

return M
