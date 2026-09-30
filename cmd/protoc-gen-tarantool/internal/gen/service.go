package gen

import (
	"fmt"
	"strings"

	"google.golang.org/protobuf/compiler/protogen"
	"google.golang.org/protobuf/types/descriptorpb"
)

// streamKind classifies an RPC method for codegen branching.
type streamKind int

const (
	kindUnary streamKind = iota
	kindServerStream
	kindClientStream
	kindBidi
)

func classify(m *protogen.Method) streamKind {
	cs, ss := m.Desc.IsStreamingClient(), m.Desc.IsStreamingServer()
	switch {
	case cs && ss:
		return kindBidi
	case ss:
		return kindServerStream
	case cs:
		return kindClientStream
	default:
		return kindUnary
	}
}

// emitService emits the descriptor + client + server factory for a single
// gRPC service. The descriptor is mode-independent; client/server factories
// reference the same per-message _encode/_decode functions that the rest of
// the module already provides.
func emitService(w *writer, file *protogen.File, svc *protogen.Service, imports map[string]string, prefix string) {
	name := string(svc.Desc.Name())
	fullName := string(svc.Desc.FullName())
	selfPath := luaPackagePath(file.Desc, prefix)

	emitProtoDoc(w, svc.Comments.Leading)
	w.line("-- Service: %s", fullName)
	w.line("M.%s_service = {", name)
	w.line("    name = %q,", fullName)
	w.line("    full_name = %q,", "/"+fullName)
	w.line("    methods = {")
	for _, m := range svc.Methods {
		mname := string(m.Desc.Name())
		emitProtoDocIndented(w, m.Comments.Leading, "        ")
		w.line("        %s = {", mname)
		w.line("            name = %q,", mname)
		w.line("            full_name = %q,", "/"+fullName+"/"+mname)
		w.line("            input = %s,", typeRef(file, m.Input.Desc, selfPath, imports, "_descriptor", prefix))
		w.line("            output = %s,", typeRef(file, m.Output.Desc, selfPath, imports, "_descriptor", prefix))
		if m.Desc.IsStreamingClient() {
			w.line("            client_streaming = true,")
		}
		if m.Desc.IsStreamingServer() {
			w.line("            server_streaming = true,")
		}
		mopts, _ := m.Desc.Options().(*descriptorpb.MethodOptions)
		// The method's idempotency level by enum name, omitted when
		// unknown (the default). Like `http`, a normalised copy of what
		// `options` also mirrors: the Connect protocol serves GET only
		// for NO_SIDE_EFFECTS methods.
		if lvl := mopts.GetIdempotencyLevel(); lvl != descriptorpb.MethodOptions_IDEMPOTENCY_UNKNOWN {
			w.line("            idempotency_level = %q,", lvl.String())
		}
		// Normalised google.api.http routing rules. The raw extension
		// also stays in `options` below: `options` mirrors the
		// descriptor for every extension alike, `http` is the flattened
		// shape a transcoder routes on.
		rules, err := methodHTTPRules(mopts)
		if err != nil {
			panic("tarantool-protobuf: " + fullName + "." + mname + ": google.api.http: " + err.Error())
		}
		if len(rules) > 0 {
			w.line("            http = {")
			for _, r := range rules {
				w.line("                %s,", luaHTTPBinding(r))
			}
			w.line("            },")
		}
		if opts := w.renderOpts(m.Desc.Options()); opts != "" {
			w.line("            options = %s,", opts)
		}
		w.line("        },")
	}
	w.line("    },")
	// `methods` is keyed by name, so it loses the declaration order;
	// consumers that need it (the HTTP transcoder's tie-break) read
	// this array.
	order := make([]string, 0, len(svc.Methods))
	for _, m := range svc.Methods {
		order = append(order, fmt.Sprintf("%q", string(m.Desc.Name())))
	}
	w.line("    method_order = {%s},", strings.Join(order, ", "))
	if opts := w.renderOpts(svc.Desc.Options()); opts != "" {
		w.line("    options = %s,", opts)
	}
	w.line("}")
	w.line("")

	emitServiceClient(w, file, svc, imports, prefix, selfPath)
	emitServiceServer(w, file, svc, imports, prefix, selfPath)
}

// emitServiceClient emits a constructor `function M.<Service>_client(transport)`
// that returns a table with one entry per RPC method:
//
//   - Unary methods are direct functions: `client.SayHello(req, ctx) -> reply`
//   - Streaming methods return a stream object (see pb.grpc for the shape):
//     `client.StreamHellos(req, ctx) -> {recv, cancel}`
//     `client.CollectHellos(ctx)    -> {send, close_send, recv, cancel}`
//     `client.Chat(ctx)             -> {send, close_send, recv, cancel}`
func emitServiceClient(w *writer, file *protogen.File, svc *protogen.Service, imports map[string]string, prefix string, selfPath string) {
	name := string(svc.Desc.Name())
	w.line("function M.%s_client(transport)", name)
	w.line("    if transport == nil then error(\"%s_client: transport is required\", 0) end", name)
	w.line("    return {")
	for _, m := range svc.Methods {
		mname := string(m.Desc.Name())
		path := "/" + string(svc.Desc.FullName()) + "/" + mname
		inputEnc := typeRef(file, m.Input.Desc, selfPath, imports, "_encode", prefix)
		outputDec := typeRef(file, m.Output.Desc, selfPath, imports, "_decode", prefix)

		emitProtoDocIndented(w, m.Comments.Leading, "        ")
		switch classify(m) {
		case kindUnary:
			w.line("        %s = function(req, ctx)", mname)
			w.line("            local req_bytes = %s(req)", inputEnc)
			w.line("            local resp_bytes = transport:unary(%q, req_bytes, ctx)", path)
			w.line("            return %s(resp_bytes)", outputDec)
			w.line("        end,")
		case kindServerStream:
			w.line("        %s = function(req, ctx)", mname)
			w.line("            local req_bytes = %s(req)", inputEnc)
			w.line("            local raw = transport:server_stream(%q, req_bytes, ctx)", path)
			w.line("            return pb.grpc.wrap_server_stream(raw, %s)", outputDec)
			w.line("        end,")
		case kindClientStream:
			w.line("        %s = function(ctx)", mname)
			w.line("            local raw = transport:client_stream(%q, ctx)", path)
			w.line("            return pb.grpc.wrap_call(raw, %s, %s)", inputEnc, outputDec)
			w.line("        end,")
		case kindBidi:
			w.line("        %s = function(ctx)", mname)
			w.line("            local raw = transport:bidi(%q, ctx)", path)
			w.line("            return pb.grpc.wrap_call(raw, %s, %s)", inputEnc, outputDec)
			w.line("        end,")
		}
	}
	w.line("    }")
	w.line("end")
	w.line("")
}

