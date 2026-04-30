local task = { name = 'idle', status = 'idle' }
task.shouldExecute = function () return false end
task.Execute       = function () end
return task
