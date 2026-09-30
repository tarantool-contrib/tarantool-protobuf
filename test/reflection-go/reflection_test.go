// Package reflectiongo checks pb.reflection against an independent
// consumer: dump.lua drives the Lua reflection service and writes the raw
// ServerReflectionResponse bytes; this test decodes them with grpc-go's
// generated reflection types and links every returned FileDescriptorProto
// with protodesc, the way a reflection client (grpcurl) does.
package reflectiongo

import (
	"bufio"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	reflectionpb "google.golang.org/grpc/reflection/grpc_reflection_v1"
	reflectionalphapb "google.golang.org/grpc/reflection/grpc_reflection_v1alpha"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/descriptorpb"
)

type entry struct {
	kind, subject, file string
}

type dump struct {
	dir     string
	entries []entry
}

// runDump runs dump.lua from the repository root into a fresh directory.
func runDump(t *testing.T) *dump {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", ".."))
	require.NoError(t, err)
	dir, err := os.MkdirTemp("", "pb-reflection-")
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	out := filepath.Join(dir, "out")

	cmd := exec.Command("tarantool", filepath.Join("test", "reflection-go", "dump.lua"), out)
	cmd.Dir = root
	cmd.Env = append(os.Environ(),
		"LUA_PATH=./runtime/?/init.lua;./runtime/?.lua;./examples/expected/?.lua;./examples/expected/?/init.lua;;")
	output, err := cmd.CombinedOutput()
	require.NoError(t, err, "dump.lua: %s", output)

	f, err := os.Open(filepath.Join(out, "manifest.tsv"))
	require.NoError(t, err)
	defer f.Close()
	d := &dump{dir: out}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		parts := strings.Split(sc.Text(), "\t")
		require.Len(t, parts, 3, "manifest line %q", sc.Text())
		d.entries = append(d.entries, entry{parts[0], parts[1], parts[2]})
	}
	require.NoError(t, sc.Err())
	require.NotEmpty(t, d.entries)
	return d
}

func (d *dump) of(kind string) []entry {
	var out []entry
	for _, e := range d.entries {
		if e.kind == kind {
			out = append(out, e)
		}
	}
	return out
}

func (d *dump) v1(t *testing.T, e entry) *reflectionpb.ServerReflectionResponse {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(d.dir, e.file))
	require.NoError(t, err)
	var resp reflectionpb.ServerReflectionResponse
	require.NoError(t, proto.Unmarshal(b, &resp), "%s %s", e.kind, e.subject)
	return &resp
}

func (d *dump) v1alpha(t *testing.T, e entry) *reflectionalphapb.ServerReflectionResponse {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(d.dir, e.file))
	require.NoError(t, err)
	var resp reflectionalphapb.ServerReflectionResponse
	require.NoError(t, proto.Unmarshal(b, &resp), "%s %s", e.kind, e.subject)
	return &resp
}

// link decodes raw FileDescriptorProtos and builds them into a registry.
func link(t *testing.T, raw [][]byte) (*protoregistry.Files, []*descriptorpb.FileDescriptorProto) {
	t.Helper()
	set := &descriptorpb.FileDescriptorSet{}
	for _, b := range raw {
		fdp := &descriptorpb.FileDescriptorProto{}
		require.NoError(t, proto.Unmarshal(b, fdp))
		set.File = append(set.File, fdp)
	}
	files, err := protodesc.NewFiles(set)
	require.NoError(t, err)
	return files, set.File
}

