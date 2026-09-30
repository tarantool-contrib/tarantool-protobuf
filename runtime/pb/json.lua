-- proto3 JSON encoding (canonical mapping).
--
-- Spec: https://protobuf.dev/programming-guides/proto3/#json
--
-- Highlights of how we map types both ways:
--   * 32-bit ints / float / double / bool -> JSON number/bool
--   * 64-bit ints (int64/uint64/sint64/fixed64/sfixed64) -> JSON string
--     (JSON doubles lose precision past 2^53; the spec mandates strings)
--   * bytes -> base64 string
--   * enum -> string name when known, else number
--   * message -> JSON object (camelCase keys)
--   * map<K,V> -> JSON object (keys stringified per spec)
--   * Timestamp -> RFC 3339 "YYYY-MM-DDTHH:MM:SS[.fff]Z"
--   * Duration -> "<seconds>[.<frac>]s" (decimal seconds with 0/3/6/9 frac digits)
--   * Empty -> {}
--   * Wrapper messages -> unwrapped scalar
--   * Any -> {"@type": "<url>", ...} for user types; nested under "value" for WKTs.
--
-- Field names: emitted lowerCamelCase per spec; decoder accepts both
-- lowerCamelCase and the original snake_case.
--
-- JSON output uses a hand-rolled encoder so the double formatter can pick
-- the shortest round-tripping representation (Tarantool's json.encode is
-- locked to a global precision that wouldn't satisfy the conformance
-- suite). JSON input still goes through Tarantool's json.decode.
local ffi      = require('ffi')
local json     = require('json')
local digest   = require('digest')
local datetime = require('datetime')
local wire     = require('pb.wire')
local pbwkt    = require('pb.wkt')

local M = {}

local INT64_FAMILY = {int64=true, uint64=true, sint64=true,
                      fixed64=true, sfixed64=true}

local INT64_T  = ffi.typeof('int64_t')
local UINT64_T = ffi.typeof('uint64_t')

local PB_NULL = pbwkt.NULL

-- ---------------------------------------------------------------------------
-- WKT classification (used by Any encoding and elsewhere).
-- WKTs that have a non-object JSON representation must be nested under a
-- "value" key when wrapped in google.protobuf.Any.
-- ---------------------------------------------------------------------------
local WKT_NAMES = {
    ['google.protobuf.Timestamp']  = true,
    ['google.protobuf.Duration']   = true,
    ['google.protobuf.FieldMask']  = true,
    ['google.protobuf.Any']        = true,
    ['google.protobuf.Struct']     = true,
    ['google.protobuf.ListValue']  = true,
    ['google.protobuf.Value']      = true,
    ['google.protobuf.Empty']      = true,
}
local function is_wkt_name(name)
    return WKT_NAMES[name] or (name:match('^google%.protobuf%.%w+Value$') ~= nil)
end

-- ---------------------------------------------------------------------------
-- Field name conversion (snake_case ↔ lowerCamelCase per spec).
-- Multi-underscore runs collapse to a single capitalized letter; trailing
-- underscores drop. A leading underscore capitalizes the next letter so the
-- JSON name has no leading underscore.
-- ---------------------------------------------------------------------------
local function to_camel(name)
    name = name:gsub('_+$', '')
    return (name:gsub('_+(%w)', function(c) return c:upper() end))
end

-- ---------------------------------------------------------------------------
-- Number/integer parsing
-- ---------------------------------------------------------------------------

-- Strict integer-literal validation. Returns true if s matches
-- /^-?[0-9]+$/. JSON spec disallows leading + and whitespace.
local function is_int_string(s)
    return type(s) == 'string' and s:match('^%-?%d+$') ~= nil
end

-- Strict JSON-number-literal validation. Accepts:
--   -?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?
--   -?\.[0-9]+([eE][+-]?[0-9]+)?
-- Plus the three sentinel strings ("NaN", "Infinity", "-Infinity").
local function is_number_string(s)
    if type(s) ~= 'string' or s == '' then return false end
    if s == 'NaN' or s == 'Infinity' or s == '-Infinity' then return true end
    local i, n = 1, #s
    if s:sub(1, 1) == '-' then i = 2 end
    if i > n then return false end
    local saw_int = false
    while i <= n and s:sub(i, i):match('%d') do saw_int = true; i = i + 1 end
    local saw_frac = false
    if i <= n and s:sub(i, i) == '.' then
        i = i + 1
        while i <= n and s:sub(i, i):match('%d') do saw_frac = true; i = i + 1 end
    end
    if not (saw_int or saw_frac) then return false end
    if i <= n then
        local c = s:sub(i, i)
        if c ~= 'e' and c ~= 'E' then return false end
        i = i + 1
        if i <= n and (s:sub(i, i) == '+' or s:sub(i, i) == '-') then i = i + 1 end
        local saw_exp = false
        while i <= n and s:sub(i, i):match('%d') do saw_exp = true; i = i + 1 end
        if not saw_exp then return false end
    end
    return i > n
end

-- Compare two strings of digits as unsigned integers (longer = larger;
-- equal length = lexicographic).
local function digits_cmp(a, b)
    -- Strip leading zeros for an apples-to-apples comparison.
    a = a:gsub('^0+', ''); if a == '' then a = '0' end
    b = b:gsub('^0+', ''); if b == '' then b = '0' end
    if #a ~= #b then return #a < #b and -1 or 1 end
    if a == b then return 0 end
    return a < b and -1 or 1
end

-- Range checks for integer strings (no need to materialize 64-bit values).
local function int64_string_in_range(s)
    local neg = s:sub(1, 1) == '-'
    local digits = neg and s:sub(2) or s
    local max = neg and '9223372036854775808' or '9223372036854775807'
    return digits_cmp(digits, max) <= 0
