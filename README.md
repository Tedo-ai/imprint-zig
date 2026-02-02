# Imprint Zig SDK

Distributed tracing SDK for Zig applications. Send traces to [Imprint](https://imprint.cloud).

## Installation

Add as a Zig dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .imprint = .{
        .url = "https://github.com/tedo-ai/imprint-zig/archive/refs/heads/main.tar.gz",
    },
},
```

Or for local development, add as a path:

```zig
.dependencies = .{
    .imprint = .{
        .path = "../imprint-zig",
    },
},
```

Then in your `build.zig`:

```zig
const imprint = b.dependency("imprint", .{
    .target = target,
    .optimize = optimize,
});
exe.addModule("imprint", imprint.module("imprint"));
```

## Quick Start

```zig
const std = @import("std");
const imprint = @import("imprint");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create client
    var client = imprint.Client.init(allocator, .{
        .api_key = std.os.getenv("IMPRINT_API_KEY") orelse "dev_key",
        .service_name = "my-service",
    });
    defer client.deinit();

    // Start a span
    var span = client.startSpan("process_request");
    span.setKind("server");
    try span.setAttribute("http.method", "GET");
    try span.setAttribute("http.route", "/api/users");

    // Do work...

    // End and record span
    span.end();
    span.setStatus(200);
    try client.recordSpan(&span);
    defer span.deinit();

    // Flush remaining spans
    try client.flush();
}
```

## Parent/Child Spans

```zig
// Start root span
var root = client.startSpan("http_request");
root.setKind("server");

// Start child span
var db_span = client.startChildSpan("database_query", &root);
db_span.setKind("client");
try db_span.setAttribute("db.system", "postgresql");

// End child
db_span.end();
try client.recordSpan(&db_span);
db_span.deinit();

// End root
root.end();
try client.recordSpan(&root);
root.deinit();
```

## Error Handling

```zig
var span = client.startSpan("risky_operation");

const result = riskyOperation() catch |err| {
    span.recordError(@errorName(err));
    span.end();
    try client.recordSpan(&span);
    span.deinit();
    return err;
};

span.end();
try client.recordSpan(&span);
span.deinit();
```

## W3C Trace Context

Generate traceparent header for outgoing requests:

```zig
var span = client.startSpan("outgoing_request");
span.setKind("client");

// Get traceparent header
const traceparent = span.traceparent();
// Use in HTTP request header

span.end();
try client.recordSpan(&span);
```

Parse incoming traceparent:

```zig
const header = request.headers.get("traceparent") orelse null;
if (header) |h| {
    if (imprint.parseTraceparent(h)) |ctx| {
        // Use ctx.trace_id and ctx.span_id for context propagation
        var span = imprint.Span.initWithParent(
            allocator,
            "my-service",
            "handler",
            ctx.trace_id,
            ctx.span_id,
        );
        // ...
    }
}
```

## Configuration

```zig
var client = imprint.Client.init(allocator, .{
    .api_key = "imp_live_...",              // Required
    .service_name = "my-service",            // Required
    .ingest_url = "https://ingest.imprint.cloud/v1/spans",  // Default
    .batch_size = 100,                       // Default: flush after 100 spans
    .flush_interval_ms = 5000,               // Default: flush every 5 seconds
});
```

## Building

```bash
# Build library
zig build

# Run tests
zig build test
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `IMPRINT_API_KEY` | API key from Imprint project | Required |
| `IMPRINT_INGEST_URL` | Ingest endpoint URL | `https://ingest.imprint.cloud/v1/spans` |

## License

MIT
