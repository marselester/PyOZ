//! Comptime Source Parser for PyOZ
//!
//! Parses Zig source files at comptime using `std.zig.Tokenizer` to extract:
//! - Function parameter names (replacing arg0/arg1 fallback)
//! - `///` doc comments for declarations
//! - `//!` module-level doc comments
//! - Method parameter names and doc comments inside structs
//!
//! This only applies to `.from` namespaces with source text provided via:
//!   pyoz.withSource(@import("file.zig"), @embedFile("file.zig"))  // recommended
//! or the legacy per-file `__source__` declaration.
//!
//! All string results are built via `++` concatenation at comptime,
//! ensuring the source text is NOT embedded in the final binary.

const std = @import("std");

/// Parsed declaration info collected in a single tokenization pass.
const DeclInfo = struct {
    name: []const u8,
    doc: ?[]const u8,
    params: ?[]const u8,
    scope: ?[]const u8, // null for top-level, struct name for methods
};

/// Create a comptime source info type from an embedded source string.
/// Provides lookup functions for parameter names, doc comments, and module docs.
/// All declarations are parsed in a single tokenization pass for performance.
pub fn SourceInfo(comptime source: [:0]const u8) type {
    // Single-pass parse — computed once per unique source string
    const all_decls = comptime parseAllDecls(source);

    return struct {
        /// File-level doc comment (//! lines at top of file).
        pub const module_doc: ?[]const u8 = parseModuleDoc(source);

        /// Look up function parameter names: "add" -> "a, b"
        pub fn getParamNames(comptime func_name: []const u8) ?[]const u8 {
            return lookupParams(all_decls, func_name, null);
        }

        /// Look up doc comment for a top-level declaration: "add" -> "Add two integers together."
        pub fn getDoc(comptime name: []const u8) ?[]const u8 {
            return lookupDoc(all_decls, name, null);
        }

        /// Look up doc comment for a method inside a struct: "Vec2", "magnitude" -> "Compute the magnitude."
        pub fn getMethodDoc(comptime struct_name: []const u8, comptime method_name: []const u8) ?[]const u8 {
            return lookupDoc(all_decls, method_name, struct_name);
        }

        /// Look up method parameter names: "Vec2", "dot" -> "other" (self is skipped)
        pub fn getMethodParams(comptime struct_name: []const u8, comptime method_name: []const u8) ?[]const u8 {
            return lookupParams(all_decls, method_name, struct_name);
        }
    };
}

// =============================================================================
// Token Helpers
// =============================================================================

const Token = std.zig.Token;
const Tokenizer = std.zig.Tokenizer;

/// Extract the text of a token from the source buffer.
fn tokenSlice(source: [:0]const u8, tok: Token) []const u8 {
    return source[tok.loc.start..tok.loc.end];
}

// =============================================================================
// Module Doc Parser (//! comments)
// =============================================================================

/// Parse `//!` container doc comments at the top of the file.
fn parseModuleDoc(comptime source: [:0]const u8) ?[]const u8 {
    @setEvalBranchQuota(std.math.maxInt(u32));
    comptime {
        var tokenizer = Tokenizer.init(source);
        var result: []const u8 = "";
        var has_any = false;

        while (true) {
            const tok = tokenizer.next();
            if (tok.tag == .container_doc_comment) {
                const line = source[tok.loc.start..tok.loc.end];
                // Strip "//! " or "//!" prefix
                const stripped = stripDocPrefix(line, "//!");
                if (has_any) {
                    result = result ++ "\n";
                }
                result = result ++ stripped;
                has_any = true;
            } else if (tok.tag == .doc_comment) {
                // Doc comments (///) can appear after container doc comments
                // but are not part of the module doc — stop here
                break;
            } else if (tok.tag == .eof) {
                break;
            } else {
                // Any non-comment token after the doc comments means we're done
                // But we should continue past whitespace-only gaps
                // Actually, the tokenizer skips whitespace, so any non-comment token means stop
                break;
            }
        }

        if (has_any) return result;
        return null;
    }
}

// =============================================================================
// Single-Pass Declaration Parser
// =============================================================================

