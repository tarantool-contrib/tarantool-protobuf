-- The one switch for the optional C runtime.
--
-- `pb.c_runtime` is used only when PB_ENABLE_C=1 is set in the
-- environment at load time AND `require('pb.c_runtime')` succeeds. A
-- failed require (no .so built, ABI mismatch, a Tarantool too old for
-- the symbols it links) leaves the pure-Lua path in place — see
-- docs/specs/c_accel_compat.md § Activation for the contract.
--
-- Every module that dispatches to C reads `runtime` from here, so the
-- codec and pb.tuple always agree on whether C is active. The decision
-- is made once, when this module is first required.
local runtime
if os.getenv('PB_ENABLE_C') == '1' then
    local ok, mod = pcall(require, 'pb.c_runtime')
    if ok then runtime = mod end
end

return {
    -- The loaded C runtime module, or nil when the Lua path is in use.
    runtime = runtime,
}
