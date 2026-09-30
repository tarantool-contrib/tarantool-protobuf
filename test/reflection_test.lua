-- pb.reflection: grpc.reflection.v1 / v1alpha ServerReflection served
-- through the in-process transports, driven by the clients generated
-- from the upstream reflection.proto.

local t      = require('luatest')
local pb     = require('pb')
local codec  = require('pb.codec')
local descpb = require('pb.descriptor_pb')

local V1      = require('pb.gen.grpc.reflection.v1.reflection_pb')
local V1ALPHA = require('pb.gen.grpc.reflection.v1alpha.reflection_pb')

local NOT_FOUND = pb.grpc.code.NOT_FOUND

local function file_name(bytes)
    return codec.decode(descpb.FileDescriptorProto, bytes).name
end

local function names_of(resp)
    t.assert_type(resp.file_descriptor_response, 'table',
        'expected a file_descriptor_response, got ' .. require('json').encode(resp))
    local out = {}
    for i, b in ipairs(resp.file_descriptor_response.file_descriptor_proto or {}) do
        out[i] = file_name(b)
    end
    return out
end

-- A reflection "session": one ServerReflectionInfo stream, one request
-- and one response at a time.
local function session(transport, mod)
    local call = (mod or V1).ServerReflection_client(transport).ServerReflectionInfo({})
    return {
        ask = function(_, req)
            call:send(req)
            local resp, err = call:recv()
            t.assert(resp ~= nil, 'no response: ' .. tostring(err))
            return resp
        end,
        call = call,
    }
end

