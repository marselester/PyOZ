# Auto-Scan with `.from`

The `.from` API auto-scans Zig namespaces and registers all Python-compatible public declarations automatically. What was 100+ lines of `pyoz.func()` / `pyoz.class()` / `pyoz.constant()` boilerplate becomes a single line.

## The Problem

A typical module definition repeats every name three times:

```zig
const Example = pyoz.module(.{
    .name = "example",
    .funcs = &.{
        pyoz.func("add", add, "Add two integers"),
        pyoz.func("subtract", subtract, "Subtract two numbers"),
        pyoz.func("multiply", multiply, "Multiply two floats"),
        // ... 50+ more identical patterns ...
    },
    .classes = &.{
        pyoz.class("Point", Point),
        pyoz.class("Vector", Vector),
    },
    .enums = &.{
        pyoz.enumDef("Color", Color),
    },
    .consts = &.{
        pyoz.constant("PI", 3.14159),
        pyoz.constant("VERSION", "1.0.0"),
    },
});
```

## The Solution

Move your declarations into separate files and let `.from` scan them:

```zig
const math = @import("math.zig");
const types = @import("types.zig");

const Example = pyoz.module(.{
    .name = "example",
    .from = &.{ math, types },
});
```

PyOZ inspects every `pub` declaration in each namespace at compile time and registers it as the appropriate Python construct — function, class, enum, or constant.

## Auto-Detection Rules

PyOZ classifies each `pub` declaration by its type:

| Declaration | Python Construct | Detection Rule |
|-------------|-----------------|----------------|
| `pub fn add(a: i64, b: i64) i64` | Function | Any `pub fn` with Python-compatible params |
| `pub const Point = struct { x: f64, ... }` | Class | Struct with fields, methods, `__doc__`, or `__new__` |
| `pub const Color = enum(i32) { ... }` | Enum | Any `enum` type |
| `pub const PI: f64 = 3.14159` | Constant | Scalar (`int`, `float`, `bool`) |
| `pub const VERSION: []const u8 = "1.0"` | Constant | String type |
| `pub const MyErr = pyoz.Exception(...)` | Exception | `pyoz.Exception` marker |
| `pub const __errors__ = pyoz.ErrorMap(...)` | Error mappings | `pyoz.ErrorMap` marker |
| `fn private(...)` | *(skipped)* | Not `pub` |
| `pub fn _helper(...)` | *(skipped)* | `_` prefix convention |
| `pub const add__doc__ = "..."` | *(consumed)* | `__doc__` suffix → docstring for `add` |

### What Gets Skipped

These declarations are silently skipped (not exported, no error):

- **Non-public** declarations (no `pub`)
- **`_` prefixed** names (private convention)
- **`__doc__` suffixed** names (consumed as docstrings)
- **`__errors__`** (consumed as error mappings)
- **`__tests__`** and **`__benchmarks__`** (consumed for inline tests/benchmarks)
- **Incompatible signatures** — functions with generic/comptime/`type` parameters
- **Type aliases** to primitive types

## Docstring Convention

Since `.from` files are pure Zig with no registration calls, docstrings use a naming convention — declare a `pub const` with the suffix `__doc__`:

```zig
pub fn add(a: i64, b: i64) i64 {
    return a + b;
}
pub const add__doc__ = "Add two integers together";

pub fn divide(a: f64, b: f64) !f64 {
    if (b == 0) return error.DivisionByZero;
    return a / b;
}
pub const divide__doc__ = "Divide a by b (raises ZeroDivisionError if b=0)";
```

The `__doc__` constant is consumed and never exported to Python. Functions without a `__doc__` constant get no docstring.

### Class Docstrings

Classes use their own `__doc__` field as usual:

```zig
pub const Point = struct {
    pub const __doc__: [*:0]const u8 = "A 2D point in space";
    x: f64,
    y: f64,

    pub fn length(self: *const Point) f64 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }
    pub const length__doc__: [*:0]const u8 = "Distance from origin";
};
```

### Module Docstring

If the module config has no `.doc` field, PyOZ looks for a namespace-level `__doc__` in the first non-submodule `.from` entry:

```zig
// math.zig
pub const __doc__ = "Mathematical utility functions";

pub fn add(a: i64, b: i64) i64 { return a + b; }
```