end
local function uint64_string_in_range(s)
    if s:sub(1, 1) == '-' then
        -- "-0" is acceptable (it's still zero); any other negative is not.
        return s:match('^%-0+$') ~= nil
    end
    return digits_cmp(s, '18446744073709551615') <= 0
end

local function int_string_from_number(v)
    -- Re-render a Lua number that is integer-valued. Used to fold a JSON
    -- number literal into the string-based int validators.
    if v ~= v or v == math.huge or v == -math.huge then return nil end
    if v % 1 ~= 0 then return nil end
    -- string.format('%.0f', ...) rounds; we want truncate-to-integer, but
    -- since we already checked v % 1 == 0 the rounding is harmless.
    if v >= 0 and v < 2^53 then return string.format('%.0f', v) end
    if v < 0 and v > -2^53 then return string.format('%.0f', v) end
    -- For magnitudes past 2^53, the Lua number can't represent v exactly.
    -- The JSON number was parsed lossily; reject it rather than guess.
    return nil
end

-- Resolve a JSON-string integer field. Accepts strict-int literal
-- ("-?[0-9]+") OR a full JSON number string with integer value. The
-- second form covers conformance "Int32FieldQuotedExponentialValue"
-- ("1e5" → 100000).
local function int_string_from_string(s, typename)
    if is_int_string(s) then return s end
    if not is_number_string(s) then
        error(typename .. ': invalid string "' .. s .. '"', 0)
    end
    local n = tonumber(s)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then
        error(typename .. ': out of range "' .. s .. '"', 0)
    end
    if n % 1 ~= 0 then
        error(typename .. ': non-integer value "' .. s .. '"', 0)
    end
    local canonical = int_string_from_number(n)
    if canonical == nil then
        error(typename .. ': out of representable range "' .. s .. '"', 0)
    end
    return canonical
end

-- Decode a JSON value into a Lua number that fits in [INT32_MIN, INT32_MAX].
local function decode_int32(v)
    local s
    if type(v) == 'cdata' then
        s = tostring(v):gsub('U?LL$', '')
    elseif type(v) == 'number' then
        s = int_string_from_number(v)
        if s == nil then error('int32: not an integer-valued JSON number', 0) end
    elseif type(v) == 'string' then
        s = int_string_from_string(v, 'int32')
    else
        error('int32: expected JSON number/string, got ' .. type(v), 0)
    end
    if not int64_string_in_range(s) then error('int32 out of range: ' .. s, 0) end
    local n = tonumber(s)
    if n < -2147483648 or n > 2147483647 then
        error('int32 out of range: ' .. s, 0)
    end
    return n
end

local function decode_uint32(v)
    local s
    if type(v) == 'cdata' then
        s = tostring(v):gsub('U?LL$', '')
    elseif type(v) == 'number' then
        s = int_string_from_number(v)
        if s == nil then error('uint32: not an integer-valued JSON number', 0) end
    elseif type(v) == 'string' then
        s = int_string_from_string(v, 'uint32')
    else
        error('uint32: expected JSON number/string, got ' .. type(v), 0)
    end
    if s:sub(1, 1) == '-' and s:match('^%-0+$') == nil then
        error('uint32 cannot be negative: ' .. s, 0)
    end
    if not uint64_string_in_range(s) then error('uint32 out of range: ' .. s, 0) end
    local n = tonumber(s)
    if n < 0 or n > 4294967295 then
        error('uint32 out of range: ' .. s, 0)
    end
    return n
end

local function decode_int64_value(v, is_unsigned)
    local s
    if type(v) == 'cdata' then
        s = tostring(v):gsub('U?LL$', '')
    elseif type(v) == 'number' then
        s = int_string_from_number(v)
        if s == nil then error('int64: not an integer-valued JSON number', 0) end
    elseif type(v) == 'string' then
        s = int_string_from_string(v, is_unsigned and 'uint64' or 'int64')
    else
        error('int64: expected JSON number/string, got ' .. type(v), 0)
    end
    if is_unsigned then
        if s:sub(1, 1) == '-' and s:match('^%-0+$') == nil then
            error('uint64 cannot be negative: ' .. s, 0)
        end
        if not uint64_string_in_range(s) then error('uint64 out of range: ' .. s, 0) end
        local c = tonumber64(s)
        if c == nil then error('uint64 parse failed: ' .. s, 0) end
        return ffi.cast(UINT64_T, c)
    end
    if not int64_string_in_range(s) then error('int64 out of range: ' .. s, 0) end
    local c = tonumber64(s)
    if c == nil then error('int64 parse failed: ' .. s, 0) end
    return ffi.cast(INT64_T, c)
end

-- Float/double decode. NaN/Infinity sentinels and JSON numbers / numeric
-- strings both accepted; out-of-range strings produce a parse error.
local FLOAT_MAX  = 3.4028234663852886e+38
local FLOAT_MIN  = -3.4028234663852886e+38

local function decode_float_value(v, is_float)
    local n
    local typename = is_float and 'float' or 'double'
    if type(v) == 'number' then
        -- JSON numeric literals that overflow double parse to inf — that's
        -- a Too-Large/Too-Small input and must be rejected.
        if v == math.huge or v == -math.huge then
            error(typename .. ': value out of range (Infinity from JSON number)', 0)
        end
        n = v
    elseif type(v) == 'cdata' then
        n = tonumber(v)
    elseif type(v) == 'string' then
        if v == 'NaN' then return 0/0 end
        if v == 'Infinity' then return math.huge end
        if v == '-Infinity' then return -math.huge end
        if not is_number_string(v) then
            error(typename .. ': invalid string "' .. v .. '"', 0)
        end
        n = tonumber(v)
        if n == nil then
            error(typename .. ': unparseable "' .. v .. '"', 0)
        end
        if n == math.huge or n == -math.huge then
            error(typename .. ': out of range "' .. v .. '"', 0)
        end
    else
        error(typename .. ': expected JSON number/string, got ' .. type(v), 0)
    end
    if is_float and n == n and n ~= math.huge and n ~= -math.huge then
        if n > FLOAT_MAX or n < FLOAT_MIN then
            error('float out of range: ' .. tostring(n), 0)
        end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- Timestamp / Duration helpers
-- ---------------------------------------------------------------------------

local TS_MIN_SECONDS = -62135596800   -- 0001-01-01T00:00:00Z
local TS_MAX_SECONDS = 253402300799   -- 9999-12-31T23:59:59Z
local DUR_MAX_SECONDS = 315576000000  -- 10000 years, per spec

-- Format a fractional-seconds string with 0/3/6/9 digits per spec.
local function fractional_seconds(nanos)
    if nanos == 0 then return '' end
    local frac = string.format('%09d', nanos)
    if nanos % 1000000 == 0 then frac = frac:sub(1, 3)
    elseif nanos % 1000 == 0 then frac = frac:sub(1, 6)
    end
    return '.' .. frac
end

-- Convert UTC epoch seconds to (year, month, day, hour, minute, second).
-- Uses Howard Hinnant's date algorithm, which works for any integer epoch
-- without depending on the platform's gmtime — POSIX %Y formats year 1 as
-- "1" on glibc, which would fall over the conformance round-trip.
local function epoch_to_ymdhms(secs)
    secs = math.floor(secs)
    local days = math.floor(secs / 86400)
    local tod  = secs - days * 86400
    if tod < 0 then tod = tod + 86400; days = days - 1 end
    days = days + 719468
    local era = math.floor(days / 146097)
    local doe = days - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460)
                          + math.floor(doe / 36524)
                          - math.floor(doe / 146096)) / 365)
    local y   = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4)
                                  - math.floor(yoe / 100))
    local mp  = math.floor((5 * doy + 2) / 153)
    local d   = doy - math.floor((153 * mp + 2) / 5) + 1
    local m   = mp < 10 and mp + 3 or mp - 9
    if m <= 2 then y = y + 1 end
    local h  = math.floor(tod / 3600)
    local mi = math.floor((tod - h * 3600) / 60)
    local s  = tod - h * 3600 - mi * 60
    return y, m, d, h, mi, s
end

-- Parse an RFC 3339 timestamp. Strict: uppercase 'T' separator, either 'Z'
-- or '±HH:MM' offset, fraction (if present) up to 9 digits.
local function parse_timestamp(s)
    if type(s) ~= 'string' then error('Timestamp: expected string', 0) end
    local base = '%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d'
    local body, frac, tz
    body, frac = s:match('^(' .. base .. ')%.(%d+)Z$')
    if body then tz = 'Z' end
    if not body then
        body, frac, tz = s:match('^(' .. base .. ')%.(%d+)([+%-]%d%d:%d%d)$')
    end
    if not body then
        body = s:match('^(' .. base .. ')Z$')
        if body then tz = 'Z'; frac = '' end
    end
    if not body then
        body, tz = s:match('^(' .. base .. ')([+%-]%d%d:%d%d)$')
        frac = frac or ''
    end
    if not body then error('Timestamp: invalid format "' .. s .. '"', 0) end
    if #frac > 9 then
        error('Timestamp: fraction has more than 9 digits', 0)
    end
    local y, mo, d, h, mi, sec = body:match(
        '^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)$')
    y  = tonumber(y);  mo = tonumber(mo); d  = tonumber(d)
    h  = tonumber(h);  mi = tonumber(mi); sec = tonumber(sec)
    if mo < 1 or mo > 12 or d < 1 or d > 31 then
        error('Timestamp: invalid date "' .. s .. '"', 0)
    end
    if h > 23 or mi > 59 or sec > 59 then
        error('Timestamp: invalid time "' .. s .. '"', 0)
    end
    local nanos = 0
    if frac ~= '' then nanos = tonumber((frac .. '000000000'):sub(1, 9)) end
    local tz_minutes = 0
    if tz ~= 'Z' then
        local sign, oh, om = tz:match('^([+%-])(%d%d):(%d%d)$')
        tz_minutes = (sign == '+' and 1 or -1) *
                     (tonumber(oh) * 60 + tonumber(om))
        if tonumber(oh) > 23 or tonumber(om) > 59 then
            error('Timestamp: invalid tz offset "' .. tz .. '"', 0)
        end
    end
    local ok, dt = pcall(datetime.new, {
        year = y, month = mo, day = d,
        hour = h, min = mi, sec = sec,
        nsec = nanos, tzoffset = tz_minutes,
    })
    if not ok then error('Timestamp: ' .. tostring(dt), 0) end
    local epoch_n = tonumber(dt.epoch)
    if epoch_n < TS_MIN_SECONDS or epoch_n > TS_MAX_SECONDS then
        error('Timestamp: out of range "' .. s .. '"', 0)
    end
    return dt