/// Parse all declarations from source in a single tokenization pass.
/// Collects doc comments, parameter names, and struct scope for each pub decl.
/// Handles `pub fn`, `pub inline fn`, `pub const`, and methods inside structs.
fn parseAllDecls(comptime source: [:0]const u8) []const DeclInfo {
    @setEvalBranchQuota(std.math.maxInt(u32));
    comptime {
        var tokenizer = Tokenizer.init(source);
        var decls: [4096]DeclInfo = undefined;
        var count: usize = 0;

        var doc_accum: []const u8 = "";
        var has_doc = false;
        var brace_depth: usize = 0;

        // Struct scope tracking
        var scope_name: ?[]const u8 = null;
        var scope_depth: usize = 0;

        while (true) {
            const tok = tokenizer.next();
            if (tok.tag == .eof) break;

            // Track braces
            if (tok.tag == .l_brace) {
                brace_depth += 1;
                if (has_doc) {
                    doc_accum = "";
                    has_doc = false;
                }
                continue;
            }
            if (tok.tag == .r_brace) {
                if (brace_depth > 0) brace_depth -= 1;
                // Left the struct scope?
                if (scope_name != null and brace_depth < scope_depth) {
                    scope_name = null;
                }
                continue;
            }

            // Accumulate doc comments
            if (tok.tag == .doc_comment) {
                const line = source[tok.loc.start..tok.loc.end];
                const stripped = stripDocPrefix(line, "///");
                if (has_doc) {
                    doc_accum = doc_accum ++ "\n" ++ stripped;
                } else {
                    doc_accum = stripped;
                    has_doc = true;
                }
                continue;
            }

            // Check for pub declarations
            if (tok.tag == .keyword_pub) {
                var next_tok = tokenizer.next();

                // Skip inline/noinline/export keywords between pub and fn/const
                while (next_tok.tag == .keyword_inline or
                    next_tok.tag == .keyword_noinline or
                    next_tok.tag == .keyword_export)
                {
                    next_tok = tokenizer.next();
                }

                if (next_tok.tag == .keyword_fn) {
                    const ident = tokenizer.next();
                    if (ident.tag == .identifier) {
                        const name = tokenSlice(source, ident);
                        const lparen = tokenizer.next();
                        var params: ?[]const u8 = null;
                        if (lparen.tag == .l_paren) {
                            params = extractParamNames(&tokenizer, source, scope_name != null);
                        }
                        decls[count] = .{
                            .name = name,
                            .doc = if (has_doc) doc_accum else null,
                            .params = params,
                            .scope = scope_name,
                        };
                        count += 1;
                    }
                } else if (next_tok.tag == .keyword_const) {
                    const ident = tokenizer.next();
                    if (ident.tag == .identifier) {
                        const name = tokenSlice(source, ident);
                        // Check for `= struct {` pattern
                        const eq = tokenizer.next();
                        if (eq.tag == .equal) {
                            const after_eq = tokenizer.next();
                            if (after_eq.tag == .keyword_struct) {
                                const lbrace = tokenizer.next();
                                if (lbrace.tag == .l_brace) {
                                    // Record the struct const with its doc
                                    decls[count] = .{
                                        .name = name,
                                        .doc = if (has_doc) doc_accum else null,
                                        .params = null,
                                        .scope = scope_name,
                                    };
                                    count += 1;
                                    // Enter struct scope
                                    brace_depth += 1;
                                    scope_name = name;
                                    scope_depth = brace_depth;
                                }
                            } else {
                                // Regular `pub const name = <expr>` (not a struct)
                                decls[count] = .{
                                    .name = name,
                                    .doc = if (has_doc) doc_accum else null,
                                    .params = null,
                                    .scope = scope_name,
                                };
                                count += 1;
                            }
                        } else {
                            // `pub const name: type` or similar
                            decls[count] = .{
                                .name = name,
                                .doc = if (has_doc) doc_accum else null,
                                .params = null,
                                .scope = scope_name,
                            };
                            count += 1;
                        }
                    }
                }

                doc_accum = "";
                has_doc = false;
                continue;
            }

            // Any other token resets doc accumulator
            if (has_doc) {
                doc_accum = "";
                has_doc = false;
            }
        }

        const final = decls[0..count].*;
        return &final;
    }
}

