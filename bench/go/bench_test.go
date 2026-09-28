// Standard `go test -bench=.` benchmarks. Mirrors bench/bench.lua: per
// fixture × per size, encode + decode, throughput + alloc.
//
// Two implementations per case:
//   * apiv2:   google.golang.org/protobuf reflective Marshal/Unmarshal
//              — the default everyone gets out of the box.
//   * vtproto: planetscale/vtprotobuf generated MarshalVT/UnmarshalVT
//              — the fastest pure-Go path, conceptually equivalent to
//              our `mode=full` codegen.
//
// Runs are single-threaded by default (testing.B doesn't parallelize
// unless RunParallel is called).
package bench

import (
	"fmt"
	"testing"

	"google.golang.org/protobuf/proto"

	hellopb "github.com/tarantool-protobuf/bench/go/pb/hellopb"
	proto2pb "github.com/tarantool-protobuf/bench/go/pb/proto2pb"
)

// --- hello.Person ---------------------------------------------------------

func BenchmarkPersonEncode(b *testing.B) {
	for _, sz := range PersonSizes {
		msg := BuildPerson(sz.Target)
		wire, err := proto.Marshal(msg)
		if err != nil {
			b.Fatal(err)
		}

		b.Run(fmt.Sprintf("apiv2/%s", sz.Label), func(b *testing.B) {
			b.SetBytes(int64(len(wire)))
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				if _, err := proto.Marshal(msg); err != nil {
					b.Fatal(err)
				}
			}
		})

		b.Run(fmt.Sprintf("vtproto/%s", sz.Label), func(b *testing.B) {
			b.SetBytes(int64(len(wire)))
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				if _, err := msg.MarshalVT(); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

func BenchmarkPersonDecode(b *testing.B) {
	for _, sz := range PersonSizes {
		msg := BuildPerson(sz.Target)
		wire, err := proto.Marshal(msg)
		if err != nil {
			b.Fatal(err)
		}

		b.Run(fmt.Sprintf("apiv2/%s", sz.Label), func(b *testing.B) {
			b.SetBytes(int64(len(wire)))
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				var out hellopb.Person
				if err := proto.Unmarshal(wire, &out); err != nil {
					b.Fatal(err)
				}
			}
		})

		b.Run(fmt.Sprintf("vtproto/%s", sz.Label), func(b *testing.B) {
			b.SetBytes(int64(len(wire)))
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				var out hellopb.Person
				if err := out.UnmarshalVT(wire); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

// --- proto2_basic.BenchPayload --------------------------------------------

func BenchmarkProto2Encode(b *testing.B) {
	for _, sz := range Proto2Sizes {
		msg := BuildProto2(sz.Target)
		wire, err := proto.Marshal(msg)
		if err != nil {
			b.Fatal(err)
		}

		b.Run(fmt.Sprintf("apiv2/%s", sz.Label), func(b *testing.B) {
			b.SetBytes(int64(len(wire)))
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				if _, err := proto.Marshal(msg); err != nil {
					b.Fatal(err)
				}
			}
		})

		// vtproto's generated MarshalVT does not serialize extensions —
		// it skips XXX_unrecognized + protoimpl.ExtensionFields and so
		// drops the ext_count/ext_label payload. The benchmark would
		// produce shorter bytes than apiv2; skip the vtproto variant
		// when the fixture carries extensions so we don't publish
		// misleading throughput numbers.
		_ = msg.MarshalVT // keep symbol referenced; intentionally not benched
	}
}

func BenchmarkProto2Decode(b *testing.B) {
	for _, sz := range Proto2Sizes {
		msg := BuildProto2(sz.Target)
		wire, err := proto.Marshal(msg)
		if err != nil {
			b.Fatal(err)
		}

		b.Run(fmt.Sprintf("apiv2/%s", sz.Label), func(b *testing.B) {
			b.SetBytes(int64(len(wire)))
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				var out proto2pb.BenchPayload
				if err := proto.Unmarshal(wire, &out); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
