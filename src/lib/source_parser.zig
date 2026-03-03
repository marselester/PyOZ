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

/// Create a comptime source info type from an embedded source string.
/// Provides lookup functions for parameter names, doc comments, and module docs.
pub fn SourceInfo(comptime source: [:0]const u8) type {
    return struct {
        /// File-level doc comment (//! lines at top of file).
        pub const module_doc: ?[]const u8 = parseModuleDoc(source);

        /// Look up function parameter names: "add" -> "a, b"
        pub fn getParamNames(comptime func_name: []const u8) ?[]const u8 {
            return parseFuncParams(source, func_name, null);
        }

        /// Look up doc comment for a top-level declaration: "add" -> "Add two integers together."
        pub fn getDoc(comptime name: []const u8) ?[]const u8 {
            return parseDeclDoc(source, name, null);
        }

        /// Look up doc comment for a method inside a struct: "Vec2", "magnitude" -> "Compute the magnitude."
        pub fn getMethodDoc(comptime struct_name: []const u8, comptime method_name: []const u8) ?[]const u8 {
            return parseDeclDoc(source, method_name, struct_name);
        }

        /// Look up method parameter names: "Vec2", "dot" -> "other" (self is skipped)
        pub fn getMethodParams(comptime struct_name: []const u8, comptime method_name: []const u8) ?[]const u8 {
            return parseFuncParams(source, method_name, struct_name);
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

/// Advance tokenizer and return the next token.
fn nextToken(tok: *Tokenizer) Token {
    return tok.next();
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
// Declaration Doc Parser (/// comments)
// =============================================================================

/// Parse `///` doc comment for a declaration (function or const).
/// If `struct_scope` is non-null, look inside that struct for the declaration.
fn parseDeclDoc(comptime source: [:0]const u8, comptime name: []const u8, comptime struct_scope: ?[]const u8) ?[]const u8 {
    @setEvalBranchQuota(std.math.maxInt(u32));
    comptime {
        var tokenizer = Tokenizer.init(source);

        // If we need to find inside a struct, first navigate to the struct scope
        if (struct_scope) |sname| {
            if (!enterStructScope(&tokenizer, source, sname)) return null;
        }

        // Now scan for doc comments followed by the target declaration
        var doc_accum: []const u8 = "";
        var has_doc = false;
        const brace_limit: ?usize = if (struct_scope != null) 1 else null;
        var brace_depth: usize = if (struct_scope != null) 1 else 0;

        while (true) {
            const tok = tokenizer.next();

            if (tok.tag == .eof) break;

            // Track brace depth when inside a struct scope
            if (tok.tag == .l_brace) {
                brace_depth += 1;
                continue;
            }
            if (tok.tag == .r_brace) {
                if (brace_depth == 0) break;
                brace_depth -= 1;
                if (brace_limit) |bl| {
                    if (brace_depth < bl) break; // Left the struct scope
                }
                continue;
            }

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

            // Check if this is `pub fn <name>` or `pub const <name>`
            if (tok.tag == .keyword_pub and has_doc) {
                const next_tok = tokenizer.next();
                if (next_tok.tag == .keyword_fn or next_tok.tag == .keyword_const) {
                    const ident = tokenizer.next();
                    if (ident.tag == .identifier) {
                        const ident_name = tokenSlice(source, ident);
                        if (std.mem.eql(u8, ident_name, name)) {
                            return doc_accum;
                        }
                    }
                }
                // Not our target — reset doc accumulator
                doc_accum = "";
                has_doc = false;
                continue;
            }

            // Any non-doc-comment, non-pub token resets the accumulator
            if (has_doc) {
                doc_accum = "";
                has_doc = false;
            }
        }

        return null;
    }
}

// =============================================================================
// Function Parameter Parser
// =============================================================================

/// Parse parameter names from a function signature.
/// If `struct_scope` is non-null, look inside that struct.
/// Returns comma-separated names, e.g., "a, b, c".
/// For methods, the self parameter is automatically skipped.
fn parseFuncParams(comptime source: [:0]const u8, comptime func_name: []const u8, comptime struct_scope: ?[]const u8) ?[]const u8 {
    @setEvalBranchQuota(std.math.maxInt(u32));
    comptime {
        var tokenizer = Tokenizer.init(source);

        // If we need to find inside a struct, first navigate to the struct scope
        if (struct_scope) |sname| {
            if (!enterStructScope(&tokenizer, source, sname)) return null;
        }

        const brace_limit: ?usize = if (struct_scope != null) 1 else null;
        var brace_depth: usize = if (struct_scope != null) 1 else 0;

        // Scan for `fn <func_name>(`
        while (true) {
            const tok = tokenizer.next();
            if (tok.tag == .eof) break;

            // Track brace depth
            if (tok.tag == .l_brace) {
                brace_depth += 1;
                continue;
            }
            if (tok.tag == .r_brace) {
                if (brace_depth == 0) break;
                brace_depth -= 1;
                if (brace_limit) |bl| {
                    if (brace_depth < bl) break;
                }
                continue;
            }

            if (tok.tag == .keyword_fn) {
                const ident = tokenizer.next();
                if (ident.tag == .identifier) {
                    const ident_name = tokenSlice(source, ident);
                    if (std.mem.eql(u8, ident_name, func_name)) {
                        const lparen = tokenizer.next();
                        if (lparen.tag == .l_paren) {
                            return extractParamNames(&tokenizer, source, struct_scope != null);
                        }
                    }
                }
            }
        }

        return null;
    }
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
// Struct Scope Navigation
// =============================================================================

/// Advance the tokenizer to inside a struct definition: `<name> = struct {`.
/// Looks for `pub const <name> = struct {` at the top level.
/// Returns true if found, false if not found.
fn enterStructScope(tokenizer: *Tokenizer, source: [:0]const u8, comptime struct_name: []const u8) bool {
    @setEvalBranchQuota(std.math.maxInt(u32));
    comptime {
        var brace_depth: usize = 0;

        while (true) {
            const tok = tokenizer.next();
            if (tok.tag == .eof) return false;

            if (tok.tag == .l_brace) {
                brace_depth += 1;
                continue;
            }
            if (tok.tag == .r_brace) {
                if (brace_depth > 0) brace_depth -= 1;
                continue;
            }

            // Only look at top-level declarations
            if (brace_depth > 0) continue;

            // Look for: pub const <struct_name> = struct {
            if (tok.tag == .keyword_pub) {
                const t1 = tokenizer.next();
                if (t1.tag == .keyword_const) {
                    const t2 = tokenizer.next();
                    if (t2.tag == .identifier and std.mem.eql(u8, tokenSlice(source, t2), struct_name)) {
                        const t3 = tokenizer.next();
                        if (t3.tag == .equal) {
                            const t4 = tokenizer.next();
                            if (t4.tag == .keyword_struct) {
                                const t5 = tokenizer.next();
                                if (t5.tag == .l_brace) {
                                    // We're now inside the struct
                                    return true;
                                }
                            }
                        }
                    }
                }
            }
        }
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
