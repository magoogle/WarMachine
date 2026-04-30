-- activities/boss/tasks/idle.lua  --  no-op terminator (matches helltide/idle.lua)

local task = { name = 'idle', status = 'idle' }
task.shouldExecute = function () return true end
task.Execute       = function () end
return task
