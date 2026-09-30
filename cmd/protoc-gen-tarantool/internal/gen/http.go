package gen

import (
	"strings"

	"google.golang.org/genproto/googleapis/api/annotations"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/descriptorpb"

	"github.com/tarantool-contrib/tarantool-protobuf/internal/luastr"
)

// httpBinding is one normalised google.api.http rule: an HTTP method, a
// path template, and the optional body / response_body selectors.
type httpBinding struct {
	Method       string
	Pattern      string
	Body         string
	ResponseBody string
}

// methodHTTPRules reads the google.api.http extension off a method's
// options and flattens it into bindings: the primary rule first, then
// its additional_bindings in declaration order. It returns nil when the
// method carries no annotation.
//
// The options are re-decoded through the global registry, where
// importing the annotations package registered the extension, so the
// rule is typed even if the options message was parsed before the
// extension was known.
func methodHTTPRules(opts *descriptorpb.MethodOptions) ([]httpBinding, error) {
	if opts == nil {
		return nil, nil
	}
	b, err := proto.Marshal(opts)
	if err != nil {
		return nil, err
	}
	fresh := &descriptorpb.MethodOptions{}
	if err := (proto.UnmarshalOptions{Resolver: protoregistry.GlobalTypes}).Unmarshal(b, fresh); err != nil {
		return nil, err
	}
	if !proto.HasExtension(fresh, annotations.E_Http) {
		return nil, nil
	}
	rule, _ := proto.GetExtension(fresh, annotations.E_Http).(*annotations.HttpRule)
	if rule == nil {
		return nil, nil
	}
	var out []httpBinding
	flattenHTTPRule(rule, &out)
	return out, nil
}

// flattenHTTPRule appends the rule, then (recursively) its additional
// bindings. http.proto forbids nested additional_bindings; recursing
// keeps the output total instead of silently dropping them. A rule with
// no pattern set (only additional_bindings) contributes nothing itself.
func flattenHTTPRule(rule *annotations.HttpRule, out *[]httpBinding) {
	method, pattern, ok := httpRulePattern(rule)
	if ok {
		*out = append(*out, httpBinding{
			Method:       method,
			Pattern:      pattern,
			Body:         rule.GetBody(),
			ResponseBody: rule.GetResponseBody(),
		})
	}
	for _, add := range rule.GetAdditionalBindings() {
		flattenHTTPRule(add, out)
	}
}

// httpRulePattern maps the rule's `pattern` oneof to (HTTP method, path).
// `custom {kind, path}` yields kind verbatim as the method.
func httpRulePattern(rule *annotations.HttpRule) (string, string, bool) {
	switch p := rule.GetPattern().(type) {
	case *annotations.HttpRule_Get:
		return "GET", p.Get, true
	case *annotations.HttpRule_Put:
		return "PUT", p.Put, true
	case *annotations.HttpRule_Post:
		return "POST", p.Post, true
	case *annotations.HttpRule_Delete:
		return "DELETE", p.Delete, true
	case *annotations.HttpRule_Patch:
		return "PATCH", p.Patch, true
	case *annotations.HttpRule_Custom:
		return p.Custom.GetKind(), p.Custom.GetPath(), true
	}
	return "", "", false
}

// luaHTTPBinding renders one binding as a Lua table constructor.
func luaHTTPBinding(b httpBinding) string {
	parts := []string{
		"method = " + luastr.Literal(b.Method),
		"pattern = " + luastr.Literal(b.Pattern),
	}
	if b.Body != "" {
		parts = append(parts, "body = "+luastr.Literal(b.Body))
	}
	if b.ResponseBody != "" {
		parts = append(parts, "response_body = "+luastr.Literal(b.ResponseBody))
	}
	return "{" + strings.Join(parts, ", ") + "}"
}
