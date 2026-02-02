const std = @import("std");
const http = std.http;
const json = std.json;

const log = std.log.scoped(.imprint);

// SDK metadata
pub const sdk_name = "imprint-zig";
pub const sdk_version = "0.1.0";
pub const sdk_language = "zig";

/// Configuration for the Imprint client.
pub const Config = struct {
    api_key: []const u8,
    service_name: []const u8,
    ingest_url: []const u8 = "https://ingest.imprint.cloud/v1/spans",
    batch_size: usize = 100,
    flush_interval_ms: u64 = 5000,
};

/// A single operation within a trace.
pub const Span = struct {
    trace_id: [32]u8,
    span_id: [16]u8,
    parent_id: ?[16]u8 = null,
    namespace: []const u8,
    name: []const u8,
    kind: []const u8 = "internal",
    start_time: i128, // Unix timestamp nanoseconds
    duration_ns: u64 = 0,
    status_code: u16 = 0,
    error_data: ?[]const u8 = null,
    attributes: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, namespace: []const u8, name: []const u8) Self {
        return Self{
            .trace_id = generateTraceId(),
            .span_id = generateSpanId(),
            .namespace = namespace,
            .name = name,
            .start_time = std.time.nanoTimestamp(),
            .attributes = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn initWithParent(allocator: std.mem.Allocator, namespace: []const u8, name: []const u8, parent_trace_id: [32]u8, parent_span_id: [16]u8) Self {
        return Self{
            .trace_id = parent_trace_id,
            .span_id = generateSpanId(),
            .parent_id = parent_span_id,
            .namespace = namespace,
            .name = name,
            .start_time = std.time.nanoTimestamp(),
            .attributes = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.attributes.deinit();
    }

    pub fn setKind(self: *Self, kind: []const u8) void {
        self.kind = kind;
    }

    pub fn setAttribute(self: *Self, key: []const u8, value: []const u8) !void {
        try self.attributes.put(key, value);
    }

    pub fn setStatus(self: *Self, code: u16) void {
        self.status_code = code;
    }

    pub fn recordError(self: *Self, err_msg: []const u8) void {
        self.error_data = err_msg;
    }

    pub fn end(self: *Self) void {
        const end_time = std.time.nanoTimestamp();
        self.duration_ns = @intCast(@as(u64, @intCast(end_time - self.start_time)));
    }

    /// Returns W3C traceparent header value.
    pub fn traceparent(self: *const Self) [55]u8 {
        var buf: [55]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "00-{s}-{s}-01", .{ &self.trace_id, &self.span_id }) catch unreachable;
        return buf;
    }

    /// Serialize span to JSON.
    pub fn toJson(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        var list = std.ArrayList(u8).init(allocator);
        errdefer list.deinit();

        try list.appendSlice("{");

        // Required fields
        try list.appendSlice("\"trace_id\":\"");
        try list.appendSlice(&self.trace_id);
        try list.appendSlice("\",\"span_id\":\"");
        try list.appendSlice(&self.span_id);
        try list.appendSlice("\"");

        // Parent ID
        if (self.parent_id) |pid| {
            try list.appendSlice(",\"parent_id\":\"");
            try list.appendSlice(&pid);
            try list.appendSlice("\"");
        }

        // String fields
        try list.appendSlice(",\"namespace\":\"");
        try list.appendSlice(self.namespace);
        try list.appendSlice("\",\"name\":\"");
        try list.appendSlice(self.name);
        try list.appendSlice("\",\"kind\":\"");
        try list.appendSlice(self.kind);
        try list.appendSlice("\"");

        // Numeric fields
        var num_buf: [32]u8 = undefined;

        try list.appendSlice(",\"start_time\":");
        const start_str = std.fmt.bufPrint(&num_buf, "{d}", .{self.start_time}) catch "0";
        try list.appendSlice(start_str);

        try list.appendSlice(",\"duration_ns\":");
        const dur_str = std.fmt.bufPrint(&num_buf, "{d}", .{self.duration_ns}) catch "0";
        try list.appendSlice(dur_str);

        try list.appendSlice(",\"status_code\":");
        const status_str = std.fmt.bufPrint(&num_buf, "{d}", .{self.status_code}) catch "0";
        try list.appendSlice(status_str);

        // Error data
        if (self.error_data) |err| {
            try list.appendSlice(",\"error_data\":\"");
            try list.appendSlice(err);
            try list.appendSlice("\"");
        }

        // Attributes
        try list.appendSlice(",\"attributes\":{");

        // SDK attributes
        try list.appendSlice("\"telemetry.sdk.name\":\"");
        try list.appendSlice(sdk_name);
        try list.appendSlice("\",\"telemetry.sdk.version\":\"");
        try list.appendSlice(sdk_version);
        try list.appendSlice("\",\"telemetry.sdk.language\":\"");
        try list.appendSlice(sdk_language);
        try list.appendSlice("\"");

        // User attributes
        var attr_iter = self.attributes.iterator();
        while (attr_iter.next()) |entry| {
            try list.appendSlice(",\"");
            try list.appendSlice(entry.key_ptr.*);
            try list.appendSlice("\":\"");
            try list.appendSlice(entry.value_ptr.*);
            try list.appendSlice("\"");
        }

        try list.appendSlice("}}");

        return list.toOwnedSlice();
    }
};

/// Imprint client for sending spans.
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    buffer: std.ArrayList(*Span),
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: Config) Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .buffer = std.ArrayList(*Span).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        // Flush remaining spans
        self.flush() catch {};
        self.buffer.deinit();
    }

    /// Start a new span.
    pub fn startSpan(self: *Self, name: []const u8) Span {
        return Span.init(self.allocator, self.config.service_name, name);
    }

    /// Start a child span with parent context.
    pub fn startChildSpan(self: *Self, name: []const u8, parent: *const Span) Span {
        return Span.initWithParent(
            self.allocator,
            self.config.service_name,
            name,
            parent.trace_id,
            parent.span_id,
        );
    }

    /// Record a completed span.
    pub fn recordSpan(self: *Self, span: *Span) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.buffer.append(span);

        if (self.buffer.items.len >= self.config.batch_size) {
            try self.flushLocked();
        }
    }

    /// Force flush all buffered spans.
    pub fn flush(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.flushLocked();
    }

    fn flushLocked(self: *Self) !void {
        if (self.buffer.items.len == 0) return;

        // Build JSON array
        var payload = std.ArrayList(u8).init(self.allocator);
        defer payload.deinit();

        try payload.append('[');
        for (self.buffer.items, 0..) |span, i| {
            if (i > 0) try payload.append(',');
            const span_json = try span.toJson(self.allocator);
            defer self.allocator.free(span_json);
            try payload.appendSlice(span_json);
        }
        try payload.append(']');

        // Send to ingest
        self.sendBatch(payload.items) catch |err| {
            log.err("Failed to send spans: {}", .{err});
        };

        // Clear buffer (spans are owned by caller)
        self.buffer.clearRetainingCapacity();
    }

    fn sendBatch(self: *Self, payload: []const u8) !void {
        // Parse URL
        const uri = try std.Uri.parse(self.config.ingest_url);

        // Create HTTP client
        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        // Prepare authorization header
        var auth_buf: [256]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.config.api_key}) catch return error.BufferTooSmall;

        // Use fetch API (Zig 0.13+)
        var response_body = std.ArrayList(u8).init(self.allocator);
        defer response_body.deinit();

        const result = try client.fetch(.{
            .location = .{ .uri = uri },
            .method = .POST,
            .payload = payload,
            .extra_headers = &[_]http.Header{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Authorization", .value = auth_header },
            },
            .response_storage = .{ .dynamic = &response_body },
        });

        if (result.status != .ok and result.status != .created and result.status != .accepted) {
            log.warn("Ingest returned status: {}", .{result.status});
            return error.IngestError;
        }

        log.info("Sent batch of {d} spans", .{self.buffer.items.len});
    }
};

