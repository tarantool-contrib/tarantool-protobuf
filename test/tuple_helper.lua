-- Shared box setup for the pb.tuple tests.
--
-- luatest runs every test file in one Tarantool process, and box.cfg is
-- process-global: the first file to need a space configures box, every
-- later call is a no-op. Data goes to a fresh temporary directory, never
-- the working directory. The log is not configured here: the luatest
-- runner has already set it up (through log.cfg, into its own var
-- directory), and box.cfg refuses to change `log` after that.
local fio = require('fio')

local M = {}

function M.ensure_box()
    if type(box.cfg) ~= 'function' then
        return
    end
    local dir = fio.tempdir()
    box.cfg{
        wal_mode  = 'none',
        memtx_dir = dir,
        wal_dir   = dir,
    }
end

-- A GC step multiplier large enough for one step to finish a whole
-- cycle, for tests that make a chosen allocation run a full collection.
-- LuaJIT gives a step a budget of (GCSTEPSIZE / 100) * stepmul = 10 *
-- stepmul, and keeps working while the budget reads as positive. Without
-- GC64 the budget is a 32-bit counter tested as a signed one, so it has
-- to stay below 2^31: 2^30 would wrap to exactly 2^31, read as negative,
-- and end every step after a single increment (GC64 builds, with a
-- 64-bit budget, do not notice). 2^27 gives a budget of about 1.3e9,
-- far above the work of a cycle over a test process's heap.
M.GC_FULL_CYCLE_STEPMUL = 2^27

-- Drop the space if it exists and create it again with `format`, plus a
-- primary index on the first field.
function M.make_space(name, format)
    M.ensure_box()
    if box.space[name] ~= nil then
        box.space[name]:drop()
    end
    local s = box.schema.space.create(name, {format = format})
    s:create_index('pk', {parts = {1}})
    return s
end

return M
