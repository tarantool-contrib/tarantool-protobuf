package servergo

import (
	"context"
	"errors"
	"io"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	reflectionpb "google.golang.org/grpc/reflection/grpc_reflection_v1"
	reflectionalphapb "google.golang.org/grpc/reflection/grpc_reflection_v1alpha"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/descriptorpb"
	"google.golang.org/protobuf/types/dynamicpb"
)

// The schema as the server's reflection service describes it; no .proto
// file and no generated Go code of the example services is used.
var (
	schemaOnce  sync.Once
	schemaFiles *protoregistry.Files
	schemaErr   error
)

// fetchFiles asks the reflection service for the files defining the
// given symbols, then for every import it has not sent yet, and links
// the result with protodesc.
func fetchFiles(t *testing.T, s *server, symbols ...string) (*protoregistry.Files, error) {
	stream, err := reflectionpb.NewServerReflectionClient(s.conn).ServerReflectionInfo(ctxT(t, 10*time.Second))
	if err != nil {
		return nil, err
	}
	defer func() { _ = stream.CloseSend() }()

	got := map[string]*descriptorpb.FileDescriptorProto{}
	ask := func(req *reflectionpb.ServerReflectionRequest) error {
		if err := stream.Send(req); err != nil {
			return err
		}
		resp, err := stream.Recv()
		if err != nil {
			return err
		}
		if e := resp.GetErrorResponse(); e != nil {
			return status.Error(codes.Code(e.GetErrorCode()), e.GetErrorMessage())
		}
		for _, b := range resp.GetFileDescriptorResponse().GetFileDescriptorProto() {
			fdp := &descriptorpb.FileDescriptorProto{}
			if err := proto.Unmarshal(b, fdp); err != nil {
				return err
			}
			got[fdp.GetName()] = fdp
		}
		return nil
	}
	for _, sym := range symbols {
		err := ask(&reflectionpb.ServerReflectionRequest{
			MessageRequest: &reflectionpb.ServerReflectionRequest_FileContainingSymbol{FileContainingSymbol: sym},
		})
		if err != nil {
			return nil, err
		}
	}
	// Imports already sent on this stream are skipped by the server, so
	// everything should be here; ask by name for anything missing.
	for {
		var missing []string
		for _, fdp := range got {
			for _, dep := range fdp.GetDependency() {
				if got[dep] == nil {
					missing = append(missing, dep)
				}
			}
		}
		if len(missing) == 0 {
			break
		}
		for _, name := range missing {
			err := ask(&reflectionpb.ServerReflectionRequest{
				MessageRequest: &reflectionpb.ServerReflectionRequest_FileByFilename{FileByFilename: name},
			})
			if err != nil {
				return nil, err
			}
		}
	}
	set := &descriptorpb.FileDescriptorSet{}
	for _, fdp := range got {
		set.File = append(set.File, fdp)
	}
	return protodesc.NewFiles(set)
}

// schema returns the reflected files of hello.Greeter and
// library.Library. Their message types are registered as dynamic types
// in protoregistry.GlobalTypes, which is what lets
// status.FromError(err).Details() decode a hello.HelloReply detail.
func schema(t *testing.T) *protoregistry.Files {
	t.Helper()
	s := srv(t)
	schemaOnce.Do(func() {
		schemaFiles, schemaErr = fetchFiles(t, s, "hello.Greeter", "library.Library")
		if schemaErr != nil {
			return
		}
		fd, err := schemaFiles.FindFileByPath("hello.proto")
		if err != nil {
			schemaErr = err
			return
		}
		msgs := fd.Messages()
		for i := 0; i < msgs.Len(); i++ {
			if _, err := protoregistry.GlobalTypes.FindMessageByName(msgs.Get(i).FullName()); err == nil {
				continue
			}
			schemaErr = protoregistry.GlobalTypes.RegisterMessage(dynamicpb.NewMessageType(msgs.Get(i)))
			if schemaErr != nil {
				return
			}
		}
	})
	require.NoError(t, schemaErr)
	return schemaFiles
}

