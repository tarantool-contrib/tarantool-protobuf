#!/usr/bin/env tarantool
--
-- protoc-gen-tarantool / pb runtime conformance test runner.
--
-- Speaks the Google protobuf conformance protocol on stdin/stdout: each
-- request and response is a little-endian uint32 length followed by a
-- `conformance.ConformanceRequest` / `conformance.ConformanceResponse`
-- serialized as protobuf. Loops until EOF.
--
-- Run against the canonical Google conformance binary like so:
--
--     conformance_test_runner --enforce_recommended \
--         tarantool cmd/conformance-runner.lua
--
-- LUA_PATH must let this script find `pb`, the generated modules, and
-- the conformance core module under `cmd/`:
--
--     LUA_PATH="./runtime/?/init.lua;./runtime/?.lua;\
--               ./examples/expected/?.lua;./examples/expected/?/init.lua;\
--               ./cmd/?.lua;;"

-- Make the script self-contained: derive package.path from this script's
-- own location instead of trusting LUA_PATH. `conformance_test_runner`
-- spawns the child with a stripped (or otherwise unhelpful) environment;
-- if we crash on the first require() the parent reads no reply and
-- reports the test as a timeout. Setting paths here avoids that.
local function script_dir()
    local src = debug.getinfo(1, 'S').source
    if src:sub(1, 1) == '@' then src = src:sub(2) end
    return src:match('^(.*/)[^/]+$') or './'
end
local SCRIPT_DIR = script_dir()
local REPO_ROOT  = SCRIPT_DIR .. '..'
package.path = table.concat({
    REPO_ROOT .. '/runtime/?/init.lua',
    REPO_ROOT .. '/runtime/?.lua',
    REPO_ROOT .. '/examples/expected/?.lua',
    REPO_ROOT .. '/examples/expected/?/init.lua',
    REPO_ROOT .. '/cmd/?.lua',
    REPO_ROOT .. '/cmd/?/init.lua',
    package.path,
}, ';')
-- package.searchpath returns the first existing file, not the first
-- loadable one. Cross-platform bind mounts (host macOS .dylib and
-- container Linux .so coexisting in the tree after `just conformance-c`)
-- can mask the correct binary if the wrong extension is listed first.
-- Order by host platform.
local _ext_first, _ext_second = '.so', '.dylib'
if jit and jit.os == 'OSX' then
    _ext_first, _ext_second = '.dylib', '.so'
end
package.cpath = table.concat({
    REPO_ROOT .. '/runtime/?' .. _ext_first,
    REPO_ROOT .. '/runtime/?' .. _ext_second,
    REPO_ROOT .. '/runtime/?/init' .. _ext_first,
    REPO_ROOT .. '/runtime/?/init' .. _ext_second,
    package.cpath,
}, ';')

-- Force our `pb` to win over any `lua-protobuf` (starwing) `.rocks/lib/
-- tarantool/pb.so` left behind by transitive dependencies (luatest
-- pulls it in). Tarantool's rocks-aware loader runs ahead of the
-- override package.path/cpath above, so we pre-populate package.loaded.
-- Submodules (`pb.codec`, etc.) have unique names and resolve via the
-- prepended package.path without collision.
package.loaded.pb = dofile(REPO_ROOT .. '/runtime/pb/init.lua')

local core = require('cmd.conformance.core')

-- When invoked by conformance_test_runner the child's stdin is a pipe.
-- Default C-stdio buffering can hold the request bytes inside libc until
-- BUFSIZ-aligned data arrives, which never happens because the parent is
-- waiting for our reply first. Disable input buffering so io.stdin:read(n)
-- returns as soon as `n` bytes are available; pair with unbuffered stdout
-- so we don't rely solely on per-write :flush().
io.stdin:setvbuf('no')
io.stdout:setvbuf('no')

local function read_n(n)
    local got = io.stdin:read(n)
    if got == nil or #got < n then return nil end
    return got
end

local function read_request_bytes()
    local hdr = read_n(4)
    if hdr == nil then return nil end
    local b1, b2, b3, b4 = hdr:byte(1, 4)
    return read_n(b1 + b2 * 256 + b3 * 65536 + b4 * 16777216)
end

local function write_response_bytes(payload)
    local n = #payload
    io.stdout:write(string.char(
        n % 256,
        math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 16777216) % 256))
    io.stdout:write(payload)
    io.stdout:flush()
end

while true do
    local req_bytes = read_request_bytes()
    if req_bytes == nil then break end
    write_response_bytes(core.handle_request(req_bytes))
end

os.exit(0)