```zig
// root
const Example = pyoz.module(.{
    .name = "example",
    .from = &.{ math },  // module docstring comes from math.__doc__
});
```

## Keyword Arguments

`.from` auto-detects functions using `pyoz.Args(T)` and registers them with named keyword argument support:

```zig
const pyoz = @import("PyOZ");

pub fn safe_sqrt(args: pyoz.Args(struct { value: f64, default: ?f64 = null })) f64 {
    if (args.value.value < 0) return args.value.default orelse 0.0;
    return @sqrt(args.value.value);
}
pub const safe_sqrt__doc__ = "Square root with optional default for negative values";
```

In Python: `safe_sqrt(value=4.0)` or `safe_sqrt(value=-1.0, default=-1.0)`

Struct fields with defaults become optional keyword arguments. Fields without defaults are required. This is the same `pyoz.Args(T)` mechanism used with explicit `pyoz.kwfunc()` — `.from` just detects it automatically.

## Filtering with `pyoz.source()`

By default, `.from` exports everything public. Use `pyoz.source()` to filter:

### `.only` — Export Only Listed Names

```zig
.from = &.{
    pyoz.source(math, .{ .only = &.{ "add", "subtract", "PI" } }),
},
```

### `.exclude` — Export Everything Except Listed Names

```zig
.from = &.{
    pyoz.source(math, .{ .exclude = &.{ "internal_helper", "debug_dump" } }),
},
```

### Validation

- `.only` and `.exclude` are **mutually exclusive** — using both is a compile error.
- Names that don't match any `pub` declaration produce a compile-time warning (helps catch typos).

## Submodules with `pyoz.sub()`

Create nested module structures with `pyoz.sub()`:

```zig
const string_utils = @import("string_utils.zig");
const io_utils = @import("io_utils.zig");

const Example = pyoz.module(.{
    .name = "example",
    .from = &.{
        math,
        pyoz.sub("strings", string_utils),
        pyoz.sub("io", io_utils),
    },
});
```

In Python:

```python
import example

example.strings.format_string("hello")
example.io.read_file("data.txt")
```

### Submodule Docstrings

Submodules pick up `__doc__` from their namespace:

```zig
// string_utils.zig
pub const __doc__ = "String utility functions";

pub fn format_string(s: []const u8) []const u8 { ... }
```

### Filtered Submodules

Combine `pyoz.sub()` with `pyoz.source()`:

```zig
.from = &.{
    pyoz.sub("strings", pyoz.source(string_utils, .{ .only = &.{ "format_string", "pad_left" } })),
},
```

## Exception Markers

Define custom exceptions inside `.from` namespaces using `pyoz.Exception()`:

```zig
const pyoz = @import("PyOZ");

pub const ValidationError = pyoz.Exception(.ValueError, "Raised when validation fails");
pub const NotFoundError = pyoz.Exception(.KeyError, null);
```

These are auto-detected and registered as importable Python exceptions:

```python
from example import ValidationError
raise ValidationError("invalid input")
```

### Raising from Zig

Use `Module.getException("ValidationError").raise("message")` to raise `.from`-defined exceptions by name.

## Error Map Markers

Define error-to-exception mappings inside `.from` namespaces using `pyoz.ErrorMap()`:

```zig
const pyoz = @import("PyOZ");

pub const __errors__ = pyoz.ErrorMap(.{
    .{ "InvalidInput", .ValueError },
    .{ "NotFound", .KeyError },
    .{ "TooBig", .ValueError, "Value exceeds limit" },
});
```

These are merged with any explicit `.error_mappings` in the module config.

## Tests and Benchmarks

Define inline tests and benchmarks inside `.from` namespaces:

```zig
const pyoz = @import("PyOZ");

pub fn add(a: i64, b: i64) i64 { return a + b; }

pub const __tests__ = &[_]pyoz.TestDef{
    pyoz.@"test"("add basic", "assert m.add(2, 3) == 5"),
    pyoz.@"test"("add negative", "assert m.add(-1, 1) == 0"),
    pyoz.testRaises("add wrong type", "TypeError", "m.add('a', 'b')"),
};

pub const __benchmarks__ = &[_]pyoz.BenchDef{
    pyoz.bench("add", "m.add(100, 200)"),
};
```

These are merged with any explicit `.tests` / `.benchmarks` in the module config and run via `pyoz test` / `pyoz bench` as usual.

