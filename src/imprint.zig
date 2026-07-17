const std = @import("std");
const http = std.http;
const json = std.json;

const log = std.log.scoped(.imprint);

// SDK metadata
pub const sdk_name = "imprint-zig";
pub const sdk_version = "0.1.1";
pub const sdk_language = "zig";

/// Configuration for the Imprint client.
pub const Config = struct {
    api_key: []const u8,
    service_name: []const u8,
    ingest_url: []const u8 = "https://ingest.imprint.cloud/v1/spans",
    batch_size: usize = 100,
    flush_interval_ms: u64 = 5000, // Auto-flush after this many ms
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
        const elapsed = end_time - self.start_time;
        self.duration_ns = if (elapsed > 0 and elapsed <= std.math.maxInt(u64))
            @intCast(elapsed)
        else
            0;
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

        try list.appendSlice("{\"trace_id\":");
        try appendJsonString(&list, self.trace_id[0..]);
        try list.appendSlice(",\"span_id\":");
        try appendJsonString(&list, self.span_id[0..]);

        if (self.parent_id) |pid| {
            try list.appendSlice(",\"parent_id\":");
            try appendJsonString(&list, pid[0..]);
        }

        try list.appendSlice(",\"namespace\":");
        try appendJsonString(&list, self.namespace);
        try list.appendSlice(",\"name\":");
        try appendJsonString(&list, self.name);
        try list.appendSlice(",\"kind\":");
        try appendJsonString(&list, self.kind);

        try list.appendSlice(",\"start_time\":");
        try appendRfc3339Nano(&list, self.start_time);
        try list.writer().print(
            ",\"duration_ns\":{d},\"status_code\":{d}",
            .{ self.duration_ns, self.status_code },
        );

        if (self.error_data) |err| {
            try list.appendSlice(",\"error_data\":");
            try appendJsonString(&list, err);
        }

        try list.appendSlice(",\"attributes\":{");
        try appendJsonString(&list, "telemetry.sdk.name");
        try list.append(':');
        try appendJsonString(&list, sdk_name);
        try list.append(',');
        try appendJsonString(&list, "telemetry.sdk.version");
        try list.append(':');
        try appendJsonString(&list, sdk_version);
        try list.append(',');
        try appendJsonString(&list, "telemetry.sdk.language");
        try list.append(':');
        try appendJsonString(&list, sdk_language);

        var attr_iter = self.attributes.iterator();
        while (attr_iter.next()) |entry| {
            if (isSdkAttribute(entry.key_ptr.*)) continue;
            try list.append(',');
            try appendJsonString(&list, entry.key_ptr.*);
            try list.append(':');
            try appendJsonString(&list, entry.value_ptr.*);
        }

        try list.appendSlice("}}");

        return list.toOwnedSlice();
    }
};

fn appendJsonString(list: *std.ArrayList(u8), value: []const u8) !void {
    try json.stringify(value, .{}, list.writer());
}

fn isSdkAttribute(key: []const u8) bool {
    return std.mem.eql(u8, key, "telemetry.sdk.name") or
        std.mem.eql(u8, key, "telemetry.sdk.version") or
        std.mem.eql(u8, key, "telemetry.sdk.language");
}

fn appendRfc3339Nano(list: *std.ArrayList(u8), unix_nanoseconds: i128) !void {
    if (unix_nanoseconds < 0) return error.TimestampOutOfRange;

    const nanoseconds_per_second: i128 = std.time.ns_per_s;
    const seconds_wide = @divFloor(unix_nanoseconds, nanoseconds_per_second);
    if (seconds_wide > std.math.maxInt(i64)) return error.TimestampOutOfRange;

    const seconds: i64 = @intCast(seconds_wide);
    const nanoseconds: u32 = @intCast(@mod(unix_nanoseconds, nanoseconds_per_second));
    const days = @divFloor(seconds, std.time.s_per_day);
    const second_of_day: u32 = @intCast(@mod(seconds, std.time.s_per_day));
    const date = civilDateFromUnixDays(days);
    if (date.year < 0 or date.year > 9999) return error.TimestampOutOfRange;

    const year: u32 = @intCast(date.year);
    const hour = second_of_day / std.time.s_per_hour;
    const minute = (second_of_day % std.time.s_per_hour) / std.time.s_per_min;
    const second = second_of_day % std.time.s_per_min;
    try list.writer().print(
        "\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}Z\"",
        .{ year, date.month, date.day, hour, minute, second, nanoseconds },
    );
}

const CivilDate = struct {
    year: i64,
    month: u32,
    day: u32,
};

