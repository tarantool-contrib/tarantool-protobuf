-- Splits a generated *_pb.lua into its code and its embedded descriptors.
--
-- Usage: tarantool test/toolchains/split.lua <module.lua> <outdir>
--
-- Every `table.concat({` ... `})` block in a generated module is a
-- serialized FileDescriptorProto: M._file_descriptor and the snapshots
-- of its imports (cmd/protoc-gen-tarantool/internal/gen/filedesc.go).
-- The block's string literals are evaluated and written, in order, to
-- <outdir>/desc.<n>.bin; the module's text, with each block replaced by
-- `table.concat(<descriptor n>)`, goes to <outdir>/code.lua. Two
-- modules then compare as: identical code.lua, and each pair of
-- desc.<n>.bin equal once decoded (see test/toolchains/compare.sh).
--
-- Prints the number of descriptors found.
local fio = require('fio')

local src, outdir = arg[1], arg[2]
if src == nil or outdir == nil then
    io.stderr:write('usage: tarantool split.lua <module.lua> <outdir>\n')
    os.exit(2)
end

local function slurp(path)
    local f = assert(io.open(path, 'rb'))
    local s = f:read('*a')
    f:close()
    return s
end

local function spit(path, s)
    local f = assert(io.open(path, 'wb'))
    f:write(s)
    f:close()
end

assert(fio.mktree(outdir))

local code, body = {}, nil
local n = 0
for line in (slurp(src) .. '\n'):gmatch('(.-)\n') do
    if body ~= nil then
        if line:match('^}%)') then
            local chunk = assert(loadstring('return {' .. table.concat(body, '\n') .. '}',
                                            src .. ': descriptor ' .. n))
            spit(('%s/desc.%d.bin'):format(outdir, n), table.concat(chunk()))
            code[#code + 1] = ('<descriptor %d>%s'):format(n, line:sub(2))
            body = nil
        else
            body[#body + 1] = line
        end
    elseif line:match('table%.concat%({$') then
        n = n + 1
        body = {}
        code[#code + 1] = line:sub(1, -2)
    else
        code[#code + 1] = line
    end
end
if body ~= nil then
    io.stderr:write(src .. ': unterminated table.concat block\n')
    os.exit(1)
end

spit(outdir .. '/code.lua', table.concat(code, '\n'))
print(n)
os.exit(0)
