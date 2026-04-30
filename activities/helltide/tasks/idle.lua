-- Helltide idle fallback.  Always returns false so it sits at the bottom
-- of the runner list; if it's reached, every other task chose to yield.
local task = { name = 'idle', status = 'idle' }
task.shouldExecute = function () return false end
task.Execute       = function () end
return task