// Services the example modules, health and reflection expose, with
// their methods and streaming shape (client, server).
var wantServices = map[string]map[string][2]bool{
	"grpc.health.v1.Health": {
		"Check": {false, false}, "List": {false, false}, "Watch": {false, true},
	},
	"grpc.reflection.v1.ServerReflection": {
		"ServerReflectionInfo": {true, true},
	},
	"grpc.reflection.v1alpha.ServerReflection": {
		"ServerReflectionInfo": {true, true},
	},
	"hello.Greeter": {
		"SayHello": {false, false}, "Echo": {false, false},
		"StreamHellos": {false, true}, "CollectHellos": {true, false}, "Chat": {true, true},
	},
	"library.Library": {
		"GetBook": {false, false}, "ListBooks": {false, false}, "CreateBook": {false, false},
		"UpdateBook": {false, false}, "DeleteBook": {false, false}, "LookupBook": {false, false},
		"MoveBook": {false, false}, "GetMessage": {false, false}, "GetFile": {false, false},
		"CheckBook": {false, false}, "WatchShelf": {false, true},
	},
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func TestReflection(t *testing.T) {
	require.True(t, protoLegacy,
		"run with -tags protolegacy (just test-reflection-go): the conformance "+
			"fixtures declare a MessageSet, which protodesc refuses otherwise")
	d := runDump(t)

	t.Run("list_services", func(t *testing.T) {
		lists := d.of("list_services")
		require.Len(t, lists, 1)
		resp := d.v1(t, lists[0])
		assert.Equal(t, "*", resp.GetOriginalRequest().GetListServices())
		var got []string
		for _, s := range resp.GetListServicesResponse().GetService() {
			got = append(got, s.GetName())
		}
		assert.Equal(t, sortedKeys(wantServices), got)

		alpha := d.of("v1alpha_list_services")
		require.Len(t, alpha, 1)
		var gotAlpha []string
		for _, s := range d.v1alpha(t, alpha[0]).GetListServicesResponse().GetService() {
			gotAlpha = append(gotAlpha, s.GetName())
		}
		assert.Equal(t, got, gotAlpha)
	})

	t.Run("every file links", func(t *testing.T) {
		entries := d.of("file")
		// Examples, conformance and proto2 fixtures, built-ins, health
		// and reflection.
		require.GreaterOrEqual(t, len(entries), 30)
		seen := map[string]bool{}
		for _, e := range entries {
			resp := d.v1(t, e)
			require.Nil(t, resp.GetErrorResponse(), e.subject)
			assert.Equal(t, e.subject, resp.GetOriginalRequest().GetFileByFilename())
			raw := resp.GetFileDescriptorResponse().GetFileDescriptorProto()
			require.NotEmpty(t, raw, e.subject)
			files, fdps := link(t, raw)
			assert.Equal(t, e.subject, fdps[0].GetName(), "requested file comes first")
			fd, err := files.FindFileByPath(e.subject)
			require.NoError(t, err, e.subject)
			// The closure is exactly what the file imports, transitively.
			assert.Equal(t, closure(fd), names(fdps), e.subject)
			seen[e.subject] = true
		}
		for _, f := range []string{
			"hello.proto", "kv.proto", "library.proto", "quickstart.proto",
			"google/api/annotations.proto", "google/protobuf/descriptor.proto",
			"grpc/health/v1/health.proto", "grpc/reflection/v1/reflection.proto",
			"grpc/reflection/v1alpha/reflection.proto",
		} {
			assert.True(t, seen[f], "no reflection answer for %s", f)
		}

		alpha := d.of("v1alpha_file")
		require.Len(t, alpha, 1)
		resp := d.v1alpha(t, alpha[0])
		_, fdps := link(t, resp.GetFileDescriptorResponse().GetFileDescriptorProto())
		assert.Equal(t, "hello.proto", fdps[0].GetName())
	})

	t.Run("services and methods by symbol", func(t *testing.T) {
		found := map[string]bool{}
		for _, e := range d.of("symbol") {
			resp := d.v1(t, e)
			require.Nil(t, resp.GetErrorResponse(), e.subject)
			files, _ := link(t, resp.GetFileDescriptorResponse().GetFileDescriptorProto())
			desc, err := files.FindDescriptorByName(protoreflect.FullName(e.subject))
			require.NoError(t, err, e.subject)
			switch desc := desc.(type) {
			case protoreflect.ServiceDescriptor:
				want, ok := wantServices[e.subject]
				require.True(t, ok, "unexpected service %s", e.subject)
				methods := desc.Methods()
				require.Equal(t, len(want), methods.Len(), e.subject)
				for name, shape := range want {
					m := methods.ByName(protoreflect.Name(name))
					require.NotNil(t, m, "%s.%s", e.subject, name)
					assert.Equal(t, shape[0], m.IsStreamingClient(), "%s.%s", e.subject, name)
					assert.Equal(t, shape[1], m.IsStreamingServer(), "%s.%s", e.subject, name)
				}
			case protoreflect.MethodDescriptor:
				_, ok := wantServices[string(desc.Parent().FullName())][string(desc.Name())]
				assert.True(t, ok, "unexpected method %s", e.subject)
			default:
				t.Fatalf("%s resolved to %T", e.subject, desc)
			}
			found[e.subject] = true
		}
		for svc, methods := range wantServices {
			assert.True(t, found[svc], "service %s not asked", svc)
			for m := range methods {
				assert.True(t, found[svc+"."+m], "method %s.%s not asked", svc, m)
			}
		}
	})

	t.Run("per-stream dedup", func(t *testing.T) {
		entries := d.of("dedup")
		require.Len(t, entries, 4)
		var all [][]byte
		count := map[string]int{}
		for _, e := range entries {
			resp := d.v1(t, e)
			raw := resp.GetFileDescriptorResponse().GetFileDescriptorProto()
			require.NotEmpty(t, raw, e.subject)
			for _, b := range raw {
				fdp := &descriptorpb.FileDescriptorProto{}
				require.NoError(t, proto.Unmarshal(b, fdp))
				count[fdp.GetName()]++
			}
			all = append(all, raw...)
		}
		for name, n := range count {
			assert.Equal(t, 1, n, "%s sent %d times on one stream", name, n)
		}
		// What the stream sent altogether still links.
		files, _ := link(t, all)
		for _, e := range entries {
			_, err := files.FindFileByPath(e.subject)
			assert.NoError(t, err, e.subject)
		}
	})

	// The descriptors served for health and reflection are the ones
	// grpc-go compiles from the same upstream files.
	t.Run("same descriptors as grpc-go", func(t *testing.T) {
		for _, want := range []protoreflect.FileDescriptor{
			healthpb.File_grpc_health_v1_health_proto,
			reflectionpb.File_grpc_reflection_v1_reflection_proto,
			reflectionalphapb.File_grpc_reflection_v1alpha_reflection_proto,
		} {
			var got *descriptorpb.FileDescriptorProto
			for _, e := range d.of("file") {
				if e.subject == want.Path() {
					raw := d.v1(t, e).GetFileDescriptorResponse().GetFileDescriptorProto()
					got = &descriptorpb.FileDescriptorProto{}
					require.NoError(t, proto.Unmarshal(raw[0], got))
				}
			}
			require.NotNil(t, got, want.Path())
			assert.True(t, proto.Equal(protodesc.ToFileDescriptorProto(want), got),
				"%s differs from grpc-go's", want.Path())
		}
	})
}

// closure returns fd and its transitive imports, sorted.
func closure(fd protoreflect.FileDescriptor) []string {
	seen := map[string]bool{}
	var visit func(protoreflect.FileDescriptor)
	visit = func(f protoreflect.FileDescriptor) {
		if seen[f.Path()] {
			return
		}
		seen[f.Path()] = true
		for i := 0; i < f.Imports().Len(); i++ {
			visit(f.Imports().Get(i).FileDescriptor)
		}
	}
	visit(fd)
	return sortedKeys(seen)
}

func names(fdps []*descriptorpb.FileDescriptorProto) []string {
	out := make([]string, 0, len(fdps))
	for _, f := range fdps {
		out = append(out, f.GetName())
	}
	sort.Strings(out)
	return out
}