end

-- Format a datetime cdata (or {seconds=,nanos=} table) as UTC RFC 3339.
local function format_timestamp(v)
    local seconds_n, nanos
    if type(v) == 'cdata' and datetime.is_datetime(v) then
        seconds_n = tonumber(v.epoch)
        nanos = v.nsec
    elseif type(v) == 'table' then
        local s = v.seconds or 0
        seconds_n = (type(s) == 'cdata') and tonumber(s) or s
        nanos = v.nanos or 0
    elseif type(v) == 'number' then
        seconds_n = math.floor(v)
        nanos = math.floor((v - seconds_n) * 1e9 + 0.5)
    else
        error('Timestamp: expected datetime/table/number, got ' .. type(v), 0)
    end
    if nanos < 0 or nanos >= 1000000000 then
        error('Timestamp: nanos out of range (' .. tostring(nanos) .. ')', 0)
    end
    if seconds_n < TS_MIN_SECONDS or seconds_n > TS_MAX_SECONDS then
        error('Timestamp: seconds out of range (' .. tostring(seconds_n) .. ')', 0)
    end
    local y, mo, d, h, mi, s = epoch_to_ymdhms(seconds_n)
    return string.format('%04d-%02d-%02dT%02d:%02d:%02d', y, mo, d, h, mi, s)
        .. fractional_seconds(nanos) .. 'Z'
end

local function parse_duration(s)
    if type(s) ~= 'string' then error('Duration: expected string', 0) end
    if s:sub(-1) ~= 's' then
        error('Duration: missing "s" suffix in "' .. s .. '"', 0)
    end
    local body = s:sub(1, -2)
    local neg = body:sub(1, 1) == '-'
    if neg then body = body:sub(2) end
    local sec_str, frac = body:match('^(%d+)%.(%d+)$')
    if sec_str == nil then
        sec_str = body:match('^(%d+)$')
        frac = ''
    end
    if sec_str == nil then
        error('Duration: invalid format "' .. s .. '"', 0)
    end
    if #frac > 9 then
        error('Duration: fraction has more than 9 digits', 0)
    end
    local seconds = tonumber(sec_str)
    local nanos = 0
    if frac ~= '' then nanos = tonumber((frac .. '000000000'):sub(1, 9)) end
    if seconds > DUR_MAX_SECONDS then
        error('Duration: out of range "' .. s .. '"', 0)
    end
    if neg then seconds = -seconds; nanos = -nanos end
    return {seconds = ffi.cast(INT64_T, seconds), nanos = nanos}
end

local function format_duration(v)
    local seconds, nanos
    if type(v) == 'table' then
        seconds = v.seconds or 0
        nanos = v.nanos or 0
    elseif type(v) == 'number' then
        seconds = math.floor(v)
        nanos = math.floor((v - seconds) * 1e9 + 0.5)
    else
        error('Duration: expected table/number, got ' .. type(v), 0)
    end
    local seconds_n = (type(seconds) == 'cdata') and tonumber(seconds) or seconds
    if nanos <= -1000000000 or nanos >= 1000000000 then
        error('Duration: nanos out of range (' .. tostring(nanos) .. ')', 0)
    end
    if (seconds_n > 0 and nanos < 0) or (seconds_n < 0 and nanos > 0) then
        error('Duration: seconds and nanos must have the same sign', 0)
    end
    if seconds_n < -DUR_MAX_SECONDS or seconds_n > DUR_MAX_SECONDS then
        error('Duration: seconds out of range (' .. tostring(seconds_n) .. ')', 0)
    end
    local negative = seconds_n < 0 or nanos < 0
    local abs_s = math.abs(seconds_n)
    local abs_n = math.abs(nanos)
    local out = string.format('%d', abs_s)
    if abs_n ~= 0 then out = out .. fractional_seconds(abs_n) end
    return (negative and '-' or '') .. out .. 's'
end

-- ---------------------------------------------------------------------------
-- Hand-rolled JSON encoder (gives us shortest round-trip doubles)
-- ---------------------------------------------------------------------------

local ESCAPES = {}
for i = 0, 0x1f do ESCAPES[string.char(i)] = string.format('\\u%04x', i) end
ESCAPES['\b'] = '\\b';  ESCAPES['\f'] = '\\f'
ESCAPES['\n'] = '\\n';  ESCAPES['\r'] = '\\r'; ESCAPES['\t'] = '\\t'
ESCAPES['"']  = '\\"';  ESCAPES['\\'] = '\\\\'

local function encode_json_string(s)
    return '"' .. (s:gsub('[%z\1-\31"\\]', ESCAPES)) .. '"'
end

local function encode_json_number(n)
    if n ~= n then return '"NaN"' end
    if n == math.huge then return '"Infinity"' end
    if n == -math.huge then return '"-Infinity"' end
    -- Integer-valued doubles within Lua's safe integer range: emit as int.
    if n == math.floor(n) and math.abs(n) < 1e16 then
        if n == 0 then return '0' end
        return string.format('%d', n)
    end
    -- Shortest round-trip: try increasing precision until tonumber round-trips.
    for p = 15, 17 do
        local s = string.format('%.' .. p .. 'g', n)
        if tonumber(s) == n then return s end
    end
    return string.format('%.17g', n)
end

local encode_json  -- forward

local function is_array_table(t, mt)
    if mt and mt.__serialize == 'seq' then return true end
    if mt and mt.__serialize == 'map' then return false end
    if mt and mt.__pb_kind == 'list'   then return true end
    if mt and mt.__pb_kind == 'struct' then return false end
    if next(t) == nil then return false end  -- empty defaults to object
    return t[1] ~= nil
end

local function encode_json_array(t)
    local parts = {}
    for i = 1, #t do parts[i] = encode_json(t[i]) end
    return '[' .. table.concat(parts, ',') .. ']'
end

local function encode_json_object(t)
    local parts, n = {}, 0
    for k, v in pairs(t) do
        n = n + 1
        parts[n] = encode_json_string(tostring(k)) .. ':' .. encode_json(v)
    end
    return '{' .. table.concat(parts, ',') .. '}'
end

encode_json = function(v)
    if v == nil then return 'null' end
    local ty = type(v)
    if ty == 'cdata' then
        if v == box.NULL then return 'null' end
        -- 64-bit ints from non-JSON sources are stringified by the proto
        -- scalar encoder before we get here; any cdata that slips through
        -- is rendered as an unquoted decimal (best-effort fallback).
        return (tostring(v):gsub('U?LL$', ''))
    end
    if ty == 'boolean' then return v and 'true' or 'false' end
    if ty == 'number' then return encode_json_number(v) end
    if ty == 'string' then return encode_json_string(v) end
    if ty == 'table' then
        local mt = getmetatable(v)
        if is_array_table(v, mt) then return encode_json_array(v) end
        return encode_json_object(v)
    end
    error('JSON encode: unsupported type ' .. ty, 0)
end

-- Pretty-printer used when `M.encode(desc, t, {indent = "  "})` is set.
-- Indent is repeated per nesting level; key/value separator becomes `: `;
-- empty arrays/objects stay on one line as `[]` / `{}`.
local encode_json_pretty
encode_json_pretty = function(v, indent, depth)
    if v == nil then return 'null' end
    local ty = type(v)
    if ty == 'cdata' then
        if v == box.NULL then return 'null' end
        return (tostring(v):gsub('U?LL$', ''))
    end
    if ty == 'boolean' then return v and 'true' or 'false' end
    if ty == 'number' then return encode_json_number(v) end
    if ty == 'string' then return encode_json_string(v) end
    if ty == 'table' then
        local mt = getmetatable(v)
        local outer = string.rep(indent, depth)
        local inner = string.rep(indent, depth + 1)
        if is_array_table(v, mt) then
            if #v == 0 then return '[]' end
            local parts = {}
            for i = 1, #v do parts[i] = encode_json_pretty(v[i], indent, depth + 1) end
            return '[\n' .. inner .. table.concat(parts, ',\n' .. inner)
                   .. '\n' .. outer .. ']'
        end
        local parts, n = {}, 0
        for k, vv in pairs(v) do
            n = n + 1
            parts[n] = encode_json_string(tostring(k)) .. ': '
                       .. encode_json_pretty(vv, indent, depth + 1)
        end
        if n == 0 then return '{}' end
        return '{\n' .. inner .. table.concat(parts, ',\n' .. inner)
               .. '\n' .. outer .. '}'
    end
    error('JSON encode: unsupported type ' .. ty, 0)
