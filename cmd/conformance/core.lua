-- Core dispatch for the Google protobuf conformance protocol.
--
-- Decodes a `conformance.ConformanceRequest` (wire bytes), runs it through
-- our codec/JSON in the requested format, and returns the encoded
-- `conformance.ConformanceResponse` bytes. The stdin/stdout framing is
-- handled by the thin wrapper in `cmd/conformance-runner.lua`.
--
-- Split out as a module so the luatest suite can drive `handle_request`
-- directly without spawning a subprocess.

local pb           = require('pb')
local conformance  = require('full.conformance.conformance_pb')
local proto3_tests = require('full.protobuf_test_messages.proto3.test_messages_proto3_pb')
local proto2_tests = require('full.protobuf_test_messages.proto2.test_messages_proto2_pb')

local M = {}

-- Map of supported `message_type` -> descriptor. Any other message type
-- yields a `skipped` response so we don't claim conformance for protos we
-- don't actually support yet (editions; MessageSet-flavored proto2 schemas
-- still need work — those tests appear as runtime/parse errors below).
local MESSAGE_REGISTRY = {
    ['protobuf_test_messages.proto3.TestAllTypesProto3'] =
        proto3_tests.TestAllTypesProto3_descriptor,
    ['protobuf_test_messages.proto2.TestAllTypesProto2'] =
        proto2_tests.TestAllTypesProto2_descriptor,
    ['conformance.FailureSet'] =
        conformance.FailureSet_descriptor,
}

-- Register test messages in the runtime's Any/WKT registry so JSON Any
-- fields with `@type` pointing at our test types resolve on decode.
pb.register(proto3_tests.TestAllTypesProto3_descriptor)
pb.register(proto2_tests.TestAllTypesProto2_descriptor)

local WIRE_FORMAT = conformance.WireFormat
local PROTOBUF    = WIRE_FORMAT.PROTOBUF
local JSON        = WIRE_FORMAT.JSON
local JSPB        = WIRE_FORMAT.JSPB
local TEXT_FORMAT = WIRE_FORMAT.TEXT_FORMAT

local function dispatch(req)
    local desc = MESSAGE_REGISTRY[req.message_type]
    if desc == nil then
        return {skipped = 'unsupported message type: ' ..
            tostring(req.message_type)}
    end

    -- 1. Decode the input payload into a Lua table.
    local msg
    if req.protobuf_payload ~= nil then
        local ok, decoded = pcall(pb.decode, desc, req.protobuf_payload)
        if not ok then
            return {parse_error = 'protobuf decode failed: ' ..
                tostring(decoded)}
        end
        msg = decoded
    elseif req.json_payload ~= nil then
        -- JSON_IGNORE_UNKNOWN_PARSING_TEST tells the testee to silently
        -- drop unknown enum names (and unknown fields). Other categories
        -- get the strict default that rejects them.
        local json_opts = {ignore_unknown_fields = (
            req.test_category == conformance.TestCategory.JSON_IGNORE_UNKNOWN_PARSING_TEST)}
        local ok, decoded = pcall(pb.json.decode, desc, req.json_payload, json_opts)
        if not ok then
            return {parse_error = 'json decode failed: ' .. tostring(decoded)}
        end
        msg = decoded
    elseif req.jspb_payload ~= nil then
        return {skipped = 'jspb input not supported'}
    elseif req.text_payload ~= nil then
        local ok, decoded = pcall(pb.text.decode, desc, req.text_payload)
        if not ok then
            return {parse_error = 'text decode failed: ' .. tostring(decoded)}
        end
        msg = decoded
    else
        return {runtime_error = 'no payload set in ConformanceRequest'}
    end

    -- 2. Serialize in the requested output format.
    local out_fmt = req.requested_output_format
    if out_fmt == PROTOBUF then
        local ok, bytes = pcall(pb.encode, desc, msg)
        if not ok then
            return {serialize_error = 'protobuf encode failed: ' ..
                tostring(bytes)}
        end
        return {protobuf_payload = bytes}
    elseif out_fmt == JSON then
        -- Optional opt-out: the Google harness crashes inside jsoncpp
        -- when comparing our currently-imperfect JSON output (enum
        -- numerics, map<K,V> shape, oneof object form). Setting
        -- PB_CONFORMANCE_SKIP_JSON=1 in the container short-circuits to
        -- `skipped` so the suite completes and PROTOBUF coverage stays
        -- measurable; the host tests run without the flag and still
        -- exercise the JSON output path end-to-end.
        -- Check explicitly for "1" so docker `-e PB_CONFORMANCE_SKIP_JSON=`
        -- (empty string) can disable the gate without rebuilding the image.
        if os.getenv('PB_CONFORMANCE_SKIP_JSON') == '1' then
            return {skipped =
                'JSON output deferred (see test/conformance/known_failures.txt)'}
        end
        local ok, jbytes = pcall(pb.json.encode, desc, msg)
        if not ok then
            return {serialize_error = 'json encode failed: ' ..
                tostring(jbytes)}
        end
        return {json_payload = jbytes}
    elseif out_fmt == TEXT_FORMAT then
        local opts = {print_unknown_fields = req.print_unknown_fields == true}
        local ok, tbytes = pcall(pb.text.encode, desc, msg, opts)
        if not ok then
            return {serialize_error = 'text encode failed: ' ..
                tostring(tbytes)}
        end
        return {text_payload = tbytes}
    elseif out_fmt == JSPB then
        return {skipped = 'jspb output not supported'}
    else
        return {runtime_error = 'unknown requested_output_format: ' ..
            tostring(out_fmt)}
    end
end

-- Takes the raw bytes of a ConformanceRequest, returns the raw bytes of
-- a ConformanceResponse. Never throws — every failure path produces a
-- well-formed ConformanceResponse so the conformance runner stays synced.
function M.handle_request(req_bytes)
    local ok, req = pcall(conformance.ConformanceRequest_decode, req_bytes)
    if not ok then
        return conformance.ConformanceResponse_encode(
            {runtime_error = 'failed to decode ConformanceRequest: ' ..
                tostring(req)})
    end
    local resp = dispatch(req)
    local ok2, bytes = pcall(conformance.ConformanceResponse_encode, resp)
    if not ok2 then
        return conformance.ConformanceResponse_encode(
            {runtime_error = 'failed to encode response: ' .. tostring(bytes)})
    end
    return bytes
end

-- Expose for introspection / extension.
M.MESSAGE_REGISTRY = MESSAGE_REGISTRY

return M
