// Package messageset lets the protoc plugins accept MessageSet
// declarations, which protobuf-go refuses to load.
package messageset

import (
	"google.golang.org/protobuf/types/descriptorpb"
	"google.golang.org/protobuf/types/pluginpb"
)

// maxFieldNumber is the largest field number the protobuf spec allows
// outside MessageSet.
const maxFieldNumber = 1<<29 - 1

// Set holds the full names of messages declared with
// `option message_set_wire_format = true`.
type Set map[string]bool

// Strip removes the MessageSet option from every message in the request
// and returns the names of the messages that carried it.
//
// protobuf-go refuses to build a descriptor for a MessageSet ("a legacy
// proto1 feature that is no longer supported") unless the binary is built
// with the protolegacy tag, and that refusal fails protogen for the whole
// file. Stripping the option lets the file load as an ordinary proto2
// file with extensions; the returned set is how a generator still knows
// which messages use the MessageSet wire format. A MessageSet's
// `extensions 4 to max` ends at 2^31-1, past the field-number limit of an
// ordinary message, so extension ranges are clamped to it as well.
func Strip(req *pluginpb.CodeGeneratorRequest) Set {
	sets := Set{}
	for _, f := range req.ProtoFile {
		prefix := f.GetPackage()
		if prefix != "" {
			prefix += "."
		}
		for _, m := range f.MessageType {
			strip(sets, prefix, m)
		}
	}
	return sets
}

func strip(sets Set, prefix string, m *descriptorpb.DescriptorProto) {
	full := prefix + m.GetName()
	if m.Options.GetMessageSetWireFormat() {
		sets[full] = true
		m.Options.MessageSetWireFormat = nil
		for _, r := range m.ExtensionRange {
			// End is exclusive.
			if r.GetEnd() > maxFieldNumber+1 {
				end := int32(maxFieldNumber + 1)
				r.End = &end
			}
		}
	}
	for _, nested := range m.NestedType {
		strip(sets, full+".", nested)
	}
}