func method(t *testing.T, name protoreflect.FullName) protoreflect.MethodDescriptor {
	t.Helper()
	d, err := schema(t).FindDescriptorByName(name)
	require.NoError(t, err, "%s", name)
	md, ok := d.(protoreflect.MethodDescriptor)
	require.True(t, ok, "%s is a %T", name, d)
	return md
}

// methodPath is the gRPC path of a method: /pkg.Service/Method.
func methodPath(md protoreflect.MethodDescriptor) string {
	return "/" + string(md.Parent().FullName()) + "/" + string(md.Name())
}

func newMsg(md protoreflect.MessageDescriptor, fields map[string]any) *dynamicpb.Message {
	m := dynamicpb.NewMessage(md)
	for name, v := range fields {
		m.Set(md.Fields().ByName(protoreflect.Name(name)), protoreflect.ValueOf(v))
	}
	return m
}

func str(m *dynamicpb.Message, field string) string {
	return m.Get(m.Descriptor().Fields().ByName(protoreflect.Name(field))).String()
}

func sayHello(t *testing.T, name string, opts ...grpc.CallOption) (*dynamicpb.Message, error) {
	t.Helper()
	return sayHelloCtx(t, ctxT(t, 10*time.Second), name, opts...)
}

func TestReflectionListServices(t *testing.T) {
	s := srv(t)
	want := []string{
		"grpc.health.v1.Health",
		"grpc.reflection.v1.ServerReflection",
		"grpc.reflection.v1alpha.ServerReflection",
		"hello.Greeter",
		"library.Library",
	}

	stream, err := reflectionpb.NewServerReflectionClient(s.conn).ServerReflectionInfo(ctxT(t, 10*time.Second))
	require.NoError(t, err)
	require.NoError(t, stream.Send(&reflectionpb.ServerReflectionRequest{
		MessageRequest: &reflectionpb.ServerReflectionRequest_ListServices{},
	}))
	resp, err := stream.Recv()
	require.NoError(t, err)
	var names []string
	for _, svc := range resp.GetListServicesResponse().GetService() {
		names = append(names, svc.GetName())
	}
	sort.Strings(names)
	assert.Equal(t, want, names)
	require.NoError(t, stream.CloseSend())
	_, err = stream.Recv()
	assert.ErrorIs(t, err, io.EOF, "the server ends the stream after the client half-closes")

	// Older clients speak only v1alpha.
	alpha, err := reflectionalphapb.NewServerReflectionClient(s.conn).ServerReflectionInfo(ctxT(t, 10*time.Second))
	require.NoError(t, err)
	require.NoError(t, alpha.Send(&reflectionalphapb.ServerReflectionRequest{
		MessageRequest: &reflectionalphapb.ServerReflectionRequest_ListServices{},
	}))
	aresp, err := alpha.Recv()
	require.NoError(t, err)
	assert.Len(t, aresp.GetListServicesResponse().GetService(), len(want))
	require.NoError(t, alpha.CloseSend())

	// The reflected Greeter has all four call kinds.
	kinds := map[string][2]bool{}
	svc := method(t, "hello.Greeter.SayHello").Parent().(protoreflect.ServiceDescriptor)
	for i := 0; i < svc.Methods().Len(); i++ {
		m := svc.Methods().Get(i)
		kinds[string(m.Name())] = [2]bool{m.IsStreamingClient(), m.IsStreamingServer()}
	}
	assert.Equal(t, map[string][2]bool{
		"SayHello":      {false, false},
		"Echo":          {false, false},
		"StreamHellos":  {false, true},
		"CollectHellos": {true, false},
		"Chat":          {true, true},
	}, kinds)
}

func TestUnary(t *testing.T) {
	resp, err := sayHello(t, "Alice")
	require.NoError(t, err)
	assert.Equal(t, "Hello, Alice", str(resp, "greeting"))
}

