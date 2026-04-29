-- ---------------------------------------------------------------------------
-- Fallback task — fires when nothing higher-priority should run.
-- Always last in the task list.
-- ---------------------------------------------------------------------------

local task = {
    name   = 'idle',
    status = nil,
}

task.shouldExecute = function ()
    return true
end

task.Execute = function () end

return task
