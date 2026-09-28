// Payload builders that mirror bench/bench.lua so msg sizes and shapes
// match across runtimes. Same field set + field numbers as the Lua
// build_person_payload / build_proto2_payload helpers, so encoded byte
// lengths land within a byte or two for the same target size.
package bench

import (
	"fmt"
	"strings"

	hellopb "github.com/tarantool-protobuf/bench/go/pb/hellopb"
	proto2pb "github.com/tarantool-protobuf/bench/go/pb/proto2pb"
	"google.golang.org/protobuf/proto"
)

type SizeSpec struct {
	Label  string
	Target int
}

var PersonSizes = []SizeSpec{
	{"10B", 10},
	{"100B", 100},
	{"1KB", 1024},
	{"10KB", 10240},
	{"100KB", 102400},
}

var Proto2Sizes = []SizeSpec{
	{"min", 0},
	{"mid", 1024},
}

func BuildPerson(target int) *hellopb.Person {
	if target <= 10 {
		return &hellopb.Person{Name: "alicia", Age: 42}
	}
	if target <= 100 {
		return &hellopb.Person{
			Name: strings.Repeat("a", target-10),
			Age:  42,
		}
	}
	const perEmail = 36
	const fixedBytes = 80
	nEmails := (target - fixedBytes) / perEmail
	if nEmails < 1 {
		nEmails = 1
	}
	p := &hellopb.Person{
		Name: "alicia",
		Age:  42,
		Address: &hellopb.Address{
			Street: "1 Main St",
			City:   "Springfield",
			Zip:    12345,
		},
		LuckyNumbers: []int32{7, 13, 21, 42, 99},
		Emails:       make([]string, nEmails),
	}
	for i := 0; i < nEmails; i++ {
		p.Emails[i] = strings.Repeat("e", 28) + fmt.Sprintf("%04d", i+1)
	}
	return p
}

func BuildProto2(target int) *proto2pb.BenchPayload {
	if target <= 0 {
		id := int32(7)
		m := &proto2pb.BenchPayload{Id: &id}
		proto.SetExtension(m, proto2pb.E_ExtCount, int32(42))
		return m
	}
	const nTags = 16
	const perTag = 30
	tags := make([]string, nTags)
	for i := 0; i < nTags; i++ {
		tags[i] = strings.Repeat("t", perTag-2) + fmt.Sprintf("%02d", i+1)
	}
	lucky := make([]int32, 8)
	for i := 0; i < 8; i++ {
		lucky[i] = int32(1000 + i + 1)
	}
	id := int32(7)
	name := "bench"
	retries := int32(9)
	innerKey := strings.Repeat("k", 16)
	innerWeight := int32(3)
	latency := int32(1234567)
	attempts := int32(4)
	m := &proto2pb.BenchPayload{
		Id:           &id,
		Name:         &name,
		Retries:      &retries,
		LuckyNumbers: lucky,
		Tags:         tags,
		Inner: &proto2pb.BenchPayload_Inner{
			Key:    &innerKey,
			Weight: &innerWeight,
		},
		Stats: &proto2pb.BenchPayload_Stats{
			LatencyNs: &latency,
			Attempts:  &attempts,
		},
	}
	proto.SetExtension(m, proto2pb.E_ExtCount, int32(99))
	proto.SetExtension(m, proto2pb.E_ExtLabel, strings.Repeat("x", 32))
	return m
}