func TestServerStreaming(t *testing.T) {
	s := srv(t)
	md := method(t, "hello.Greeter.StreamHellos")
	stream, err := s.conn.NewStream(ctxT(t, 10*time.Second),
		&grpc.StreamDesc{ServerStreams: true}, methodPath(md))
	require.NoError(t, err)
	require.NoError(t, stream.SendMsg(newMsg(md.Input(), map[string]any{"name": "Bob"})))
	require.NoError(t, stream.CloseSend())
	var got []string
	for {
		m := dynamicpb.NewMessage(md.Output())
		err := stream.RecvMsg(m)
		if errors.Is(err, io.EOF) {
			break
		}
		require.NoError(t, err)
		got = append(got, str(m, "greeting"))
	}
	assert.Equal(t, []string{"Hello #1, Bob", "Hello #2, Bob", "Hello #3, Bob"}, got)
}

func TestClientStreaming(t *testing.T) {
	s := srv(t)
	md := method(t, "hello.Greeter.CollectHellos")
	stream, err := s.conn.NewStream(ctxT(t, 10*time.Second),
		&grpc.StreamDesc{ClientStreams: true}, methodPath(md))
	require.NoError(t, err)
	for _, name := range []string{"a", "b", "c"} {
		require.NoError(t, stream.SendMsg(newMsg(md.Input(), map[string]any{"name": name})))
	}
	// The handler reads until the half-close; only then does it answer.
	require.NoError(t, stream.CloseSend())
	resp := dynamicpb.NewMessage(md.Output())
	require.NoError(t, stream.RecvMsg(resp))
	assert.Equal(t, "Hello, a, b, c", str(resp, "greeting"))
	assert.ErrorIs(t, stream.RecvMsg(dynamicpb.NewMessage(md.Output())), io.EOF)

	// No messages at all: the handler's status reaches the client.
	stream, err = s.conn.NewStream(ctxT(t, 10*time.Second),
		&grpc.StreamDesc{ClientStreams: true}, methodPath(md))
	require.NoError(t, err)
	require.NoError(t, stream.CloseSend())
	err = stream.RecvMsg(dynamicpb.NewMessage(md.Output()))
	assert.Equal(t, codes.InvalidArgument, status.Code(err), "%v", err)
	assert.Equal(t, "no names", status.Convert(err).Message())
}

func TestBidi(t *testing.T) {
	s := srv(t)
	md := method(t, "hello.Greeter.Chat")
	stream, err := s.conn.NewStream(ctxT(t, 10*time.Second),
		&grpc.StreamDesc{ClientStreams: true, ServerStreams: true}, methodPath(md))
	require.NoError(t, err)
	// Ping-pong: each reply arrives before the next request is sent.
	for _, name := range []string{"one", "two", "three"} {
		require.NoError(t, stream.SendMsg(newMsg(md.Input(), map[string]any{"name": name})))
		m := dynamicpb.NewMessage(md.Output())
		require.NoError(t, stream.RecvMsg(m))
		assert.Equal(t, "Echo "+name, str(m, "greeting"))
	}
	require.NoError(t, stream.CloseSend())
	assert.ErrorIs(t, stream.RecvMsg(dynamicpb.NewMessage(md.Output())), io.EOF)

	// A status raised mid-stream ends the call with it, after the
	// replies already sent.
	stream, err = s.conn.NewStream(ctxT(t, 10*time.Second),
		&grpc.StreamDesc{ClientStreams: true, ServerStreams: true}, methodPath(md))
	require.NoError(t, err)
	require.NoError(t, stream.SendMsg(newMsg(md.Input(), map[string]any{"name": "x"})))
	m := dynamicpb.NewMessage(md.Output())
	require.NoError(t, stream.RecvMsg(m))
	assert.Equal(t, "Echo x", str(m, "greeting"))
	require.NoError(t, stream.SendMsg(newMsg(md.Input(), map[string]any{"name": "stop"})))
	err = stream.RecvMsg(dynamicpb.NewMessage(md.Output()))
	assert.Equal(t, codes.Aborted, status.Code(err), "%v", err)
	assert.Equal(t, "stopped by request", status.Convert(err).Message())
}