/// Look up a doc comment from the cached declarations.
fn lookupDoc(comptime all: []const DeclInfo, comptime name: []const u8, comptime scope: ?[]const u8) ?[]const u8 {
    for (all) |d| {
        if (!std.mem.eql(u8, d.name, name)) continue;
        if (scope == null and d.scope == null) return d.doc;
        if (scope != null and d.scope != null and std.mem.eql(u8, scope.?, d.scope.?)) return d.doc;
    }
    return null;
}

/// Look up parameter names from the cached declarations.
fn lookupParams(comptime all: []const DeclInfo, comptime name: []const u8, comptime scope: ?[]const u8) ?[]const u8 {
    for (all) |d| {
        if (!std.mem.eql(u8, d.name, name)) continue;
        if (scope == null and d.scope == null) return d.params;
        if (scope != null and d.scope != null and std.mem.eql(u8, scope.?, d.scope.?)) return d.params;
    }
    return null;
}

/// Extract parameter names from inside a function's parameter list.
/// The tokenizer should be positioned right after the opening `(`.
/// For methods (is_method=true), the first parameter (self) is skipped.
fn extractParamNames(tokenizer: *Tokenizer, source: [:0]const u8, comptime is_method: bool) ?[]const u8 {
    @setEvalBranchQuota(std.math.maxInt(u32));
    comptime {
        var result: []const u8 = "";
        var param_count: usize = 0;
        var depth: usize = 1; // Already inside the opening paren
        var expecting_name = true;

        while (true) {
            const tok = tokenizer.next();
            if (tok.tag == .eof) break;

            if (tok.tag == .l_paren or tok.tag == .l_brace or tok.tag == .l_bracket) {
                depth += 1;
                expecting_name = false;
                continue;
            }

            if (tok.tag == .r_paren or tok.tag == .r_brace or tok.tag == .r_bracket) {
                depth -= 1;
                if (depth == 0) break; // End of parameter list
                continue;
            }

            // Only process tokens at the parameter list level (depth == 1)
            if (depth != 1) continue;

            if (tok.tag == .comma) {
                expecting_name = true;
                continue;
            }

            if (tok.tag == .colon) {
                // After the colon comes the type — stop expecting name
                expecting_name = false;
                continue;
            }

            if (tok.tag == .identifier and expecting_name) {
                // Peek at the next token — if it's a colon, this is a param name
                const peek = tokenizer.next();
                if (peek.tag == .colon) {
                    const pname = tokenSlice(source, tok);

                    // Skip self parameter for methods
                    if (is_method and param_count == 0 and std.mem.eql(u8, pname, "self")) {
                        expecting_name = false;
                        continue;
                    }

                    // Skip comptime parameters (the preceding token was keyword_comptime)
                    // We handle this by checking if the name is a type keyword — not needed
                    // since we just collect the identifier before ':'

                    if (param_count > 0) {
                        result = result ++ ", ";
                    }
                    result = result ++ pname;
                    param_count += 1;
                    expecting_name = false;
                } else {
                    // Not a param name (e.g., part of a type expression)
                    // The peek token is something else, continue processing
                    if (peek.tag == .r_paren) {
                        depth -= 1;
                        if (depth == 0) break;
                    } else if (peek.tag == .l_paren or peek.tag == .l_brace or peek.tag == .l_bracket) {
                        depth += 1;
                        expecting_name = false;
                    } else if (peek.tag == .comma) {
                        expecting_name = true;
                    }
                }
                continue;
            }

            // keyword_comptime before a parameter name — mark next ident as comptime param
            // We skip comptime params by checking: if the token is keyword_comptime, the
            // next identifier + colon is a comptime param, which we should still include
            // (e.g., `comptime n: usize` → "n")
            if (tok.tag == .keyword_comptime) {
                expecting_name = true;
                continue;
            }
        }

        if (param_count > 0) return result;
        return null;
    }
}

// =============================================================================
// Helpers
// =============================================================================

/// Strip a doc comment prefix ("///" or "//!") and optional leading space.
fn stripDocPrefix(comptime line: []const u8, comptime prefix: []const u8) []const u8 {
    comptime {
        if (line.len >= prefix.len and std.mem.startsWith(u8, line, prefix)) {
            const after_prefix = line[prefix.len..];
            // Strip one leading space if present
            if (after_prefix.len > 0 and after_prefix[0] == ' ') {
                return after_prefix[1..];
            }
            return after_prefix;
        }
        return line;
    }
}