// emitServiceServer emits `function M.<Service>_server(impl)` returning
// {service, methods, streams}. `methods` holds unary handlers keyed by
// path; `streams` holds streaming handlers keyed by path. Each streaming
// entry is `{kind = '...', handler = function(req_bytes, server_view, ctx)}`
// — see pb.grpc for the transport's expectations.
//
// User-supplied impl functions speak decoded messages; the generated
// wrappers handle the per-message encode/decode boundary so user code
// stays free of wire details.
func emitServiceServer(w *writer, file *protogen.File, svc *protogen.Service, imports map[string]string, prefix string, selfPath string) {
	name := string(svc.Desc.Name())
	w.line("function M.%s_server(impl)", name)
	w.line("    if type(impl) ~= 'table' then error(\"%s_server: impl table is required\", 0) end", name)
	w.line("    return {")
	w.line("        service = M.%s_service,", name)
	w.line("        methods = {")
	for _, m := range svc.Methods {
		if classify(m) != kindUnary {
			continue
		}
		mname := string(m.Desc.Name())
		path := "/" + string(svc.Desc.FullName()) + "/" + mname
		inputDec := typeRef(file, m.Input.Desc, selfPath, imports, "_decode", prefix)
		outputEnc := typeRef(file, m.Output.Desc, selfPath, imports, "_encode", prefix)

		emitProtoDocIndented(w, m.Comments.Leading, "            ")
		w.line("            [%q] = function(req_bytes, ctx)", path)
		w.line("                local handler = impl.%s", mname)
		w.line("                if handler == nil then pb.grpc.error(pb.grpc.code.UNIMPLEMENTED, \"%s.%s: handler missing\") end", name, mname)
		w.line("                local req = %s(req_bytes)", inputDec)
		w.line("                local resp = handler(req, ctx)")
		w.line("                return %s(resp)", outputEnc)
		w.line("            end,")
	}
	w.line("        },")
	w.line("        streams = {")
	for _, m := range svc.Methods {
		kind := classify(m)
		if kind == kindUnary {
			continue
		}
		mname := string(m.Desc.Name())
		path := "/" + string(svc.Desc.FullName()) + "/" + mname
		inputDec := typeRef(file, m.Input.Desc, selfPath, imports, "_decode", prefix)
		outputEnc := typeRef(file, m.Output.Desc, selfPath, imports, "_encode", prefix)

		emitProtoDocIndented(w, m.Comments.Leading, "            ")
		switch kind {
		case kindServerStream:
			w.line("            [%q] = {", path)
			w.line("                kind = 'server_stream',")
			w.line("                handler = function(req_bytes, server_view, ctx)")
			w.line("                    local handler = impl.%s", mname)
			w.line("                    if handler == nil then pb.grpc.error(pb.grpc.code.UNIMPLEMENTED, \"%s.%s: handler missing\") end", name, mname)
			w.line("                    local req = %s(req_bytes)", inputDec)
			w.line("                    local wrapped = pb.grpc.wrap_server_view(server_view, nil, %s)", outputEnc)
			w.line("                    handler(req, wrapped, ctx)")
			w.line("                end,")
			w.line("            },")
		case kindClientStream:
			w.line("            [%q] = {", path)
			w.line("                kind = 'client_stream',")
			w.line("                handler = function(_, server_view, ctx)")
			w.line("                    local handler = impl.%s", mname)
			w.line("                    if handler == nil then pb.grpc.error(pb.grpc.code.UNIMPLEMENTED, \"%s.%s: handler missing\") end", name, mname)
			w.line("                    local wrapped = pb.grpc.wrap_server_view(server_view, %s, nil)", inputDec)
			w.line("                    local resp = handler(wrapped, ctx)")
			w.line("                    if resp == nil then error(\"%s.%s: handler returned nil response\", 0) end", name, mname)
			w.line("                    server_view:send(%s(resp))", outputEnc)
			w.line("                end,")
			w.line("            },")
		case kindBidi:
			w.line("            [%q] = {", path)
			w.line("                kind = 'bidi',")
			w.line("                handler = function(_, server_view, ctx)")
			w.line("                    local handler = impl.%s", mname)
			w.line("                    if handler == nil then pb.grpc.error(pb.grpc.code.UNIMPLEMENTED, \"%s.%s: handler missing\") end", name, mname)
			w.line("                    local wrapped = pb.grpc.wrap_server_view(server_view, %s, %s)", inputDec, outputEnc)
			w.line("                    handler(wrapped, ctx)")
			w.line("                end,")
			w.line("            },")
		}
	}
	w.line("        },")
	w.line("    }")
	w.line("end")
	w.line("")
}