/// Parse W3C traceparent header.
pub fn parseTraceparent(header: []const u8) ?struct { trace_id: [32]u8, span_id: [16]u8 } {
    if (header.len != 55) return null;
    if (!std.mem.startsWith(u8, header, "00-")) return null;
    if (header[35] != '-' or header[52] != '-') return null;

    var result: struct { trace_id: [32]u8, span_id: [16]u8 } = undefined;
    @memcpy(&result.trace_id, header[3..35]);
    @memcpy(&result.span_id, header[36..52]);

    return result;
}

/// Generate a random 32-character trace ID.
fn generateTraceId() [32]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    var hex: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x:0>32}", .{std.mem.readInt(u128, &bytes, .big)}) catch unreachable;
    return hex;
}

/// Generate a random 16-character span ID.
fn generateSpanId() [16]u8 {
    var bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    var hex: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x:0>16}", .{std.mem.readInt(u64, &bytes, .big)}) catch unreachable;
    return hex;
}

// Tests
test "generateTraceId produces 32 hex chars" {
    const id = generateTraceId();
    try std.testing.expectEqual(@as(usize, 32), id.len);
}

test "generateSpanId produces 16 hex chars" {
    const id = generateSpanId();
    try std.testing.expectEqual(@as(usize, 16), id.len);
}

test "parseTraceparent valid" {
    const header = "00-0123456789abcdef0123456789abcdef-fedcba9876543210-01";
    const result = parseTraceparent(header);
    try std.testing.expect(result != null);
    try std.testing.expectEqualSlices(u8, "0123456789abcdef0123456789abcdef", &result.?.trace_id);
    try std.testing.expectEqualSlices(u8, "fedcba9876543210", &result.?.span_id);
}

test "parseTraceparent invalid" {
    try std.testing.expect(parseTraceparent("invalid") == null);
    try std.testing.expect(parseTraceparent("") == null);
}

test "span toJson" {
    const allocator = std.testing.allocator;

    var span = Span.init(allocator, "test-service", "test-span");
    defer span.deinit();

    span.setKind("server");
    span.setStatus(200);
    try span.setAttribute("http.method", "GET");
    span.end();

    const json_output = try span.toJson(allocator);
    defer allocator.free(json_output);

    // Check that required fields are present
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"trace_id\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"span_id\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"namespace\":\"test-service\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"name\":\"test-span\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"kind\":\"server\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"telemetry.sdk.name\":\"imprint-zig\"") != null);
}
