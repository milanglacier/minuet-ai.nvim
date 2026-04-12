local M = {}

M.current_jobs = {}

local function register_job(job)
    table.insert(M.current_jobs, job)
end

local function remove_job(job)
    for index, current_job in ipairs(M.current_jobs) do
        if current_job.pid == job.pid then
            table.remove(M.current_jobs, index)
            break
        end
    end
end

function M.terminate_all_jobs()
    for _, job in ipairs(M.current_jobs) do
        pcall(job.kill, job, 'sigterm')
    end

    M.current_jobs = {}
end

function M.start_job(command, args, handlers)
    local cmd = { command }
    vim.list_extend(cmd, args)

    local job
    local ok, result = pcall(
        vim.system,
        cmd,
        { text = true },
        vim.schedule_wrap(function(out)
            if not job then
                return
            end

            remove_job(job)
            handlers.on_exit(job, out)
        end)
    )

    if not ok then
        if handlers.on_spawn_error then
            handlers.on_spawn_error()
        end
        return nil
    end

    job = result
    register_job(job)

    return job
end

function M.apply_transforms(transform, end_point, headers, body)
    local transformed_data = {
        end_point = end_point,
        headers = headers,
        body = body,
    }

    for _, fun in ipairs(transform or {}) do
        transformed_data = fun(transformed_data)
    end

    return transformed_data
end

return M