// Howard Hinnant's civil-from-days algorithm. The input is days since the
// Unix epoch and the output is the corresponding proleptic Gregorian date.
fn civilDateFromUnixDays(unix_days: i64) CivilDate {
    const shifted = unix_days + 719_468;
    const era = @divFloor(shifted, 146_097);
    const day_of_era = shifted - era * 146_097;
    const year_of_era = @divFloor(
        day_of_era - @divFloor(day_of_era, 1_460) +
            @divFloor(day_of_era, 36_524) -
            @divFloor(day_of_era, 146_096),
        365,
    );
    var year = year_of_era + era * 400;
    const day_of_year = day_of_era -
        (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_prime = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * month_prime + 2, 5) + 1;
    const month = month_prime + if (month_prime < 10) @as(i64, 3) else -9;
    year += if (month <= 2) 1 else 0;

    return .{
        .year = year,
        .month = @intCast(month),
        .day = @intCast(day),
    };
}

/// Imprint client for sending spans.
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    buffer: std.ArrayList([]u8), // Store serialized JSON, not pointers
    mutex: std.Thread.Mutex,
    last_flush_time: i64, // milliseconds since epoch

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: Config) Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .buffer = std.ArrayList([]u8).init(allocator),
            .mutex = .{},
            .last_flush_time = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *Self) void {
        // Flush remaining spans
        self.flush() catch {};
        // Free any remaining serialized spans
        for (self.buffer.items) |span_data| {
            self.allocator.free(span_data);
        }
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
        // Serialize span immediately to avoid use-after-free
        const span_json = try span.toJson(self.allocator);

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.buffer.append(span_json);

        const now = std.time.milliTimestamp();
        const time_since_flush: u64 = @intCast(@max(0, now - self.last_flush_time));

        // Flush if batch size reached OR flush interval elapsed
        if (self.buffer.items.len >= self.config.batch_size or
            time_since_flush >= self.config.flush_interval_ms)
        {
            try self.flushLocked();
            self.last_flush_time = now;
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

        const span_count = self.buffer.items.len;

        // Build JSON array from pre-serialized spans
        var payload = std.ArrayList(u8).init(self.allocator);
        defer payload.deinit();

        try payload.append('[');
        for (self.buffer.items, 0..) |span_json, i| {
            if (i > 0) try payload.append(',');
            try payload.appendSlice(span_json);
        }
        try payload.append(']');

        // Send to ingest
        self.sendBatch(payload.items, span_count) catch |err| {
            log.err("Failed to send spans: {}", .{err});
        };

        // Free serialized JSON and clear buffer
        for (self.buffer.items) |span_data| {
            self.allocator.free(span_data);
        }
        self.buffer.clearRetainingCapacity();
    }

    fn sendBatch(self: *Self, payload: []const u8, span_count: usize) !void {
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

        log.info("Sent batch of {d} spans", .{span_count});
    }
};

/// Parent identifiers extracted from a W3C traceparent header.
pub const TraceContext = struct {
    trace_id: [32]u8,
    span_id: [16]u8,
};

/// Parse W3C traceparent header.
pub fn parseTraceparent(header: []const u8) ?TraceContext {
    if (header.len != 55) return null;
    if (!std.mem.startsWith(u8, header, "00-")) return null;
    if (header[35] != '-' or header[52] != '-') return null;

    var result: TraceContext = undefined;
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
    try std.testing.expect(std.mem.indexOf(u8, json_output, "\"start_time\":\"") != null);
}

test "span JSON matches the v1 timestamp and escaping contract" {
    const allocator = std.testing.allocator;

    var span = Span.init(allocator, "worker\"service", "artifact\ntrace");
    defer span.deinit();
    span.start_time = 951_782_400_123_456_789;
    span.duration_ns = 42;
    span.recordError("bad\tinput");
    try span.setAttribute("quoted\"key", "line\nvalue");
    try span.setAttribute("telemetry.sdk.version", "spoofed");

    const json_output = try span.toJson(allocator);
    defer allocator.free(json_output);

    const Parsed = struct {
        start_time: []const u8,
        namespace: []const u8,
        name: []const u8,
        error_data: []const u8,
        duration_ns: u64,
        attributes: std.json.ArrayHashMap([]const u8),
    };
    const parsed = try json.parseFromSlice(Parsed, allocator, json_output, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings(
        "2000-02-29T00:00:00.123456789Z",
        parsed.value.start_time,
    );
    try std.testing.expectEqualStrings("worker\"service", parsed.value.namespace);
    try std.testing.expectEqualStrings("artifact\ntrace", parsed.value.name);
    try std.testing.expectEqualStrings("bad\tinput", parsed.value.error_data);
    try std.testing.expectEqual(@as(u64, 42), parsed.value.duration_ns);
    try std.testing.expectEqualStrings(
        "line\nvalue",
        parsed.value.attributes.map.get("quoted\"key").?,
    );
    try std.testing.expectEqualStrings(
        sdk_version,
        parsed.value.attributes.map.get("telemetry.sdk.version").?,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, json_output, "\"telemetry.sdk.version\""),
    );
}

test "RFC3339 conversion covers the Unix epoch" {
    const allocator = std.testing.allocator;
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    try appendRfc3339Nano(&output, 0);
    try std.testing.expectEqualStrings(
        "\"1970-01-01T00:00:00.000000000Z\"",
        output.items,
    );
}