for _, mode in ipairs({'full', 'runtime'}) do
    local hello   = require(mode .. '.hello.hello_pb')
    local library = require(mode .. '.library.library_pb')
    local g = t.group('reflection.' .. mode)

    local function transport()
        local services = {hello.Greeter_server({}), library.Library_server({})}
        local refl = pb.reflection.new({services = services})
        local all = {services[1], services[2]}
        for _, s in ipairs(refl:servers()) do all[#all + 1] = s end
        return pb.grpc.multiplex(all)
    end

    g.test_list_services = function()
        for _, mod in ipairs({V1, V1ALPHA}) do
            local s = session(transport(), mod)
            local resp = s:ask({host = 'h1', list_services = ''})
            t.assert_equals(resp.valid_host, 'h1')
            t.assert_equals(resp.original_request, {host = 'h1', list_services = ''})
            t.assert_equals(resp.list_services_response, {service = {
                {name = 'grpc.reflection.v1.ServerReflection'},
                {name = 'grpc.reflection.v1alpha.ServerReflection'},
                {name = 'hello.Greeter'},
                {name = 'library.Library'},
            }})
        end
    end

    g.test_file_by_filename_with_transitive_dependencies = function()
        local s = session(transport())
        local resp = s:ask({file_by_filename = 'library.proto'})
        t.assert_equals(resp.original_request, {file_by_filename = 'library.proto'})
        -- Breadth first: the file, its imports, then theirs.
        t.assert_equals(names_of(resp), {
            'library.proto',
            'google/api/annotations.proto',
            'google/protobuf/empty.proto',
            'google/api/http.proto',
            'google/protobuf/descriptor.proto',
        })
        t.assert_equals(resp.file_descriptor_response.file_descriptor_proto[1],
                        library._file_descriptor)
    end

    g.test_files_already_sent_are_skipped_per_stream = function()
        local tr = transport()
        local s = session(tr)
        t.assert_equals(#names_of(s:ask({file_by_filename = 'library.proto'})), 5)

        -- hello.proto imports seven WKT files; empty.proto went out with
        -- library.proto on this stream.
        local got = names_of(s:ask({file_by_filename = 'hello.proto'}))
        t.assert_equals(got, {
            'hello.proto',
            'google/protobuf/timestamp.proto',
            'google/protobuf/duration.proto',
            'google/protobuf/wrappers.proto',
            'google/protobuf/struct.proto',
            'google/protobuf/any.proto',
            'google/protobuf/field_mask.proto',
        })

        -- The requested file itself is always sent, its imports are not.
        t.assert_equals(names_of(s:ask({file_by_filename = 'library.proto'})),
                        {'library.proto'})
        t.assert_equals(names_of(s:ask({file_containing_symbol = 'google.api.HttpRule'})),
                        {'google/api/http.proto'})

        -- A new stream starts from scratch.
        local fresh = session(tr)
        t.assert_equals(#names_of(fresh:ask({file_by_filename = 'library.proto'})), 5)
    end

    g.test_file_containing_symbol = function()
        local s = session(transport())
        local cases = {
            {'hello.HelloRequest', 'hello.proto'},              -- message
            {'hello.Person.AddressesByLabelEntry', 'hello.proto'}, -- map entry
            {'library.GetMessageRequest.SubMessage', 'library.proto'}, -- nested
            {'hello.Status', 'hello.proto'},                    -- enum
            {'hello.OK', 'hello.proto'},                        -- enum value
            {'hello.Greeter', 'hello.proto'},                   -- service
            {'hello.Greeter.SayHello', 'hello.proto'},          -- method
            {'library.Library.WatchShelf', 'library.proto'},    -- streaming method
            {'hello.HelloRequest.name', 'hello.proto'},         -- field
            {'hello.Result.outcome', 'hello.proto'},            -- oneof
            {'google.protobuf.FieldDescriptorProto.Type',
             'google/protobuf/descriptor.proto'},               -- nested enum
            {'google.protobuf.FieldDescriptorProto.TYPE_STRING',
             'google/protobuf/descriptor.proto'},               -- nested enum value
            {'google.api.http', 'google/api/annotations.proto'}, -- extension
        }
        for _, c in ipairs(cases) do
            local resp = s:ask({file_containing_symbol = c[1]})
            t.assert_equals(names_of(resp)[1], c[2], c[1])
        end
    end

    g.test_not_found_keeps_the_stream_open = function()
        local s = session(transport())
        local cases = {
            {file_by_filename = 'no/such.proto'},
            {file_containing_symbol = 'no.Such'},
            -- Enum values live beside their enum, not inside it.
            {file_containing_symbol = 'hello.Status.OK'},
            {file_containing_symbol = 'hello.Greeter.NoSuchMethod'},
            {file_containing_extension = {containing_type = 'google.protobuf.MethodOptions',
                                          extension_number = 1}},
            {all_extension_numbers_of_type = 'no.Such'},
        }
        for _, req in ipairs(cases) do
            local resp = s:ask(req)
            t.assert_equals(resp.original_request, req)
            t.assert_type(resp.error_response, 'table')
            t.assert_equals(resp.error_response.error_code, NOT_FOUND)
            t.assert_type(resp.error_response.error_message, 'string')
            t.assert_equals(resp.file_descriptor_response, nil)
        end
        t.assert_equals(names_of(s:ask({file_by_filename = 'hello.proto'}))[1], 'hello.proto')
    end

    g.test_extensions = function()
        local s = session(transport())
        local resp = s:ask({file_containing_extension = {
            containing_type = 'google.protobuf.MethodOptions',
            extension_number = 72295728,
        }})
        t.assert_equals(names_of(resp)[1], 'google/api/annotations.proto')

        resp = s:ask({all_extension_numbers_of_type = 'google.protobuf.MethodOptions'})
        t.assert_equals(resp.all_extension_numbers_response.base_type_name,
                        'google.protobuf.MethodOptions')
        t.assert_items_include(resp.all_extension_numbers_response.extension_number,
                               {72295728})

        -- A known type without extensions: an empty list, not an error.
        resp = s:ask({all_extension_numbers_of_type = 'hello.HelloRequest'})
        t.assert_equals(resp.error_response, nil)
        t.assert_equals(resp.all_extension_numbers_response, {
            base_type_name = 'hello.HelloRequest',
        })
    end

    g.test_empty_request_fails_the_stream = function()
        local s = session(transport())
        s.call:send({host = 'h'})
        local resp, err = s.call:recv()
        t.assert_equals(resp, nil)
        t.assert(pb.grpc.is_status(err), tostring(err))
        t.assert_equals(err.code, pb.grpc.code.INVALID_ARGUMENT)
    end

    g.test_stream_ends_on_close_send = function()
        local s = session(transport())
        t.assert_equals(#s:ask({list_services = ''}).list_services_response.service, 4)
        s.call:close_send()
        local resp, err = s.call:recv()
        t.assert_equals(resp, nil)
        t.assert_equals(err, nil)
    end
end

local g = t.group('reflection')

-- FileDescriptorProto{name, package, message_type {name}} by hand.
local function fdp(name, pkg, message)
    local m = '\x0a' .. string.char(#message) .. message
    return '\x0a' .. string.char(#name) .. name
        .. '\x12' .. string.char(#pkg) .. pkg
        .. '\x22' .. string.char(#m) .. m
end

g.test_index_follows_the_registry = function()
    t.assert_equals(pb.reflection.file_containing_symbol('late.Added'), nil)
    pb.descriptors.register(fdp('late/added.proto', 'late', 'Added'))
    t.assert_equals(pb.reflection.file_containing_symbol('late.Added'), 'late/added.proto')
    -- A replaced descriptor replaces its symbols' file.
    pb.descriptors.register(fdp('late/added.proto', 'late', 'Renamed'))
    t.assert_equals(pb.reflection.file_containing_symbol('late.Renamed'), 'late/added.proto')
    t.assert_equals(pb.reflection.file_containing_symbol('late.Added'), nil)
end

-- Two files declaring one type: the first registered keeps all of its
-- symbols, the second is left out whole (protobuf-go: "name conflict").
g.test_conflicting_file_is_left_out_whole = function()
    local warnings = {}
    local orig_warn = pb.reflection._warn
    pb.reflection._warn = function(msg) warnings[#warnings + 1] = msg end

    local function file(name, nested)
        return codec.encode(descpb.FileDescriptorProto, {
            name = name,
            package = 'collision',
            message_type = {{name = 'Shared', nested_type = {{name = nested}}}},
        })
    end
    local ok, err = pcall(function()
        -- Registered first, sorts last.
        pb.descriptors.register(file('z-original.proto', 'Old'))
        pb.descriptors.register(file('a-new.proto', 'New'))

        local r = pb.reflection
        t.assert_equals(r.file_containing_symbol('collision.Shared'), 'z-original.proto')
        t.assert_equals(r.file_containing_symbol('collision.Shared.Old'), 'z-original.proto')
        t.assert_equals(r.file_containing_symbol('collision.Shared.New'), nil)
        t.assert_equals(#warnings, 1)
        t.assert_str_contains(warnings[1], 'a-new.proto')
        t.assert_str_contains(warnings[1], 'collision.Shared')

        local s = session(pb.grpc.multiplex(pb.reflection.servers()))
        local resp = s:ask({file_containing_symbol = 'collision.Shared.New'})
        t.assert_equals(resp.error_response.error_code, NOT_FOUND)
        t.assert_equals(names_of(s:ask({file_containing_symbol = 'collision.Shared'})),
                        {'z-original.proto'})

        -- Replacing the winning file is not a conflict with itself, and
        -- the loser is not warned about twice.
        pb.descriptors.register(file('z-original.proto', 'Older'))
        t.assert_equals(r.file_containing_symbol('collision.Shared.Older'), 'z-original.proto')
        t.assert_equals(r.file_containing_symbol('collision.Shared.New'), nil)
        t.assert_equals(#warnings, 1)

        -- The left-out file is not served by name either, and a file
        -- importing both gets only the accepted one, like a missing
        -- import. pb.descriptors itself keeps both.
        resp = s:ask({file_by_filename = 'a-new.proto'})
        t.assert_equals(resp.error_response.error_code, NOT_FOUND)
        t.assert_type(pb.descriptors.file('a-new.proto'), 'string')
        pb.descriptors.register(codec.encode(descpb.FileDescriptorProto, {
            name = 'uses-both.proto', package = 'user',
            dependency = {'z-original.proto', 'a-new.proto'},
            message_type = {{name = 'X'}},
        }))
        local fresh = session(pb.grpc.multiplex(pb.reflection.servers()))
        t.assert_equals(names_of(fresh:ask({file_by_filename = 'uses-both.proto'})),
                        {'uses-both.proto', 'z-original.proto'})

        -- Hot reload that removes the conflict brings the file back.
        pb.descriptors.register(codec.encode(descpb.FileDescriptorProto, {
            name = 'a-new.proto', package = 'collision',
            message_type = {{name = 'Fresh'}},
        }))
        t.assert_equals(r.file_containing_symbol('collision.Fresh'), 'a-new.proto')
        fresh = session(pb.grpc.multiplex(pb.reflection.servers()))
        t.assert_equals(names_of(fresh:ask({file_by_filename = 'uses-both.proto'})),
                        {'uses-both.proto', 'z-original.proto', 'a-new.proto'})
        t.assert_equals(names_of(fresh:ask({file_by_filename = 'a-new.proto'})),
                        {'a-new.proto'})
        t.assert_equals(#warnings, 1)
    end)
    pb.reflection._warn = orig_warn
    if not ok then error(err, 0) end
end

g.test_services_forms = function()
    local hello = require('full.hello.hello_pb')
    local refl = pb.reflection.new({services = {
        hello.Greeter_server({}),   -- generated server table
        hello.Greeter_service,      -- service descriptor (duplicate)
        'x.Other',                  -- full name
    }})
    t.assert_equals(refl:services(), {'hello.Greeter', 'x.Other'})
    refl:server('v1alpha')
    refl:add('a.First')
    t.assert_equals(refl:services(),
        {'a.First', 'grpc.reflection.v1alpha.ServerReflection', 'hello.Greeter', 'x.Other'})

    local dynamic = {'one.Svc'}
    local refl2 = pb.reflection.new({services = function() return dynamic end})
    refl2:servers()
    dynamic[2] = 'two.Svc'
    t.assert_equals(refl2:services(), {
        'grpc.reflection.v1.ServerReflection',
        'grpc.reflection.v1alpha.ServerReflection',
        'one.Svc', 'two.Svc',
    })
    t.assert_error_msg_contains('needs an instance built with a services array',
        refl2.add, refl2, 'x')
end

g.test_bad_arguments = function()
    t.assert_error_msg_contains('opts.services must be',
        pb.reflection.new, {services = 'x'})
    t.assert_error_msg_contains('a service is a server table',
        pb.reflection.new, {services = {42}})
    t.assert_error_msg_contains('unknown version',
        function() pb.reflection.new():server('v2') end)
end

g.test_server_tables_have_the_generated_shape = function()
    local v1, v1alpha = unpack(pb.reflection.servers())
    t.assert_is(v1.service, V1.ServerReflection_service)
    t.assert_is(v1alpha.service, V1ALPHA.ServerReflection_service)
    t.assert_equals(v1.streams['/grpc.reflection.v1.ServerReflection/ServerReflectionInfo'].kind,
                    'bidi')
    t.assert_equals(v1alpha.streams['/grpc.reflection.v1alpha.ServerReflection/ServerReflectionInfo'].kind,
                    'bidi')
end

g.test_reflection_describes_itself = function()
    local tr = pb.grpc.multiplex(pb.reflection.servers())
    local s = session(tr)
    local resp = s:ask({file_containing_symbol = 'grpc.reflection.v1.ServerReflection'})
    t.assert_equals(names_of(resp), {'grpc/reflection/v1/reflection.proto'})
    resp = s:ask({file_containing_symbol = 'grpc.reflection.v1alpha.ServerReflection'})
    t.assert_equals(names_of(resp), {'grpc/reflection/v1alpha/reflection.proto'})
end