end

-- ---------------------------------------------------------------------------
-- Encode (proto-Lua table -> Lua structure suitable for our JSON emitter)
-- ---------------------------------------------------------------------------

local to_json_value
local encode_message

-- Marker so the JSON encoder emits a quoted JSON value verbatim. The
-- proto3 spec mandates 64-bit ints as JSON strings; this keeps the
-- formatter simple while letting the scalar encoder produce ready-made
-- string output.
local function encode_scalar(proto_type, v)
    if INT64_FAMILY[proto_type] then
        -- Always emit as JSON string per spec.
        if type(v) == 'cdata' then
            return (tostring(v):gsub('U?LL$', ''))
        end
        if type(v) == 'number' then return string.format('%.0f', v) end
        return tostring(v)
    end
    if proto_type == 'uint32' then return v end
    if proto_type == 'bytes' then return digest.base64_encode(v, {nowrap = true}) end
    if proto_type == 'float' or proto_type == 'double' then
        return v  -- handled by encode_json_number
    end
    return v  -- string, bool, int32, sint32, fixed32, sfixed32
end

local function encode_enum(enum_desc, v)
    -- google.protobuf.NullValue's JSON form is the literal `null`, not the
    -- enum name "NULL_VALUE". Mainline's TextFormat/JSON parsers accept
    -- either on input, but the canonical output is null — and the
    -- NullValueInOtherOneof*Format.Validator conformance tests pin it.
    if enum_desc.name == 'google.protobuf.NullValue' then
        return box.NULL
    end
    if type(v) == 'string' then return v end
    local name = enum_desc.by_value[v]
    return name or v  -- unknown numeric value: emit as number
end

local function encode_field_value(field, v)
    local kind = field.kind
    if kind == 'scalar' then return encode_scalar(field.proto_type, v) end
    if kind == 'enum'   then return encode_enum(field.enum, v)        end
    if kind == 'message' then return encode_message(field.message, v) end
    error('encode_field_value: unknown kind ' .. tostring(kind), 0)
end

local function encode_map_key(key_field, k)
    local pt = key_field.proto_type
    if pt == 'bool' then return k and 'true' or 'false' end
    if INT64_FAMILY[pt] then
        if type(k) == 'cdata' then return (tostring(k):gsub('U?LL$', '')) end
        return tostring(k)
    end
    if pt == 'string' then return k end
    return tostring(k)
end

local value_to_json, value_to_json_struct, value_to_json_list

value_to_json = function(v)
    if v == nil or v == PB_NULL then return box.NULL end
    local ty = type(v)
    if ty == 'number' then
        -- google.protobuf.Value's number_value is a double, but JSON has no
        -- NaN/Infinity literals so the spec forbids them here. JSON output
        -- must fail rather than emit a "NaN"/"Infinity" string (which would
        -- be silently treated as the string_value branch by readers).
        if v ~= v then error('Value JSON: NaN is not a valid number_value', 0) end
        if v == math.huge or v == -math.huge then
            error('Value JSON: Infinity is not a valid number_value', 0)
        end
        return v
    end
    if ty == 'boolean' or ty == 'string' then return v end
    if ty == 'cdata' then
        if v == box.NULL then return box.NULL end
        return tonumber(v)
    end
    if ty == 'table' then
        local mt = getmetatable(v)
        if mt and mt.__pb_kind == 'list'   then return value_to_json_list(v)   end
        if mt and mt.__pb_kind == 'struct' then return value_to_json_struct(v) end
        if v[1] ~= nil then return value_to_json_list(v) end
        return value_to_json_struct(v)
    end
    error('Value JSON: unsupported Lua type ' .. ty, 0)
end

value_to_json_struct = function(t)
    if t == nil then return setmetatable({}, {__serialize='map'}) end
    local out, empty = {}, true
    for k, v in pairs(t) do
        out[tostring(k)] = value_to_json(v)
        empty = false
    end
    if empty then return setmetatable(out, {__serialize='map'}) end
    return out
end

value_to_json_list = function(t)
    if t == nil then return setmetatable({}, {__serialize='seq'}) end
    local out = {}
    for i = 1, #t do out[i] = value_to_json(t[i]) end
    return setmetatable(out, {__serialize='seq'})
end

