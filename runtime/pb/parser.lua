-- Pure-Lua .proto file parser (proto2 + proto3).
--
-- The output AST is intentionally minimal — descriptor synthesis lives in
-- `pb.dynamic`, which converts the AST into the runtime descriptor format
-- used by `pb.encode` / `pb.decode`.
--
-- Supported:
--   syntax = "proto2" | "proto3"
--   package, import (recorded but not resolved across files)
--   message + nested messages + nested enums + oneofs + maps
--   enum (top-level + nested)
--   service { rpc Method(In) returns (Out); }
--   proto2 `required` / `optional` keywords (presence + custom defaults)
--   proto3 explicit `optional`
--   field options including `[default = X]`, `[packed = true|false]`
--
-- Not yet:
--   custom options past simple `option name = value;` (skipped)
--   extensions, reserved fields (skipped harmlessly)
--   proto2 `extend` blocks and `group` (deprecated)
local M = {}

-- ---------------------------------------------------------------------------
-- Tokenizer
-- ---------------------------------------------------------------------------

local function tokenize(source)
    local tokens = {}
    local pos = 1
    local len = #source

    while pos <= len do
        local ws_start, ws_end = source:find('^%s+', pos)
        if ws_start then pos = ws_end + 1 end
        if pos > len then break end

        if source:sub(pos, pos + 1) == '//' then
            local nl = source:find('\n', pos)
            pos = nl and nl + 1 or len + 1
        elseif source:sub(pos, pos + 1) == '/*' then
            local close = source:find('%*/', pos + 2)
            pos = close and close + 2 or len + 1
        elseif source:sub(pos, pos) == '"' then
            local str_end = pos + 1
            while str_end <= len do
                local c = source:sub(str_end, str_end)
                if c == '"' then break
                elseif c == '\\' then str_end = str_end + 2
                else str_end = str_end + 1 end
            end
            tokens[#tokens + 1] = {type = 'string', value = source:sub(pos + 1, str_end - 1)}
            pos = str_end + 1
        elseif source:match('^%-?%d', pos) then
            local num_end = source:find('[^%d%.xXa-fA-FeE%+%-]', pos + 1) or len + 1
            tokens[#tokens + 1] = {type = 'number', value = source:sub(pos, num_end - 1)}
            pos = num_end
        elseif source:match('^[a-zA-Z_]', pos) then
            local id_end = source:find('[^a-zA-Z0-9_.]', pos + 1) or len + 1
            tokens[#tokens + 1] = {type = 'ident', value = source:sub(pos, id_end - 1)}
            pos = id_end
        else
            tokens[#tokens + 1] = {type = 'punct', value = source:sub(pos, pos)}
            pos = pos + 1
        end
    end
    return tokens
end

-- ---------------------------------------------------------------------------
-- Parser
-- ---------------------------------------------------------------------------

local function parse(tokens)
    local pos = 1
    local result = {
        syntax = 'proto3',
        package = '',
        imports = {},
        messages = {},      -- declaration-ordered: messages[i] = {name=, ...}
        enums = {},         -- declaration-ordered: enums[i] = {name=, values=}
        services = {},
    }

    local function peek() return tokens[pos] end
    local function consume(typ, val)
        local tok = tokens[pos]
        if not tok then error("protobuf parser: unexpected end of input", 0) end
        if typ and tok.type ~= typ then
            error(("protobuf parser: expected %s, got %s (%q) at token %d")
                :format(typ, tok.type, tok.value or '', pos), 0)
        end
        if val and tok.value ~= val then
            error(("protobuf parser: expected %q, got %q at token %d")
                :format(val, tok.value, pos), 0)
        end
        pos = pos + 1
        return tok
    end
    local function match(typ, val)
        local tok = peek()
        if tok and tok.type == typ and (val == nil or tok.value == val) then
            return consume()
        end
        return nil
    end

    local function parse_option_value()
        local tok = peek()
        if tok.type == 'string' then return consume().value
        elseif tok.type == 'number' then return tonumber(consume().value)
        elseif tok.type == 'ident' then
            local v = consume().value
            if v == 'true' then return true end
            if v == 'false' then return false end
            return v
        end
        error("protobuf parser: invalid option value", 0)
    end

    local function parse_field_options()
        local options = {}
        if match('punct', '[') then
            repeat
                local name = consume('ident').value
                consume('punct', '=')
                options[name] = parse_option_value()
            until not match('punct', ',')
            consume('punct', ']')
        end
        return options
    end

    local function skip_to_semi()
        while not match('punct', ';') do consume() end
    end

    local function parse_enum()
        consume('ident', 'enum')
        local name = consume('ident').value
        consume('punct', '{')
        local enum = {name = name, values = {}}
        while not match('punct', '}') do
            if match('ident', 'option') or match('ident', 'reserved') then
                skip_to_semi()
            else
                local value_name = consume('ident').value
                consume('punct', '=')
                local value_num = tonumber(consume('number').value)
                parse_field_options()
                consume('punct', ';')
                enum.values[value_name] = value_num
            end
        end
        return enum
    end

    -- parse_message(preconsumed_name?) — consumes `message Name { … }` from
    -- the head of the token stream. When called with a non-nil name argument
    -- (the proto2 group desugaring path), the `message Name` part has
    -- already been recognized by the caller and only the `{ … }` body
    -- remains.
    local parse_message
    parse_message = function(preconsumed_name)
        local name
        if preconsumed_name then
            name = preconsumed_name
        else
            consume('ident', 'message')
            name = consume('ident').value
        end
        consume('punct', '{')
        local message = {
            name = name,
            fields = {},       -- declaration-ordered
            nested_messages = {},
            nested_enums = {},
            oneofs = {},       -- ordered: {name=, fields={}}
        }

        local function emit_field(field)
            message.fields[#message.fields + 1] = field
        end

        -- Proto2 group syntax desugars into (a) a nested message named
        -- after the group's capitalized identifier and (b) a field of
        -- kind=group referencing that submessage. The field's user-
        -- visible name is the lowercased group identifier (mainline
        -- proto behavior).
        local function emit_group_field(cardinality)
            -- `group` keyword already consumed by caller. Group field
            -- syntax: `group Name = id { body }` — no terminating `;`.
            local group_name = consume('ident').value
            consume('punct', '=')
            local fid = tonumber(consume('number').value)
            parse_field_options()
            local nested = parse_message(group_name)
            message.nested_messages[#message.nested_messages + 1] = nested
            local entry = {
                name = group_name:lower(), type = group_name, id = fid,
                kind = 'group',
            }
            if cardinality == 'optional' then entry.optional = true end
            if cardinality == 'required' then entry.required = true end
            if cardinality == 'repeated' then entry.repeated = true end
            emit_field(entry)
        end

        while not match('punct', '}') do
            local tok = peek()

            if tok.type == 'ident' and tok.value == 'message' then
                local nested = parse_message()
                message.nested_messages[#message.nested_messages + 1] = nested
            elseif tok.type == 'ident' and tok.value == 'enum' then
                local nested = parse_enum()
                message.nested_enums[#message.nested_enums + 1] = nested
            elseif tok.type == 'ident' and tok.value == 'oneof' then
                consume('ident', 'oneof')
                local oneof_name = consume('ident').value
                consume('punct', '{')
                local oneof_fields = {}
                while not match('punct', '}') do
                    local ft = consume('ident').value
                    local fn = consume('ident').value
                    consume('punct', '=')
                    local fid = tonumber(consume('number').value)
                    parse_field_options()
                    consume('punct', ';')
                    oneof_fields[#oneof_fields + 1] = fn
                    emit_field({name = fn, type = ft, id = fid, oneof = oneof_name})
                end
                message.oneofs[#message.oneofs + 1] = {name = oneof_name, fields = oneof_fields}
            elseif tok.type == 'ident' and tok.value == 'reserved' then
                consume()
                skip_to_semi()
            elseif tok.type == 'ident' and tok.value == 'option' then
                consume()
                skip_to_semi()
            elseif tok.type == 'ident' and tok.value == 'extensions' then
                consume()
                skip_to_semi()
            elseif tok.type == 'ident' and tok.value == 'optional' then
                -- proto3 explicit optional / every proto2 optional field
                consume()
                if match('ident', 'group') then
                    emit_group_field('optional', message)
                else
                    local ft = consume('ident').value
                    local fn = consume('ident').value
                    consume('punct', '=')
                    local fid = tonumber(consume('number').value)
                    local opts = parse_field_options()
                    consume('punct', ';')
                    emit_field({
                        name = fn, type = ft, id = fid, optional = true,
                        default_value = opts.default,
                    })
                end
            elseif tok.type == 'ident' and tok.value == 'required' then
                -- Proto2 `required`. The codec enforces presence on encode.
                consume()
                if match('ident', 'group') then
                    emit_group_field('required', message)
                else
                    local ft = consume('ident').value
                    local fn = consume('ident').value
                    consume('punct', '=')
                    local fid = tonumber(consume('number').value)
                    local opts = parse_field_options()
                    consume('punct', ';')
                    emit_field({
                        name = fn, type = ft, id = fid, required = true,
                        default_value = opts.default,
                    })
                end
            elseif tok.type == 'ident' and tok.value == 'repeated' then
                consume()
                if match('ident', 'group') then
                    emit_group_field('repeated', message)
                else
                    local ft = consume('ident').value
                    local fn = consume('ident').value
                    consume('punct', '=')
                    local fid = tonumber(consume('number').value)
                    local opts = parse_field_options()
                    consume('punct', ';')
                    emit_field({
                        name = fn, type = ft, id = fid, repeated = true,
                        packed = opts.packed,
                    })
                end
            elseif tok.type == 'ident' and tok.value == 'map' then
                consume()
                consume('punct', '<')
                local key_type = consume('ident').value
                consume('punct', ',')
                local value_type = consume('ident').value
                consume('punct', '>')
                local fn = consume('ident').value
                consume('punct', '=')
                local fid = tonumber(consume('number').value)
                parse_field_options()
                consume('punct', ';')
                emit_field({
                    name = fn, id = fid, kind = 'map',
                    key_type = key_type, value_type = value_type,
                })
            elseif tok.type == 'ident' then
                local ft = consume('ident').value
                local fn = consume('ident').value
                consume('punct', '=')
                local fid = tonumber(consume('number').value)
                parse_field_options()
                consume('punct', ';')
                emit_field({name = fn, type = ft, id = fid})
            else
                error(("protobuf parser: unexpected token %q in message %s")
                    :format(tok.value, name), 0)
            end
        end
        return message
    end

    local function parse_service()
        consume('ident', 'service')
        local name = consume('ident').value
        consume('punct', '{')
        local svc = {name = name, methods = {}}
        while not match('punct', '}') do
            if match('ident', 'option') then
                skip_to_semi()
            elseif match('ident', 'rpc') then
                local method_name = consume('ident').value
                consume('punct', '(')
                local client_streaming = match('ident', 'stream') ~= nil
                local input = consume('ident').value
                consume('punct', ')')
                consume('ident', 'returns')
                consume('punct', '(')
                local server_streaming = match('ident', 'stream') ~= nil
                local output = consume('ident').value
                consume('punct', ')')
                if match('punct', '{') then
                    while not match('punct', '}') do consume() end
                else
                    consume('punct', ';')
                end
                svc.methods[#svc.methods + 1] = {
                    name = method_name,
                    input = input,
                    output = output,
                    client_streaming = client_streaming,
                    server_streaming = server_streaming,
                }
            else
                consume()
            end
        end
        return svc
    end

    while pos <= #tokens do
        local tok = peek()
        if not tok then break end

        if tok.type == 'ident' and tok.value == 'syntax' then
            consume()
            consume('punct', '=')
            result.syntax = consume('string').value
            consume('punct', ';')
        elseif tok.type == 'ident' and tok.value == 'package' then
            consume()
            result.package = consume('ident').value
            consume('punct', ';')
        elseif tok.type == 'ident' and tok.value == 'import' then
            consume()
            match('ident', 'public')
            match('ident', 'weak')
            local path = consume('string').value
            result.imports[#result.imports + 1] = path
            consume('punct', ';')
        elseif tok.type == 'ident' and tok.value == 'option' then
            consume()
            skip_to_semi()
        elseif tok.type == 'ident' and tok.value == 'message' then
            result.messages[#result.messages + 1] = parse_message()
        elseif tok.type == 'ident' and tok.value == 'enum' then
            result.enums[#result.enums + 1] = parse_enum()
        elseif tok.type == 'ident' and tok.value == 'service' then
            result.services[#result.services + 1] = parse_service()
        else
            consume()  -- skip unknown top-level constructs
        end
    end
    return result
end

function M.tokenize(source) return tokenize(source) end
function M.parse(source) return parse(tokenize(source)) end

return M
