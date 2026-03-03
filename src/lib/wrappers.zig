//! Function Wrapper Generators
//!
//! Provides utilities for generating Python-callable wrapper functions
//! from Zig functions, with support for keyword arguments and error mapping.

const std = @import("std");
const py = @import("python.zig");
const PyObject = py.PyObject;
const conversion = @import("conversion.zig");
const Converter = conversion.Converter;
const class_mod = @import("class.zig");
const ClassInfo = class_mod.ClassInfo;
const errors_mod = @import("errors.zig");
const ErrorMapping = errors_mod.ErrorMapping;
const setErrorFromMapping = errors_mod.setErrorFromMapping;
const root = @import("root.zig");
const unwrapSignature = root.unwrapSignature;
const unwrapSignatureValue = root.unwrapSignatureValue;

/// Generate a Python-callable wrapper for a Zig function with class type awareness
pub fn wrapFunctionWithClasses(comptime zig_func: anytype, comptime class_infos: []const ClassInfo) py.PyCFunction {
    const Conv = Converter(class_infos);
    const Fn = @TypeOf(zig_func);
    const fn_info = @typeInfo(Fn).@"fn";
    const params = fn_info.params;
    const ReturnType = unwrapSignature(fn_info.return_type orelse void);

    return struct {
        fn wrapper(self: ?*PyObject, args: ?*PyObject) callconv(.c) ?*PyObject {
            _ = self;

            var zig_args = parseArgs(params, args) catch |err| {
                setError(err);
                return null;
            };
            // Ensure BufferView arguments are released after the function call
            defer releaseBufferViews(&zig_args);

            const raw_result = @call(.auto, zig_func, zig_args);
            const result = unwrapSignatureValue(@TypeOf(raw_result), raw_result);
            return handleReturn(ReturnType, result);
        }

        fn parseArgs(comptime parameters: anytype, args: ?*PyObject) !ArgsTuple(parameters) {
            var result: ArgsTuple(parameters) = undefined;

            if (parameters.len == 0) {
                return result;
            }

            const py_args = args orelse return error.MissingArguments;
            const arg_count = py.PyTuple_Size(py_args);

            if (arg_count != parameters.len) {
                return error.WrongArgumentCount;
            }

            inline for (parameters, 0..) |param, i| {
                const item = py.PyTuple_GetItem(py_args, @intCast(i)) orelse return error.InvalidArgument;
                result[i] = try Conv.fromPy(param.type.?, item);
            }

            return result;
        }

        fn releaseBufferViews(zig_args: *ArgsTuple(params)) void {
            inline for (0..params.len) |i| {
                const ParamType = params[i].type.?;
                const param_info = @typeInfo(ParamType);
                if (param_info == .@"struct" and @hasDecl(ParamType, "is_buffer_view") and ParamType.is_buffer_view) {
                    zig_args[i].release();
                }
                // Release Path types that hold Python object references
                if (ParamType == conversion.Path) {
                    zig_args[i].deinit();
                }
            }
        }

        fn handleReturn(comptime RT: type, result: anytype) ?*PyObject {
            const rt_info = @typeInfo(RT);

            if (rt_info == .error_union) {
                if (result) |value| {
                    return Conv.toPy(@TypeOf(value), value);
                } else |err| {
                    setError(err);
                    return null;
                }
            } else {
                return Conv.toPy(RT, result);
            }
        }

        fn setError(err: anyerror) void {
            // Don't overwrite an exception already set by Python
            // (e.g., KeyboardInterrupt from checkSignals)
            if (py.PyErr_Occurred() != null) return;
            const msg = @errorName(err);
            const exc_type = mapErrorToExc(err);
            py.PyErr_SetString(exc_type, msg.ptr);
        }
    }.wrapper;
}

/// Map a Zig error to the appropriate Python exception type.
fn mapErrorToExc(err: anyerror) *PyObject {
    return errors_mod.mapWellKnownError(@errorName(err));
}

/// Generate a Python-callable wrapper for a Zig function (no class awareness)
pub fn wrapFunction(comptime zig_func: anytype) py.PyCFunction {
    return wrapFunctionWithClasses(zig_func, &[_]ClassInfo{});
}

/// Helper type for argument tuple
pub fn ArgsTuple(comptime params: anytype) type {
    var types: [params.len]type = undefined;
    for (params, 0..) |param, i| {
        types[i] = param.type.?;
    }
    return std.meta.Tuple(&types);
}

/// Type for keyword function signature (C calling convention)
pub const PyCFunctionWithKeywords = *const fn (?*PyObject, ?*PyObject, ?*PyObject) callconv(.c) ?*PyObject;

