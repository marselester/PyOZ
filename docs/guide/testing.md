# Testing & Benchmarks

PyOZ lets you define tests and benchmarks inline in your Zig module definition. Tests are Python code snippets that get embedded into the compiled `.so` and extracted at runtime by `pyoz test` and `pyoz bench`. No separate test files, no stub chicken-and-egg problem.

## Why Inline Tests?

Writing Python tests for a Zig extension normally requires `.pyi` stubs for autocomplete, but stubs only exist after compilation. Inline tests solve this:

- Tests live next to the code they test
- No external test files to keep in sync
- `pyoz test` builds, extracts, and runs in one command
- Uses `unittest` from the standard library (zero dependencies)

## Defining Tests

Add a `.tests` field to your `pyoz.module()` config:

```zig
pub const Module = pyoz.module(.{
    .name = "mymodule",
    .funcs = &.{
        pyoz.func("add", add, "Add two integers"),
        pyoz.func("divide", divide, "Divide two numbers"),
    },
    .tests = &.{
        pyoz.@"test"("add returns correct result",
            \\assert mymodule.add(2, 3) == 5
        ),
        pyoz.@"test"("add handles negatives",
            \\assert mymodule.add(-1, 1) == 0
            \\assert mymodule.add(-5, -3) == -8
        ),
    },
});
```

Each test becomes a `unittest.TestCase` method. The test name is slugified (`"add returns correct result"` becomes `test_add_returns_correct_result`).

!!! note "`@\"test\"` syntax"
    `test` is a reserved keyword in Zig, so the function is called as `pyoz.@"test"(...)`. This is standard Zig syntax for using keywords as identifiers.

### Test Body

The test body is a Zig multiline string literal (lines prefixed with `\\`). Each line becomes a line of Python code inside the test method. Your module is automatically imported — use the module name directly:

```zig
pyoz.@"test"("string functions work",
    \\result = mymodule.greet("World")
    \\assert result == "Hello, World!"
    \\assert isinstance(result, str)
),
```

### Testing Exceptions

Use `pyoz.testRaises` to verify that code raises the expected exception:

```zig
pyoz.testRaises("divide by zero raises ValueError", "ValueError",
    \\mymodule.divide(1, 0)
),

pyoz.testRaises("add rejects strings", "TypeError",
    \\mymodule.add("a", 1)
),
```

This generates a test using `self.assertRaises()`:

```python
def test_divide_by_zero_raises_valueerror(self):
    with self.assertRaises(ValueError):
        mymodule.divide(1, 0)
```

### Testing Classes

Tests have full access to your module's classes, enums, and constants:

```zig
.tests = &.{
    pyoz.@"test"("Point construction",
        \\p = mymodule.Point(3.0, 4.0)
        \\assert p.x == 3.0
        \\assert p.y == 4.0
    ),
    pyoz.@"test"("Point magnitude",
        \\p = mymodule.Point(3.0, 4.0)
        \\assert abs(p.magnitude() - 5.0) < 1e-10
    ),
    pyoz.@"test"("Point addition",
        \\p1 = mymodule.Point(1.0, 2.0)
        \\p2 = mymodule.Point(3.0, 4.0)
        \\p3 = p1 + p2
        \\assert p3.x == 4.0
        \\assert p3.y == 6.0
    ),
    pyoz.testRaises("Point rejects strings", "TypeError",
        \\mymodule.Point("a", "b")
    ),
},
```

## Running Tests

```bash
pyoz test
```

This builds the module (debug mode by default), extracts the embedded test file, and runs it with `unittest`:

```
Building mymodule v0.1.0 (Debug)...
  Python 3.10 detected
  Module: src/lib.zig
  Using build.zig

Running tests...

....
----------------------------------------------------------------------
Ran 4 tests in 0.001s

OK
```

### Verbose Output

Use `-v` or `--verbose` for detailed test results:

```bash
pyoz test -v
```

