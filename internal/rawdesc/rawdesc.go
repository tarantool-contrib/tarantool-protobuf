// Package rawdesc reads serialized FileDescriptorProto messages straight
// off the wire of their container (a CodeGeneratorRequest or a
// FileDescriptorSet), so the bytes that end up embedded are exactly the
// ones protoc produced — no unmarshal/re-marshal round trip whose field
// order could differ from protoc's.
package rawdesc

import (
	"fmt"

	"google.golang.org/protobuf/encoding/protowire"
)

// Field numbers used below (descriptor.proto, plugin.proto).
const (
	fileDescriptorSetFile    = 1  // FileDescriptorSet.file
	codeGeneratorProtoFile   = 15 // CodeGeneratorRequest.proto_file
	fileDescriptorName       = 1  // FileDescriptorProto.name
	fileDescriptorSourceCode = 9  // FileDescriptorProto.source_code_info
)

// File is one FileDescriptorProto as found on the wire, with
// source_code_info removed.
type File struct {
	Name  string
	Bytes []byte
}

// FromRequest returns every CodeGeneratorRequest.proto_file entry.
func FromRequest(req []byte) ([]File, error) {
	return files(req, codeGeneratorProtoFile)
}

// FromSet returns every FileDescriptorSet.file entry.
func FromSet(set []byte) ([]File, error) {
	return files(set, fileDescriptorSetFile)
}

func files(b []byte, field protowire.Number) ([]File, error) {
	var out []File
	for len(b) > 0 {
		num, typ, n := protowire.ConsumeTag(b)
		if n < 0 {
			return nil, protowire.ParseError(n)
		}
		b = b[n:]
		if num == field && typ == protowire.BytesType {
			v, m := protowire.ConsumeBytes(b)
			if m < 0 {
				return nil, protowire.ParseError(m)
			}
			f, err := parseFile(v)
			if err != nil {
				return nil, err
			}
			out = append(out, f)
			b = b[m:]
			continue
		}
		m := protowire.ConsumeFieldValue(num, typ, b)
		if m < 0 {
			return nil, protowire.ParseError(m)
		}
		b = b[m:]
	}
	return out, nil
}

// parseFile copies a FileDescriptorProto's fields in wire order, minus
// source_code_info, and picks up its name.
func parseFile(b []byte) (File, error) {
	var f File
	out := make([]byte, 0, len(b))
	for len(b) > 0 {
		num, typ, n := protowire.ConsumeTag(b)
		if n < 0 {
			return File{}, protowire.ParseError(n)
		}
		m := protowire.ConsumeFieldValue(num, typ, b[n:])
		if m < 0 {
			return File{}, protowire.ParseError(m)
		}
		field := b[:n+m]
		if num == fileDescriptorName && typ == protowire.BytesType {
			v, _ := protowire.ConsumeBytes(b[n:])
			f.Name = string(v)
		}
		if num != fileDescriptorSourceCode {
			out = append(out, field...)
		}
		b = b[n+m:]
	}
	if f.Name == "" {
		return File{}, fmt.Errorf("FileDescriptorProto without a name")
	}
	f.Bytes = out
	return f, nil
}
