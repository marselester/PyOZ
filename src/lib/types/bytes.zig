//! Bytes types for Python interop
//!
//! Provides Bytes, ByteArray, MemoryView, and BytesLike types for working with
//! Python bytes, bytearray, and memoryview objects.

const py = @import("../python.zig");

/// A bytes type for accepting Python bytes
pub const Bytes = struct {
    pub const _is_pyoz_bytes = true;

    data: []const u8,
};

/// A bytearray type for accepting Python bytearray (mutable)
pub const ByteArray = struct {
    pub const _is_pyoz_bytearray = true;

    data: []u8,
};

/// A memoryview type for accepting Python memoryview objects.
/// Provides read-only access to the underlying buffer data.
/// The memoryview must be contiguous and contain byte-sized elements.
pub const MemoryView = struct {
    pub const _is_pyoz_memoryview = true;

    data: []const u8,
    /// The Python buffer — must be released when done
    _view: py.Py_buffer,

    /// Release the underlying buffer. Must be called when done.
    pub fn release(self: *MemoryView) void {
        py.PyBuffer_Release(&self._view);
    }
};

/// A unified byte-like type that accepts Python bytes, bytearray, or memoryview.
/// Provides read-only access to the underlying data regardless of source type.
pub const BytesLike = struct {
    pub const _is_pyoz_byteslike = true;

    data: []const u8,
    /// Non-null if backed by a buffer (memoryview) that needs releasing
    _view: ?py.Py_buffer = null,

    /// Release the underlying buffer if one was acquired. Must be called when done.
    pub fn release(self: *BytesLike) void {
        if (self._view) |*view| {
            py.PyBuffer_Release(view);
            self._view = null;
        }
    }
};