/// Generate a Python-callable wrapper for a Zig function with named keyword arguments
/// The function should take Args(SomeStruct) as its parameter
pub fn wrapFunctionWithNamedKeywords(comptime zig_func: anytype, comptime class_infos: []const ClassInfo) PyCFunctionWithKeywords {
    const Conv = Converter(class_infos);
    const Fn = @TypeOf(zig_func);
    const fn_info = @typeInfo(Fn).@"fn";
    const params = fn_info.params;
    const ReturnType = unwrapSignature(fn_info.return_type orelse void);

    // Get the Args wrapper type and the inner struct type
    const ArgsWrapperType = params[0].type.?;
    const ArgsStructType = ArgsWrapperType.ArgsStruct;
    const args_fields = @typeInfo(ArgsStructType).@"struct".fields;

    return struct {
        fn wrapper(self: ?*PyObject, args: ?*PyObject, kwargs: ?*PyObject) callconv(.c) ?*PyObject {
            _ = self;

            var result_args: ArgsStructType = undefined;

            // Get positional args count
            const pos_count: usize = if (args) |a| @intCast(py.PyTuple_Size(a)) else 0;

            // Parse each field
            inline for (args_fields, 0..) |field, i| {
                const has_default = field.default_value_ptr != null;
                const is_optional = @typeInfo(field.type) == .optional;

                // Try positional first
                if (i < pos_count) {
                    const item = py.PyTuple_GetItem(args.?, @intCast(i)) orelse {
                        setError(error.InvalidArgument);
                        return null;
                    };
                    if (is_optional and py.PyNone_Check(item)) {
                        @field(result_args, field.name) = null;
                    } else if (is_optional) {
                        const inner_type = @typeInfo(field.type).optional.child;
                        @field(result_args, field.name) = Conv.fromPy(inner_type, item) catch {
                            setFieldError(field.name);
                            return null;
                        };
                    } else {
                        @field(result_args, field.name) = Conv.fromPy(field.type, item) catch {
                            setFieldError(field.name);
                            return null;
                        };
                    }
                } else if (kwargs) |kw| {
                    // Try keyword argument by name
                    if (py.PyDict_GetItemString(kw, field.name.ptr)) |item| {
                        if (is_optional and py.PyNone_Check(item)) {
                            @field(result_args, field.name) = null;
                        } else if (is_optional) {
                            const inner_type = @typeInfo(field.type).optional.child;
                            @field(result_args, field.name) = Conv.fromPy(inner_type, item) catch {
                                setFieldError(field.name);
                                return null;
                            };
                        } else {
                            @field(result_args, field.name) = Conv.fromPy(field.type, item) catch {
                                setFieldError(field.name);
                                return null;
                            };
                        }
                    } else if (has_default) {
                        // Use default value
                        @field(result_args, field.name) = field.defaultValue().?;
                    } else if (is_optional) {
                        @field(result_args, field.name) = null;
                    } else {
                        setMissingError(field.name);
                        return null;
                    }
                } else if (has_default) {
                    // Use default value
                    @field(result_args, field.name) = field.defaultValue().?;
                } else if (is_optional) {
                    @field(result_args, field.name) = null;
                } else {
                    setMissingError(field.name);
                    return null;
                }
            }

            // Call function with wrapped args
            const wrapped_args = ArgsWrapperType{ .value = result_args };
            const raw_result = zig_func(wrapped_args);
            const result = unwrapSignatureValue(@TypeOf(raw_result), raw_result);

            return handleReturn(ReturnType, result);
        }

        fn handleReturn(comptime RT: type, result: anytype) ?*PyObject {
            const rt_info = @typeInfo(RT);
            if (rt_info == .error_union) {
                if (result) |value| {
                    return Conv.toPy(@TypeOf(value), value);
                } else |err| {
                    setError(err);
                    return null;
                }
            } else {
                return Conv.toPy(RT, result);
            }
        }

        fn setError(err: anyerror) void {
            // Don't overwrite an exception already set by Python
            // (e.g., KeyboardInterrupt from checkSignals)
            if (py.PyErr_Occurred() != null) return;
            const msg = @errorName(err);
            py.PyErr_SetString(mapErrorToExc(err), msg.ptr);
        }

        fn setFieldError(comptime field_name: []const u8) void {
            py.PyErr_SetString(py.PyExc_TypeError(), "Invalid type for argument: " ++ field_name);
        }

        fn setMissingError(comptime field_name: []const u8) void {
            py.PyErr_SetString(py.PyExc_TypeError(), "Missing required argument: " ++ field_name);
        }
    }.wrapper;
}