## Mixing `.from` with Explicit Definitions

`.from` and explicit fields (`.funcs`, `.classes`, etc.) compose naturally:

```zig
const math = @import("math.zig");

const Example = pyoz.module(.{
    .name = "example",
    .from = &.{ math },
    .funcs = &.{
        // This function needs a custom name different from its Zig identifier
        pyoz.func("compute", internal_compute, "Run computation"),
    },
    .exceptions = &.{
        pyoz.exception("AppError", .RuntimeError),
    },
});
```

### Deduplication

If a name appears in both `.from` and an explicit field, **explicit wins** — the `.from` version is silently skipped. This lets you override specific items while auto-scanning the rest:

```zig
const math = @import("math.zig");  // has pub fn add(...)

const Example = pyoz.module(.{
    .name = "example",
    .from = &.{ math },
    .funcs = &.{
        // Override math.add with custom registration (e.g., different doc)
        pyoz.func("add", math.add, "Custom docstring for add"),
    },
});
```

### Duplicate Detection

If the same name appears in multiple `.from` namespaces, you get a compile error. Use `pyoz.source()` with `.exclude` to resolve conflicts.

## Single-File Modules with `@This()`

For small modules, put everything in one file using `@This()`:

```zig
const pyoz = @import("PyOZ");

pub fn add(a: i64, b: i64) i64 { return a + b; }
pub const add__doc__ = "Add two integers";

pub fn multiply(a: f64, b: f64) f64 { return a * b; }

pub const PI: f64 = 3.14159;

const _module = pyoz.module(.{
    .name = "mymath",
    .from = &.{ @This() },
});

pub export fn PyInit_mymath() ?*pyoz.PyObject {
    return _module.init();
}
```

The `_module` and `PyInit_mymath` declarations are skipped automatically (`_` prefix and `export fn`).

## Stub Generation

`.from` entries are fully included in the auto-generated `.pyi` type stubs. Functions, classes, enums, constants, exceptions, and submodules all appear in the stub file with correct type annotations and docstrings.

Submodules are represented as classes with `@staticmethod` methods in the stub.

## ABI3 Compatibility

`.from` works identically in ABI3 (Stable ABI) mode. No special configuration needed — class registration automatically uses the correct code path.

## Complete Example

```zig
// math.zig — pure Zig, no PyOZ imports needed for basic functions
const std = @import("std");

pub fn add(a: i64, b: i64) i64 { return a + b; }
pub const add__doc__ = "Add two integers";

pub fn fibonacci(n: i64) i64 {
    if (n <= 0) return 0;
    if (n == 1) return 1;
    var a: i64 = 0;
    var b: i64 = 1;
    var i: i64 = 2;
    while (i <= n) : (i += 1) {
        const temp = a +% b;
        a = b;
        b = temp;
    }
    return b;
}
pub const fibonacci__doc__ = "Calculate the Fibonacci number at position n";

pub const PI: f64 = 3.14159265358979;
pub const MAX_FIB_INDEX: i64 = 92;
```

```zig
// types.zig
pub const Point = struct {
    pub const __doc__: [*:0]const u8 = "A 2D point in space";
    x: f64,
    y: f64,

    pub fn length(self: *const Point) f64 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }
    pub const length__doc__: [*:0]const u8 = "Distance from origin";
};

pub const Color = enum(i32) { Red = 1, Green = 2, Blue = 3 };
```

```zig
// root.zig
const pyoz = @import("PyOZ");
const math = @import("math.zig");
const types = @import("types.zig");

const Example = pyoz.module(.{
    .name = "example",
    .from = &.{ math, types },
});

pub export fn PyInit_example() ?*pyoz.PyObject {
    return Example.init();
}
```

In Python:

```python
import example

example.add(2, 3)           # 5
example.fibonacci(10)       # 55
example.PI                  # 3.14159265358979

p = example.Point(3.0, 4.0)
p.length()                  # 5.0

example.Color.Red           # Color.Red (IntEnum, value=1)
```

## Next Steps

- [Functions](functions.md) — Explicit function registration with `pyoz.func()` and `pyoz.kwfunc()`
- [Testing & Benchmarks](testing.md) — Inline tests with `pyoz test`
- [Submodules](submodules.md) — Manual submodule creation with `mod.createSubmodule()`
- [Type Stubs](stubs.md) — Auto-generated `.pyi` files