```
Running tests...

test_add_handles_negatives (zig-out.lib.__pyoz_test.TestMymodule) ... ok
test_add_raises_typeerror_on_string (zig-out.lib.__pyoz_test.TestMymodule) ... ok
test_add_returns_correct_result (zig-out.lib.__pyoz_test.TestMymodule) ... ok
test_point_magnitude (zig-out.lib.__pyoz_test.TestMymodule) ... ok

----------------------------------------------------------------------
Ran 4 tests in 0.001s

OK
```

### Release Mode

Build in release mode before testing:

```bash
pyoz test --release
```

### Options

| Option | Description |
|--------|-------------|
| `-v, --verbose` | Show individual test results |
| `-r, --release` | Build in release mode before testing |
| `-h, --help` | Show help message |

## Defining Benchmarks

Add a `.benchmarks` field to your module config:

```zig
pub const Module = pyoz.module(.{
    .name = "mymodule",
    .funcs = &.{
        pyoz.func("add", add, "Add two integers"),
        pyoz.func("multiply", multiply, "Multiply two floats"),
    },
    .benchmarks = &.{
        pyoz.bench("add performance",
            \\mymodule.add(100, 200)
        ),
        pyoz.bench("multiply performance",
            \\mymodule.multiply(3.14, 2.71)
        ),
    },
});
```

Each benchmark body is timed over 100,000 iterations using Python's `timeit` module.

## Running Benchmarks

```bash
pyoz bench
```

Benchmarks always build in release mode for accurate measurements:

```
Building mymodule v0.1.0 (Release)...
  Python 3.10 detected
  Module: src/lib.zig
  Using build.zig

Running benchmarks...

Benchmark Results:
------------------------------------------------------------
  add performance                            20,051,810 ops/s
  multiply performance                       20,268,969 ops/s
------------------------------------------------------------
```

## Syntax Checking

Before running tests or benchmarks, PyOZ validates the generated Python file with `py_compile`. If your inline code has a syntax error, you get a clear message with the exact line and position:

```
Building mymodule v0.1.0 (Debug)...

  File "zig-out/lib/__pyoz_test.py", line 7
    assert mymodule.add(2, 3) ==== 5
                                ^^
SyntaxError: invalid syntax

Syntax error in generated test file.
Check the Python code in your pyoz.@"test"() definitions.
```

## Generated Code

For reference, here's what PyOZ generates from your test definitions.

### Test File

```python
import unittest
import mymodule

class TestMymodule(unittest.TestCase):
    def test_add_returns_correct_result(self):
        assert mymodule.add(2, 3) == 5

    def test_add_handles_negatives(self):
        assert mymodule.add(-1, 1) == 0
        assert mymodule.add(-5, -3) == -8

    def test_divide_by_zero_raises_valueerror(self):
        with self.assertRaises(ValueError):
            mymodule.divide(1, 0)

if __name__ == "__main__":
    unittest.main()
```

### Benchmark File

```python
import timeit
import mymodule

def run_benchmarks():
    results = []
    def bench_add_performance():
        mymodule.add(100, 200)
    t = timeit.timeit(bench_add_performance, number=100000)
    results.append(("add performance", t))

    def bench_multiply_performance():
        mymodule.multiply(3.14, 2.71)
    t = timeit.timeit(bench_multiply_performance, number=100000)
    results.append(("multiply performance", t))

    print("\nBenchmark Results:")
    print("-" * 60)
    for name, elapsed in results:
        ops = 100000 / elapsed
        print(f"  {name:<40} {ops:>12,.0f} ops/s")
    print("-" * 60)

if __name__ == "__main__":
    run_benchmarks()
```

## Complete Example

Here's a full module with functions, classes, tests, and benchmarks:

```zig
const pyoz = @import("PyOZ");

fn add(a: i64, b: i64) i64 {
    return a + b;
}

fn divide(a: f64, b: f64) !f64 {
    if (b == 0.0) return error.DivisionByZero;
    return a / b;
}

const Point = struct {
    x: f64,
    y: f64,

    pub fn magnitude(self: *const Point) f64 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }
};

pub const Module = pyoz.module(.{
    .name = "mymodule",
    .funcs = &.{
        pyoz.func("add", add, "Add two integers"),
        pyoz.func("divide", divide, "Divide two numbers"),
    },
    .classes = &.{
        pyoz.class("Point", Point),
    },
    .error_mappings = &.{
        pyoz.mapError("DivisionByZero", .ValueError),
    },
    .tests = &.{
        pyoz.@"test"("add basic",
            \\assert mymodule.add(2, 3) == 5
            \\assert mymodule.add(0, 0) == 0
        ),
        pyoz.@"test"("add negatives",
            \\assert mymodule.add(-1, 1) == 0
            \\assert mymodule.add(-5, -3) == -8
        ),
        pyoz.@"test"("divide works",
            \\assert mymodule.divide(10, 2) == 5.0
            \\assert mymodule.divide(7, 2) == 3.5
        ),
        pyoz.testRaises("divide by zero", "ValueError",
            \\mymodule.divide(1, 0)
        ),
        pyoz.testRaises("add type error", "TypeError",
            \\mymodule.add("a", 1)
        ),
        pyoz.@"test"("Point construction",
            \\p = mymodule.Point(3.0, 4.0)
            \\assert p.x == 3.0
            \\assert p.y == 4.0
        ),
        pyoz.@"test"("Point magnitude",
            \\p = mymodule.Point(3.0, 4.0)
            \\assert abs(p.magnitude() - 5.0) < 1e-10
        ),
    },
    .benchmarks = &.{
        pyoz.bench("add",
            \\mymodule.add(100, 200)
        ),
        pyoz.bench("divide",
            \\mymodule.divide(355.0, 113.0)
        ),
        pyoz.bench("Point creation",
            \\mymodule.Point(3.0, 4.0)
        ),
        pyoz.bench("Point.magnitude",
            \\mymodule.Point(3.0, 4.0).magnitude()
        ),
    },
});
```

## API Reference

| Function | Description |
|----------|-------------|
| `pyoz.@"test"(name, body)` | Define an assertion-based test |
| `pyoz.testRaises(name, exception, body)` | Define a test that expects an exception |
| `pyoz.bench(name, body)` | Define a benchmark |

| Type | Description |
|------|-------------|
| `pyoz.TestDef` | Test definition struct |
| `pyoz.BenchDef` | Benchmark definition struct |

| Module Config Field | Type | Description |
|---------------------|------|-------------|
| `.tests` | `[]const TestDef` | Array of test definitions |
| `.benchmarks` | `[]const BenchDef` | Array of benchmark definitions |

## How It Works

1. Test and benchmark bodies are Python code embedded as Zig comptime strings
2. At compile time, PyOZ generates complete Python files and embeds them as binary sections (`.pyoztest` / `.pyozbenc`) in the compiled `.so`
3. `pyoz test` / `pyoz bench` extract the content from the binary section using the same mechanism as [type stubs](stubs.md)
4. The extracted Python file is written to `zig-out/lib/` and executed with `python3`

## Tests in `.from` Namespaces

When using the [`.from` auto-scan API](from.md), you can define tests and benchmarks directly in your scanned namespaces using `__tests__` and `__benchmarks__`:

```zig
// math.zig
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

These are automatically merged with any explicit `.tests` / `.benchmarks` in the module config. Run them with `pyoz test` / `pyoz bench` as usual.

## Next Steps

- [Auto-Scan (.from)](from.md) - Zero-boilerplate module definitions
- [Type Stubs](stubs.md) - Auto-generated `.pyi` files
- [Error Handling](errors.md) - Exception types and error mapping
- [CLI Reference](../cli/test.md) - Detailed CLI options