func TestStatusWithDetails(t *testing.T) {
	_, err := sayHello(t, "missing")
	require.Error(t, err)
	st, ok := status.FromError(err)
	require.True(t, ok, "%v", err)
	assert.Equal(t, codes.NotFound, st.Code())
	assert.Equal(t, "no such person: missing", st.Message())

	details := st.Details()
	require.Len(t, details, 1)
	detail, ok := details[0].(proto.Message)
	require.True(t, ok, "detail did not decode: %v", details[0])
	assert.Equal(t, protoreflect.FullName("hello.HelloReply"), detail.ProtoReflect().Descriptor().FullName())
	d := detail.ProtoReflect()
	assert.Equal(t, "try someone else", d.Get(d.Descriptor().Fields().ByName("greeting")).String())
}

func TestPlainErrorIsInternal(t *testing.T) {
	_, err := sayHello(t, "boom")
	st := status.Convert(err)
	assert.Equal(t, codes.Internal, st.Code(), "%v", err)
	assert.Equal(t, "internal error", st.Message())
	assert.NotContains(t, st.Message(), "secret")
	assert.Empty(t, st.Details())
}

func TestUnknownMethod(t *testing.T) {
	s := srv(t)
	md := method(t, "hello.Greeter.SayHello")
	err := s.conn.Invoke(ctxT(t, 10*time.Second), "/hello.Greeter/Nope",
		newMsg(md.Input(), nil), dynamicpb.NewMessage(md.Output()))
	assert.Equal(t, codes.Unimplemented, status.Code(err), "%v", err)
	err = s.conn.Invoke(ctxT(t, 10*time.Second), "/nope.Service/Call",
		newMsg(md.Input(), nil), dynamicpb.NewMessage(md.Output()))
	assert.Equal(t, codes.Unimplemented, status.Code(err), "%v", err)
}

func TestMetadata(t *testing.T) {
	var header, trailer metadata.MD
	ctx := metadata.AppendToOutgoingContext(ctxT(t, 10*time.Second), "x-request-id", "req-42")
	resp, err := sayHelloCtx(t, ctx, "Carol", grpc.Header(&header), grpc.Trailer(&trailer))
	require.NoError(t, err)
	assert.Equal(t, "Hello, Carol", str(resp, "greeting"))
	assert.Equal(t, []string{"req-42"}, header.Get("x-response-id"))
	assert.Equal(t, []string{"req-42"}, trailer.Get("x-trailer-id"))
}

func TestDeadline(t *testing.T) {
	ctx := ctxT(t, 300*time.Millisecond)
	start := time.Now()
	_, err := sayHelloCtx(t, ctx, "sleep:3")
	elapsed := time.Since(start)
	assert.Equal(t, codes.DeadlineExceeded, status.Code(err), "%v", err)
	assert.Less(t, elapsed, 2*time.Second)

	// grpc-go sends the deadline as grpc-timeout and times out on its
	// own as well, so either side may report it first. The server must
	// still serve the next call while the sleeping handler winds down.
	resp, err := sayHello(t, "after-deadline")
	require.NoError(t, err)
	assert.Equal(t, "Hello, after-deadline", str(resp, "greeting"))
}

func sayHelloCtx(t *testing.T, ctx context.Context, name string, opts ...grpc.CallOption) (*dynamicpb.Message, error) {
	t.Helper()
	s := srv(t)
	md := method(t, "hello.Greeter.SayHello")
	resp := dynamicpb.NewMessage(md.Output())
	err := s.conn.Invoke(ctx, methodPath(md), newMsg(md.Input(), map[string]any{"name": name}), resp, opts...)
	return resp, err
}

// The Echo method returns its request; a long name checks messages
// larger than one HTTP/2 frame survive both directions.
func TestLargeUnary(t *testing.T) {
	s := srv(t)
	md := method(t, "hello.Greeter.Echo")
	name := strings.Repeat("x", 100_000)
	resp := dynamicpb.NewMessage(md.Output())
	require.NoError(t, s.conn.Invoke(ctxT(t, 10*time.Second), methodPath(md),
		newMsg(md.Input(), map[string]any{"name": name}), resp))
	assert.Equal(t, name, str(resp, "name"))
}