-- google.protobuf.FieldMask paths use snake_case on the wire and a
-- lowerCamelCase JSON form. To survive the round-trip, snake_case paths
-- must be restricted so the inverse transform is unambiguous:
--   * no uppercase letters (it's not snake_case otherwise)
--   * no consecutive underscores (would lose info: "foo__bar" → "fooBar"
--     → "foo_bar"); pinned by FieldMaskTooManyUnderscore
--   * no trailing underscore
--   * underscore must precede a lowercase letter — never a digit
--     ("foo_3_bar" → "foo3Bar" → "foo3_bar"); pinned by
--     FieldMaskNumbersDontRoundTrip
--   * the path itself must already be snake-cased (no uppercase letters
--     in the input we're asked to serialize); pinned by
--     FieldMaskPathsDontRoundTrip
local function fieldmask_to_json(v)
    if v == nil or #v == 0 then return '' end
    local parts = {}
    for i = 1, #v do
        local p = v[i]
        if type(p) ~= 'string' then
            error('FieldMask: path is not a string', 0)
        end
        if p == '' then
            error('FieldMask: empty path', 0)
        end
        if p:find('[A-Z]') then
            error('FieldMask: path "' .. p ..
                  '" has uppercase letter (must be snake_case)', 0)
        end
        if p:find('__') then
            error('FieldMask: path "' .. p ..
                  '" has consecutive underscores', 0)
        end
        if p:sub(-1) == '_' then
            error('FieldMask: path "' .. p .. '" has trailing underscore', 0)
        end
        if p:find('_[^a-z]') then
            error('FieldMask: path "' .. p ..
                  '" has underscore followed by non-letter (does not round-trip)', 0)
        end
        parts[i] = to_camel(p)
    end
    return table.concat(parts, ',')
end

-- JSON FieldMask paths are lowerCamelCase; the wire is snake_case. The
-- input must therefore be free of `_` (an underscore in the JSON form
-- breaks the snake↔camel inverse: see FieldMaskInvalidCharacter).
local function fieldmask_from_json(s)
    if type(s) ~= 'string' or s == '' then return {} end
    local out = {}
    for part in (s .. ','):gmatch('([^,]+),') do
        if part:find('_') then
            error('FieldMask JSON: path "' .. part ..
                  '" contains underscore (JSON form must be lowerCamelCase)', 0)
        end
        out[#out + 1] = (part:gsub('(%u)', function(c) return '_' .. c:lower() end))
    end
    return out
end

-- Encode Any to a Lua structure ready for the JSON emitter. Returns a
-- table with the `@type`+`value` shape per spec.
local function any_to_json(v)
    if v == nil then return setmetatable({}, {__serialize='map'}) end
    if type(v) ~= 'table' then
        error('Any JSON: expected table, got ' .. type(v), 0)
    end
    local type_url = v.type_url or ''
    local bytes    = v.value or ''
    if type_url == '' and bytes == '' then
        return setmetatable({}, {__serialize='map'})
    end
    local desc = pbwkt.lookup(type_url)
    if desc == nil then
        -- Unknown type: opaque pass-through with base64-encoded value (this
        -- keeps round-trips through user-registered types stable without
        -- forcing every embedded payload into a Wkt shape).
        local obj = {}
        if type_url ~= '' then obj['@type'] = type_url end
        if bytes ~= '' then obj.value = digest.base64_encode(bytes, {nowrap = true}) end
        return obj
    end
    local inner = desc.decode and desc.decode(bytes)
                or require('pb.codec').decode(desc, bytes)
    local payload = encode_message(desc, inner)
    if is_wkt_name(desc.name) then
        -- Empty's JSON form is {} and the reference implementation rejects
        -- the explicit {"value": {}} shape inside Any, so emit only @type.
        if desc.name == 'google.protobuf.Empty' then
            return {['@type'] = type_url}
        end
        return {['@type'] = type_url, value = payload}
    end
    -- User-type Any: flatten the message fields next to "@type".
    if type(payload) ~= 'table' then
        return {['@type'] = type_url, value = payload}
    end
    payload['@type'] = type_url
    return payload
end

-- WKT special-case encoders. Return the value to emit in place of the
-- generic message walk, or nil to fall back.
local function encode_wkt(desc, v)
    local name = desc.name
    if name == 'google.protobuf.Empty' then
        return setmetatable({}, {__serialize='map'})
    end
    if name == 'google.protobuf.Timestamp' then return format_timestamp(v) end
    if name == 'google.protobuf.Duration'  then return format_duration(v)  end
    if name == 'google.protobuf.FieldMask' then return fieldmask_to_json(v) end
    if name == 'google.protobuf.Any' then return any_to_json(v) end
    if name == 'google.protobuf.Struct'    then return value_to_json_struct(v) end
    if name == 'google.protobuf.ListValue' then return value_to_json_list(v) end
    if name == 'google.protobuf.Value'     then return value_to_json(v) end
    local wrap = name:match('^google%.protobuf%.(%w+)Value$')
    if wrap then
        local wrapper_proto = {
            Int32='int32', UInt32='uint32', Int64='int64', UInt64='uint64',
            Float='float', Double='double', Bool='bool',
            String='string', Bytes='bytes',
        }
        local pt = wrapper_proto[wrap]
        if pt then return encode_scalar(pt, v) end
    end
    return nil
end

-- Set by M.encode for the duration of a call. See CURRENT_OPTS for the
-- decode-side analogue. Read by encode_message to honor:
--   * use_proto_names      — emit snake_case field names (proto wire names)
--                            instead of the spec-default lowerCamelCase
--   * emit_defaults        — emit zero-valued scalars/enums, empty
--   (alias: always_emit_zero_value)  repeated/map fields, even when
--                            implicit-presence semantics would skip them.
--                            Explicit-presence fields (`optional`/`oneof`)
--                            and singular message fields remain absent
--                            when unset.
local CURRENT_ENCODE_OPTS = nil

-- Zero value to emit for an implicit-presence scalar/enum field when
-- emit_defaults is on and the field is absent from the input table.
-- Returns nil for kinds that should never be synthesized (message,
-- repeated, map — handled separately).
local FFI_INT64_ZERO  = ffi.cast(INT64_T, 0)
local FFI_UINT64_ZERO = ffi.cast(UINT64_T, 0)
local function zero_value_for_field(f)
    if f.kind == 'scalar' then
        local pt = f.proto_type
        if pt == 'string' or pt == 'bytes' then return '' end
        if pt == 'bool' then return false end
        if pt == 'int64' or pt == 'sint64' or pt == 'sfixed64' then
            return FFI_INT64_ZERO
        end
        if pt == 'uint64' or pt == 'fixed64' then
            return FFI_UINT64_ZERO
        end
        return 0
    end
    if f.kind == 'enum' then return 0 end
    return nil
end

encode_message = function(desc, t)
    if rawequal(t, nil) then return nil end
    local override = encode_wkt(desc, t)
    -- box.NULL ~= nil is false under __eq; use rawequal so a Value WKT can
    -- legitimately return null as its override.
    if not rawequal(override, nil) then return override end

    local opts = CURRENT_ENCODE_OPTS
    local emit_defaults = opts and opts.emit_defaults
    local use_proto_names = opts and opts.use_proto_names
    -- Unset singular message fields as JSON null (protojson's
    -- EmitUnpopulated, grpc-gateway's default). Oneof members and
    -- proto3 `optional` fields stay absent, as there.
    local emit_null_messages = opts and opts.emit_null_messages

    local out = setmetatable({}, {__serialize='map'})
    for _, f in ipairs(desc.fields) do
        local v = t[f.name]
        local key = use_proto_names and f.name or to_camel(f.name)
        -- box.NULL == nil under Tarantool's __eq metamethod; use rawequal
        -- so a deliberately-stored null sentinel survives the field walk.
        if not rawequal(v, nil) then
            if f.kind == 'map' then
                if next(v) ~= nil then
                    local obj = setmetatable({}, {__serialize='map'})
                    for k, mv in pairs(v) do
                        obj[encode_map_key(f.key, k)] = encode_field_value(f.value, mv)
                    end
                    out[key] = obj
                elseif emit_defaults then
                    out[key] = setmetatable({}, {__serialize='map'})
                end
            elseif f.repeated then
                if #v > 0 then
                    local arr = setmetatable({}, {__serialize='seq'})
                    for i = 1, #v do arr[i] = encode_field_value(f, v[i]) end
                    out[key] = arr
                elseif emit_defaults then
                    out[key] = setmetatable({}, {__serialize='seq'})
                end
            else
                local emit = true
                -- Default-elision only applies to proto3 implicit-presence
                -- shapes. Anything with explicit presence (`optional`,
                -- oneof, proto2 `required`) emits its value verbatim — even
                -- when it equals the type's zero/default — because the
                -- absence of the field is observably distinct from being
                -- set-to-default.
                if not emit_defaults and not (f.optional or f.oneof or f.required) then
                    if f.kind == 'scalar' then
                        local pt = f.proto_type
                        if pt == 'string' or pt == 'bytes' then
                            if v == '' then emit = false end
                        elseif pt == 'bool' then
                            if v == false then emit = false end
                        else
                            if v == 0 or (type(v) == 'cdata' and v == FFI_INT64_ZERO) then
                                emit = false
                            end
                        end
                    elseif f.kind == 'enum' then
                        if v == 0 or v == f.enum.by_value[0] then emit = false end
                    end
                end
                if emit then out[key] = encode_field_value(f, v) end
            end
        elseif emit_defaults then
            -- Field is absent from input. Emit a default only for
            -- implicit-presence shapes (proto3 non-optional, non-oneof,
            -- non-message). Maps and repeated come out as empty
            -- containers; scalars/enums as the zero value.
            if f.kind == 'map' then
                out[key] = setmetatable({}, {__serialize='map'})
            elseif f.repeated then
                out[key] = setmetatable({}, {__serialize='seq'})
            elseif not (f.optional or f.oneof) and f.kind ~= 'message' then
                local z = zero_value_for_field(f)
                if z ~= nil then out[key] = encode_field_value(f, z) end
            end
        end
        if emit_null_messages and rawequal(v, nil) and f.kind == 'message'
                and not f.repeated and not (f.optional or f.oneof) then
            out[key] = box.NULL
        end
    end
    -- Proto2 extensions: surface set entries under their bracketed
    -- fully-qualified name (`[pkg.ext_name]`). Walk the array
    -- (`extensions_list`) rather than the hash — pairs() compiles to
    -- ISNEXT which is NYI on the JIT. Repeated extensions emit as JSON
    -- arrays per the proto2 JSON spec.
    local exts = t._extensions
    local elist = exts ~= nil and desc.extensions_list or nil
    if elist ~= nil then
        for i = 1, #elist do
            local ext = elist[i]
            local v = exts[ext.full_name]
            if v ~= nil then
                local k = '[' .. ext.full_name .. ']'
                if ext.repeated then
                    local arr = setmetatable({}, {__serialize='seq'})
                    for j = 1, #v do arr[j] = encode_field_value(ext, v[j]) end
                    out[k] = arr
                else
                    out[k] = encode_field_value(ext, v)
                end
            end
        end
    end
    return out
end

to_json_value = encode_message

-- Top-level field of desc by proto name. Scans `fields` because only
-- pb.finalize_message builds field_by_name; runtime-built descriptors
-- (pb.parse, pb.from_pb) carry field_by_id alone.
local function top_field(desc, name)
    for _, f in ipairs(desc.fields or {}) do
        if f.name == name then return f end
    end
    return nil
end

-- Normalize encode opts once so the hot path reads a single boolean.
local function normalize_encode_opts(opts, fname)
    if opts == nil then return nil end
    if type(opts) ~= 'table' then
        error('pb.json.' .. fname .. ': opts must be a table, got ' .. type(opts), 0)
    end
    local norm = {
        use_proto_names = opts.use_proto_names and true or false,
        emit_defaults   = (opts.emit_defaults or opts.always_emit_zero_value)
                          and true or false,
        emit_null_messages = opts.emit_null_messages and true or false,
        indent          = opts.indent,
    }
    if norm.indent ~= nil and type(norm.indent) ~= 'string' then
        error('pb.json.' .. fname .. ': indent must be a string', 0)
    end
    if norm.indent == '' then norm.indent = nil end
    return norm
end

-- Run fn(...) with CURRENT_ENCODE_OPTS installed and render its result.
local function encode_with(norm, fn, ...)
    local prev = CURRENT_ENCODE_OPTS
    CURRENT_ENCODE_OPTS = norm
    local ok, root_or_err = pcall(fn, ...)
    CURRENT_ENCODE_OPTS = prev
    if not ok then error(root_or_err, 0) end
    if norm and norm.indent then
        return encode_json_pretty(root_or_err, norm.indent, 0)
    end
    return encode_json(root_or_err)
end

---@param desc pb.Descriptor
---@param t    table
---@param opts? pb.JsonEncodeOpts
---@return string
function M.encode(desc, t, opts)
    return encode_with(normalize_encode_opts(opts, 'encode'), encode_message, desc, t)
end

-- JSON value of one top-level field of `desc` taken from `t`, the way
-- it would appear under its key in M.encode's output. An unset field
-- renders as `null` for a singular message (well-known types
-- included), `{}` for a map, `[]` for a repeated field, the zero value
-- for a scalar or enum. Used by HTTP transcoding for `response_body`.
local function encode_one_field(desc, f, t)
    local v = t[f.name]
    local empty_map = setmetatable({}, {__serialize='map'})
    local empty_seq = setmetatable({}, {__serialize='seq'})
    if f.kind == 'map' then
        if rawequal(v, nil) then return empty_map end
        local obj = setmetatable({}, {__serialize='map'})
        for k, mv in pairs(v) do
            obj[encode_map_key(f.key, k)] = encode_field_value(f.value, mv)
        end
        return obj
    end
    if f.repeated then
        if rawequal(v, nil) then return empty_seq end
        local arr = setmetatable({}, {__serialize='seq'})
        for i = 1, #v do arr[i] = encode_field_value(f, v[i]) end
        return arr
    end
    if rawequal(v, nil) then
        -- An unset message is JSON null, as protojson prints it. Feeding
        -- the encoder a synthesised `{}` instead is wrong for the
        -- well-known types, whose Lua value is not a field table (an
        -- unset Int64Value would print "table: 0x...").
        if f.kind == 'message' then return box.NULL end
        v = zero_value_for_field(f)
    end
    return encode_field_value(f, v)
end

---@param desc pb.Descriptor
---@param t    table
---@param field_name string   proto name of a top-level field of desc
---@param opts? pb.JsonEncodeOpts
---@return string
function M.encode_field(desc, t, field_name, opts)
    local f = top_field(desc, field_name)
    if f == nil then
        error('pb.json.encode_field: ' .. tostring(desc.name) ..
              ' has no field "' .. tostring(field_name) .. '"', 0)
    end
    return encode_with(normalize_encode_opts(opts, 'encode_field'),
                       encode_one_field, desc, f, t)
end

-- JSON name of a proto field name (lowerCamelCase per the proto3 JSON
-- mapping).
M.json_name = function(name) return to_camel(name) end

-- ---------------------------------------------------------------------------
-- Decode (JSON -> proto-Lua table)
-- ---------------------------------------------------------------------------

local decode_message  -- forward

local function decode_scalar(proto_type, v)
    if proto_type == 'int32' or proto_type == 'sint32' or
       proto_type == 'fixed32' or proto_type == 'sfixed32' then
        return decode_int32(v)
    end
    if proto_type == 'uint32' then return decode_uint32(v) end
    if proto_type == 'int64' or proto_type == 'sint64' or
       proto_type == 'sfixed64' then
        return decode_int64_value(v, false)
    end
    if proto_type == 'uint64' or proto_type == 'fixed64' then
        return decode_int64_value(v, true)
    end
    if proto_type == 'float'  then return decode_float_value(v, true)  end
    if proto_type == 'double' then return decode_float_value(v, false) end
    if proto_type == 'bool' then
        if type(v) ~= 'boolean' then
            error('bool: expected JSON true/false, got ' .. type(v), 0)
        end
        return v
    end
    if proto_type == 'string' then
        if type(v) ~= 'string' then
            error('string: expected JSON string, got ' .. type(v), 0)
        end
        if not wire.is_valid_utf8(v) then
            error('string: invalid UTF-8', 0)
        end
        return v
    end
    if proto_type == 'bytes' then
        if type(v) ~= 'string' then
            error('bytes: expected base64 JSON string, got ' .. type(v), 0)
        end
        return digest.base64_decode(v)
    end
    error('decode_scalar: unsupported proto type ' .. tostring(proto_type), 0)
end

-- Set by M.decode for the duration of a parse. Reads are fiber-local in
-- effect because pb.json.decode never yields (pure Lua / FFI work). The
-- recursive decode chain reads this when it needs to know whether the
-- caller asked for "ignore unknown enum names / fields" behavior.
local CURRENT_OPTS = nil

local function decode_enum(enum_desc, v)
    if type(v) == 'string' then
        local n = enum_desc.by_name[v]
        if n ~= nil then return n end
        -- Numeric string (e.g. "999"): JSON spec allows it; treat as integer.
        if is_int_string(v) then
            local n2 = tonumber(v)
            if n2 >= -2147483648 and n2 <= 2147483647 then return n2 end
        end
        -- Unknown enum NAMES are rejected per proto3 JSON spec
        -- (RejectUnknownEnumStringValueIn{Optional,Repeated,Map}Field).
        -- Unknown enum *integers* fall through to the integer branch and
        -- are preserved — that's the proto3 forward-compat contract.
        -- Under `ignore_unknown_fields=true` (conformance category
        -- JSON_IGNORE_UNKNOWN_PARSING_TEST) we silently drop instead;
        -- the caller in repeated/map context filters nil through.
        if CURRENT_OPTS and CURRENT_OPTS.ignore_unknown_fields then
            return nil
        end
        error('unknown enum value "' .. v .. '" for ' .. enum_desc.name, 0)
    end
    if type(v) == 'number' then
        if v ~= v or v ~= math.floor(v) then
            error('enum: non-integer JSON number', 0)
        end
        if v < -2147483648 or v > 2147483647 then
            error('enum: integer out of int32 range', 0)
        end
        return v
    end
    if type(v) == 'cdata' then return tonumber(v) end
    error('enum: expected JSON string or integer, got ' .. type(v), 0)
end

local function decode_field_value(field, v)
    if v == box.NULL then
        -- proto3 JSON: null on a non-message field means "use the default"
        -- (treat as absent). Two exceptions:
        --   * google.protobuf.Value — null maps to NullValue.NULL_VALUE.
        --   * NullValue-typed enum field (used as a oneof presence marker)
        --     — null SETS the field to 0, marking the oneof active.
        if field.kind == 'message' and field.message
           and field.message.name == 'google.protobuf.Value' then
            return PB_NULL
        end
        if field.kind == 'enum' and field.enum
           and field.enum.name == 'google.protobuf.NullValue' then
            return 0
        end
        return nil
    end
    local kind = field.kind
    if kind == 'scalar' then return decode_scalar(field.proto_type, v) end
    if kind == 'enum'   then return decode_enum(field.enum, v) end
    if kind == 'message' then return decode_message(field.message, v) end
    error('decode_field_value: unknown kind ' .. tostring(kind), 0)
end

local function decode_map_key(key_field, k)
    local pt = key_field.proto_type
    if pt == 'string' then return k end
    if pt == 'bool' then
        if k == 'true' then return true end
        if k == 'false' then return false end
        error('map<bool, ...>: invalid key "' .. tostring(k) .. '"', 0)
    end
    if INT64_FAMILY[pt] then
        return decode_int64_value(k, pt:sub(1, 1) == 'u' or pt == 'fixed64')
    end
    -- 32-bit integer key. JSON map keys are always strings; require strict
    -- digits-only input.
    if pt == 'uint32' or pt == 'fixed32' then return decode_uint32(k) end
    return decode_int32(k)
end

local json_to_value, json_to_struct, json_to_list, json_to_any  -- forwards

json_to_any = function(v)
    if v == nil then return {type_url='', value=''} end
    if type(v) ~= 'table' then
        error('Any JSON: expected object, got ' .. type(v), 0)
    end
    local type_url = v['@type']
    if type_url == nil then
        -- Bare `{}` is an empty Any. Anything else without @type is an error.
        if next(v) ~= nil then
            error('Any JSON: missing @type', 0)
        end
        return {type_url='', value=''}
    end
    if type(type_url) ~= 'string' then
        error('Any JSON: @type must be a string', 0)
    end
    if type_url == '' then
        -- Empty @type with any other key is malformed
        -- (AnyWktRepresentationWithEmptyTypeAndValue).
        for k, _ in pairs(v) do
            if k ~= '@type' then
                error('Any JSON: empty @type with sibling fields', 0)
            end
        end
        return {type_url='', value=''}
    end
    -- A valid Any type URL has the shape "<prefix>/<full.message.name>".
    -- "not_a_url" or anything else without a slash is rejected
    -- (AnyWktRepresentationWithBadType).
    if type_url:find('/', 1, true) == nil then
        error('Any JSON: invalid @type URL "' .. type_url .. '"', 0)
    end
    local desc = pbwkt.lookup(type_url)
    if desc == nil then
        -- Opaque fallback: only accept base64-encoded `value`. A non-string
        -- value implies a Wkt representation that we cannot dispatch.
        local raw = v.value
        if raw == nil or raw == box.NULL then
            return {type_url = type_url, value = ''}
        end
        if type(raw) ~= 'string' then
            error('Any JSON: unknown type "' .. type_url .. '"', 0)
        end
        return {type_url = type_url, value = digest.base64_decode(raw)}
    end
    local payload
    if is_wkt_name(desc.name) then
        -- Spec requires WKTs to be nested under "value". Empty is the lone
        -- exception: its JSON form is `{}` so the value key is optional
        -- (AnyEmpty test sends `{"@type": ".../Empty"}` and expects success).
        local raw = v.value
        if raw == nil then
            if desc.name == 'google.protobuf.Empty' then
                payload = {}
            else
                error('Any JSON: WKT @type "' .. type_url
                      .. '" requires a "value" key', 0)
            end
        elseif raw == box.NULL and desc.name ~= 'google.protobuf.Value' then
            error('Any JSON: null value for WKT "' .. type_url .. '"', 0)
        else
            payload = raw
        end
    else
        payload = {}
        for k, mv in pairs(v) do
            if k ~= '@type' then payload[k] = mv end
        end
    end
    local inner = decode_message(desc, payload)
    local bytes = desc.encode and desc.encode(inner)
               or require('pb.codec').encode(desc, inner)
    return {type_url = type_url, value = bytes}
end

json_to_value = function(v)
    if v == nil or v == box.NULL then return PB_NULL end
    local ty = type(v)
    if ty == 'boolean' or ty == 'number' or ty == 'string' then return v end
    if ty == 'cdata' then return tonumber(v) end
    if ty == 'table' then
        local mt = getmetatable(v)
        if mt and mt.__serialize == 'seq' then return json_to_list(v) end
        if mt and mt.__serialize == 'map' then return json_to_struct(v) end
        if v[1] ~= nil then return json_to_list(v) end
        return json_to_struct(v)
    end
    error('Value JSON: unsupported type ' .. ty, 0)
end

json_to_struct = function(v)
    local out = pbwkt.struct({})
    if v == nil then return out end
    for k, mv in pairs(v) do out[k] = json_to_value(mv) end
    return out
end

json_to_list = function(v)
    local out = pbwkt.list({})
    if v == nil then return out end
    for i = 1, #v do out[i] = json_to_value(v[i]) end
    return out
end

local function decode_wkt(desc, v)
    local name = desc.name
    if name == 'google.protobuf.Empty' then
        if v ~= nil and type(v) ~= 'table' then
            error('Empty JSON: expected object, got ' .. type(v), 0)
        end
        return {}
    end
    if name == 'google.protobuf.Timestamp' then return parse_timestamp(v) end
    if name == 'google.protobuf.Duration'  then return parse_duration(v)  end
    if name == 'google.protobuf.FieldMask' then return fieldmask_from_json(v) end
    if name == 'google.protobuf.Any'       then return json_to_any(v) end
    if name == 'google.protobuf.Value'     then return json_to_value(v) end
    if name == 'google.protobuf.Struct' then
        if type(v) ~= 'table' then
            error('Struct JSON: expected object, got ' .. type(v), 0)
        end
        return json_to_struct(v)
    end
    if name == 'google.protobuf.ListValue' then
        if type(v) ~= 'table' then
            error('ListValue JSON: expected array, got ' .. type(v), 0)
        end
        return json_to_list(v)
    end
    local wrap = name:match('^google%.protobuf%.(%w+)Value$')
    if wrap then
        local wrapper_proto = {
            Int32='int32', UInt32='uint32', Int64='int64', UInt64='uint64',
            Float='float', Double='double', Bool='bool',
            String='string', Bytes='bytes',
        }
        local pt = wrapper_proto[wrap]
        if pt then return decode_scalar(pt, v) end
    end
    return nil
end

local function is_json_array(t)
    local mt = getmetatable(t)
    if mt and mt.__serialize == 'seq' then return true end
    if mt and mt.__serialize == 'map' then return false end
    if next(t) == nil then
        -- Empty `{}` from Tarantool's json.decode has no metatable; treat
        -- empty as either depending on context. For repeated-field decode
        -- we allow `[]` (empty array) or null (the caller short-circuits).
        return true
    end
    return t[1] ~= nil
end

decode_message = function(desc, v)
    if v == nil then return nil end
    local override = decode_wkt(desc, v)
    if override ~= nil then return override end
    if type(v) ~= 'table' then
        error('expected JSON object for ' .. desc.name ..
              ', got ' .. type(v), 0)
    end

    -- Build a name -> field map covering both camelCase and snake_case.
    local field_by_json_name = desc._json_field_by_name
    if field_by_json_name == nil then
        field_by_json_name = {}
        for _, f in ipairs(desc.fields) do
            field_by_json_name[f.name] = f
            field_by_json_name[to_camel(f.name)] = f
        end
        desc._json_field_by_name = field_by_json_name
    end

    local out = {}
    local oneof_seen  -- lazily allocated
    local field_seen  -- proto-name set; detects camelCase/snake_case duplicates
    for k, jv in pairs(v) do
        local f = field_by_json_name[k]
        if f ~= nil then
            -- Reject same proto field appearing under both camelCase and
            -- snake_case aliases in the same JSON object (mainline rejects;
            -- FieldNameDuplicateDifferentCasing{1,2} pin this). Literal
            -- duplicate keys (same string twice) are caught upstream by
            -- the find_duplicate_json_keys pre-scan in M.decode.
            field_seen = field_seen or {}
            if field_seen[f.name] then
                error('duplicate field "' .. f.name ..
                      '" (camelCase / snake_case aliases collide)', 0)
            end
            field_seen[f.name] = true
            local is_value_field = (f.kind == 'message' and f.message
                                   and f.message.name == 'google.protobuf.Value')
            -- NullValue-typed enum (used as a oneof presence marker) treats
            -- JSON null as "set to NULL_VALUE", not as "absent / use default".
            -- Mainline's NullValueInOtherOneofNewFormat pins this — the
            -- decoded message must record the oneof as active.
            local is_null_value_enum = (f.kind == 'enum' and f.enum
                                       and f.enum.name == 'google.protobuf.NullValue')
            local is_null_default = (jv == box.NULL)
                and not is_value_field and not is_null_value_enum
            -- Reject duplicate oneof branches. A `null` JSON value for a
            -- oneof branch means "field absent" and does NOT count as
            -- setting the oneof (matches OneofFieldNullFirst/Second tests).
            if f.oneof and not is_null_default then
                oneof_seen = oneof_seen or {}
                if oneof_seen[f.oneof] then
                    error('oneof "' .. f.oneof .. '" set multiple times', 0)
                end
                oneof_seen[f.oneof] = true
            end
            if is_null_default then -- luacheck: ignore 542
                -- proto3 JSON: null on non-Value fields = "use default"
            elseif f.kind == 'map' then
                if jv ~= box.NULL then
                    if type(jv) ~= 'table' then
                        error('field "' .. k .. '": expected JSON object for map', 0)
                    end
                    local m = {}
                    for mk, mv in pairs(jv) do
                        -- Map values must not be JSON null per spec.
                        -- (MapFieldValueIsNull conformance test).
                        if mv == box.NULL then
                            error('field "' .. k .. '": map value for key "' ..
                                  tostring(mk) .. '" is JSON null', 0)
                        end
                        local dv = decode_field_value(f.value, mv)
                        if not rawequal(dv, nil) then
                            m[decode_map_key(f.key, mk)] = dv
                        end
                    end
                    out[f.name] = m
                end
            elseif f.repeated then
                if jv ~= box.NULL then
                    if type(jv) ~= 'table' or not is_json_array(jv) then
                        error('field "' .. k .. '": expected JSON array', 0)
                    end
                    local arr = {}
                    local n = 0
                    for i = 1, #jv do
                        -- Repeated array elements must not be JSON null per
                        -- spec (RepeatedField{Message,Primitive}ElementIsNull).
                        if jv[i] == box.NULL then
                            error('field "' .. k .. '": array element ' .. i ..
                                  ' is JSON null', 0)
                        end
                        local dv = decode_field_value(f, jv[i])
                        if not rawequal(dv, nil) then
                            n = n + 1; arr[n] = dv
                        end
                    end
                    out[f.name] = arr
                end
            else
                local dv = decode_field_value(f, jv)
                if not rawequal(dv, nil) then out[f.name] = dv end
            end
        else
            -- Proto2 extension: keys of the form `[full.name]` resolve via
            -- the extendee's registered extensions table. Anything else is
            -- a truly unknown key (silently ignored per spec).
            local ext_full = k:match('^%[(.*)%]$')
            local ext = ext_full and desc.extensions_by_full_name
                and desc.extensions_by_full_name[ext_full] or nil
            if ext ~= nil then
                local exts = out._extensions
                if exts == nil then exts = {}; out._extensions = exts end
                if ext.repeated then
                    if jv ~= box.NULL and jv ~= nil then
                        if type(jv) ~= 'table' then
                            error('extension "' .. k ..
                                  '": expected JSON array for repeated', 0)
                        end
                        local arr, n = {}, 0
                        for i = 1, #jv do
                            local dv = decode_field_value(ext, jv[i])
                            if not rawequal(dv, nil) then
                                n = n + 1; arr[n] = dv
                            end
                        end
                        exts[ext_full] = arr
                    end
                else
                    local dv = decode_field_value(ext, jv)
                    if not rawequal(dv, nil) then exts[ext_full] = dv end
                end
            end
            -- Truly unknown JSON keys are silently ignored (per spec).
        end
    end
    return out
end

-- Walk the JSON source string, raising on any object that contains the same
-- literal key twice. Tarantool's `json.decode` is hash-backed and silently
-- collapses such duplicates, so without this pre-scan we'd accept payloads
-- like `{"foo":1,"foo":2}` which the conformance suite (FieldNameDuplicate)
-- requires us to reject.
--
-- This is a minimal byte walker — it tracks bracket nesting and string
-- escapes well enough to find object key boundaries, and stops at the first
-- duplicate. It does NOT replicate `json.decode`'s validation; we still rely
-- on `json.decode` to surface every other JSON syntax error.
local function find_duplicate_json_keys(s)
    local pos, len = 1, #s
    local stacks = {}      -- per-depth array of `seen` tables (object frames)
    local depth = 0
    local in_object = {}   -- depth → true if frame is an object (vs array)
    while pos <= len do
        local c = s:byte(pos)
        if c == 0x22 then  -- '"' — string literal
            local key_start = pos + 1
            local p = key_start
            while p <= len do
                local b = s:byte(p)
                if b == 0x5c then p = p + 2          -- '\\' + escaped char
                elseif b == 0x22 then break          -- closing quote
                else p = p + 1 end
            end
            if p > len then return end  -- malformed; json.decode will reject
            local key = s:sub(key_start, p - 1)
            pos = p + 1
            -- Lookahead: is the next non-whitespace char a `:` (object key)?
            -- If so, register the key in the current object frame.
            local q = pos
            while q <= len do
                local b = s:byte(q)
                if b == 0x20 or b == 0x09 or b == 0x0a or b == 0x0d then
                    q = q + 1
                else break end
            end
            if q <= len and s:byte(q) == 0x3a and in_object[depth] then
                local seen = stacks[depth]
                if seen[key] then
                    return 'duplicate JSON key "' .. key .. '"'
                end
                seen[key] = true
            end
        elseif c == 0x7b then           -- '{'
            depth = depth + 1
            stacks[depth] = {}
            in_object[depth] = true
            pos = pos + 1
        elseif c == 0x5b then           -- '['
            depth = depth + 1
            stacks[depth] = false
            in_object[depth] = false
            pos = pos + 1
        elseif c == 0x7d or c == 0x5d then  -- '}' or ']'
            stacks[depth] = nil
            in_object[depth] = nil
            depth = depth - 1
            pos = pos + 1
        else
            pos = pos + 1
        end
    end
end

---@param desc pb.Descriptor
---@param s    string
---@param opts? pb.JsonDecodeOpts
---@return table
function M.decode(desc, s, opts)
    local dup_err = find_duplicate_json_keys(s)
    if dup_err ~= nil then error(dup_err, 0) end
    local v = json.decode(s)
    if v == nil or v == box.NULL then
        -- Top-level JSON null is rejected for regular messages but is a
        -- legal Value (it maps to NullValue.NULL_VALUE).
        if desc.name == 'google.protobuf.Value' then
            return PB_NULL
        end
        error('top-level JSON null is not a valid message', 0)
    end
    -- Install opts for the recursive enum-name resolution. Cleared in a
    -- finally-like xpcall guard so an error inside decode_message doesn't
    -- leak state into the next caller (especially across fibers — though
    -- pb.json.decode never yields, defensiveness is cheap).
    CURRENT_OPTS = opts
    local ok, out = pcall(decode_message, desc, v)
    CURRENT_OPTS = nil
    if not ok then error(out, 0) end
    return out
end

-- decode_field(desc, field_name, s, opts) -> value of one top-level
-- field of `desc` parsed from the JSON text `s` (an object for a
-- message or map field, an array for a repeated one, a scalar
-- otherwise). Returns nil for JSON null. Used by HTTP transcoding for
-- `body: "<field>"`.
---@param desc pb.Descriptor
---@param field_name string   proto name of a top-level field of desc
---@param s    string
---@param opts? pb.JsonDecodeOpts
---@return any
function M.decode_field(desc, field_name, s, opts)
    local f = top_field(desc, field_name)
    if f == nil then
        error('pb.json.decode_field: ' .. tostring(desc.name) ..
              ' has no field "' .. tostring(field_name) .. '"', 0)
    end
    local dup_err = find_duplicate_json_keys(s)
    if dup_err ~= nil then error(dup_err, 0) end
    local v = json.decode(s)
    if v == nil or v == box.NULL then return nil end
    -- Decode through a one-key wrapper so repeated, map and null
    -- handling is exactly the one M.decode applies to that field.
    CURRENT_OPTS = opts
    local ok, out = pcall(decode_message, desc, {[f.name] = v})
    CURRENT_OPTS = nil
    if not ok then error(out, 0) end
    return out[f.name]
end

M.to_json_value   = to_json_value
M.from_json_value = decode_message

return M