/// Generate a wrapper with custom error mapping
pub fn wrapFunctionWithErrorMapping(comptime zig_func: anytype, comptime class_infos: []const ClassInfo, comptime error_mappings: []const ErrorMapping) py.PyCFunction {
    const Conv = Converter(class_infos);
    const Fn = @TypeOf(zig_func);
    const fn_info = @typeInfo(Fn).@"fn";
    const params = fn_info.params;
    const ReturnType = unwrapSignature(fn_info.return_type orelse void);

    return struct {
        fn wrapper(self: ?*PyObject, args: ?*PyObject) callconv(.c) ?*PyObject {
            _ = self;

            var zig_args = parseArgs(params, args) catch |err| {
                setMappedError(err);
                return null;
            };
            // Ensure BufferView arguments are released after the function call
            defer releaseBufferViews(&zig_args);

            const raw_result = @call(.auto, zig_func, zig_args);
            const result = unwrapSignatureValue(@TypeOf(raw_result), raw_result);
            return handleReturn(ReturnType, result);
        }

        fn parseArgs(comptime parameters: anytype, args: ?*PyObject) !ArgsTuple(parameters) {
            var parse_result: ArgsTuple(parameters) = undefined;

            if (parameters.len == 0) {
                return parse_result;
            }

            const py_args = args orelse return error.MissingArguments;
            const arg_count = py.PyTuple_Size(py_args);

            if (arg_count != parameters.len) {
                return error.WrongArgumentCount;
            }

            inline for (parameters, 0..) |param, i| {
                const item = py.PyTuple_GetItem(py_args, @intCast(i)) orelse return error.InvalidArgument;
                parse_result[i] = try Conv.fromPy(param.type.?, item);
            }

            return parse_result;
        }

        fn releaseBufferViews(zig_args: *ArgsTuple(params)) void {
            inline for (0..params.len) |i| {
                const ParamType = params[i].type.?;
                const param_info = @typeInfo(ParamType);
                if (param_info == .@"struct" and @hasDecl(ParamType, "is_buffer_view") and ParamType.is_buffer_view) {
                    zig_args[i].release();
                }
                // Release Path types that hold Python object references
                if (ParamType == conversion.Path) {
                    zig_args[i].deinit();
                }
            }
        }

        fn handleReturn(comptime RT: type, result: anytype) ?*PyObject {
            const rt_info = @typeInfo(RT);

            if (rt_info == .error_union) {
                if (result) |value| {
                    return Conv.toPy(@TypeOf(value), value);
                } else |err| {
                    setMappedError(err);
                    return null;
                }
            } else {
                return Conv.toPy(RT, result);
            }
        }

        fn setMappedError(err: anyerror) void {
            setErrorFromMapping(error_mappings, err);
        }
    }.wrapper;
}

// ============================================================================
// Function Definition Helpers
// ============================================================================

/// Function definition entry - stores info needed to wrap at module creation time
pub fn FuncDefEntry(comptime Func: type) type {
    return struct {
        name: [*:0]const u8,
        func: Func,
        doc: ?[*:0]const u8,
    };
}

/// Helper to create a function entry
pub fn func(comptime name: [*:0]const u8, comptime function: anytype, comptime doc: ?[*:0]const u8) FuncDefEntry(@TypeOf(function)) {
    return .{
        .name = name,
        .func = function,
        .doc = doc,
    };
}

// ============================================================================
// Keyword Arguments Support
// ============================================================================

/// Define named keyword arguments using a struct.
/// Each field becomes a keyword argument with its name.
/// Optional fields (?T) have a default of null.
/// Fields with default values use those defaults.
///
/// Example:
/// ```zig
/// const GreetArgs = struct {
///     name: []const u8,              // Required
///     greeting: ?[]const u8 = null,  // Optional, default null
///     times: i64 = 1,                // Optional, default 1
/// };
///
/// fn greet(args: pyoz.Args(GreetArgs)) []const u8 {
///     const greeting = args.greeting orelse "Hello";
///     // ...
/// }
/// ```
pub fn Args(comptime T: type) type {
    return struct {
        pub const ArgsStruct = T;
        pub const is_pyoz_args = true;
        value: T,

        // Allow direct field access via the wrapper
        pub fn get(self: @This()) T {
            return self.value;
        }
    };
}

/// Wrapper type for functions with keyword arguments using Args(T)
pub fn KwFuncDefEntry(comptime Func: type) type {
    return struct {
        name: [*:0]const u8,
        func: Func,
        doc: ?[*:0]const u8,
        is_named_kwargs: bool = true,
    };
}

/// Create a function entry with keyword arguments.
/// The function should accept Args(YourArgsStruct) as its parameter.
pub fn kwfunc(comptime name: [*:0]const u8, comptime function: anytype, comptime doc: ?[*:0]const u8) KwFuncDefEntry(@TypeOf(function)) {
    return .{
        .name = name,
        .func = function,
        .doc = doc,
        .is_named_kwargs = true,
    };
}
