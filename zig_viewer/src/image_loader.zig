const std = @import("std");
const rl = @cImport(@cInclude("raylib.h"));
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;
const Atomic = std.atomic.Value;

/// Request for background image loading
pub const LoadRequest = struct {
    page_idx: usize,
    file_idx: usize,
    local_idx: usize,
    image_name: []const u8,
    priority: i32, // Higher = more urgent (visible pages)

    pub fn deinit(self: *LoadRequest, allocator: Allocator) void {
        allocator.free(self.image_name);
    }
};

/// Result of background image loading
pub const LoadResult = struct {
    page_idx: usize,
    width: i32,
    height: i32,
    format: i32, // raylib pixel format
    pixel_data: []u8,
    success: bool,

    pub fn deinit(self: *LoadResult, allocator: Allocator) void {
        if (self.pixel_data.len > 0) {
            allocator.free(self.pixel_data);
        }
    }
};

/// Thread-safe queue for load requests
const RequestQueue = struct {
    items: ArrayList(LoadRequest),
    mutex: Mutex,
    condition: Condition,
    allocator: Allocator,

    pub fn init(allocator: Allocator) RequestQueue {
        return RequestQueue{
            .items = ArrayList(LoadRequest).init(allocator),
            .mutex = Mutex{},
            .condition = Condition{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RequestQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up any remaining requests
        for (self.items.items) |*request| {
            request.deinit(self.allocator);
        }
        self.items.deinit();
    }

    /// Add a request to the queue (higher priority items go first)
    pub fn push(self: *RequestQueue, request: LoadRequest) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Insert in priority order (higher priority first)
        var insert_idx: usize = 0;
        for (self.items.items, 0..) |item, i| {
            if (request.priority > item.priority) {
                insert_idx = i;
                break;
            }
            insert_idx = i + 1;
        }

        try self.items.insert(insert_idx, request);
        self.condition.signal();
    }

    /// Wait for a request to become available
    pub fn waitForRequest(self: *RequestQueue) ?LoadRequest {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.items.items.len == 0) {
            self.condition.wait(&self.mutex);
        }

        return self.items.orderedRemove(0);
    }

    /// Cancel loading requests for pages outside the given range
    pub fn cancelOutsideRange(self: *RequestQueue, start_page: usize, end_page: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.items.items.len) {
            const page_idx = self.items.items[i].page_idx;
            if (page_idx < start_page or page_idx > end_page) {
                var request = self.items.orderedRemove(i);
                request.deinit(self.allocator);
            } else {
                i += 1;
            }
        }
    }

    /// Get current queue size
    pub fn size(self: *RequestQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.items.items.len;
    }
};

/// Thread-safe queue for load results
const ResultQueue = struct {
    items: ArrayList(LoadResult),
    mutex: Mutex,
    allocator: Allocator,

    pub fn init(allocator: Allocator) ResultQueue {
        return ResultQueue{
            .items = ArrayList(LoadResult).init(allocator),
            .mutex = Mutex{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ResultQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up any remaining results
        for (self.items.items) |*result| {
            result.deinit(self.allocator);
        }
        self.items.deinit();
    }

    /// Add a result to the queue
    pub fn push(self: *ResultQueue, result: LoadResult) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(result);
    }

    /// Remove and return the oldest result, or null if empty
    pub fn pop(self: *ResultQueue) ?LoadResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.items.items.len == 0) {
            return null;
        }

        return self.items.orderedRemove(0);
    }

    /// Get current queue size
    pub fn size(self: *ResultQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.items.items.len;
    }
};

/// Background image loader system
pub const ImageLoader = struct {
    allocator: Allocator,
    request_queue: RequestQueue,
    result_queue: ResultQueue,
    worker_thread: ?Thread,
    should_stop: Atomic(bool),
    cbz_files_ptr: *anyopaque, // Opaque pointer to avoid circular imports
    extract_fn: *const fn (*anyopaque, Allocator, []const u8, usize, usize) anyerror![]u8,

    pub fn init(allocator: Allocator, cbz_files_ptr: *anyopaque, extract_fn: *const fn (*anyopaque, Allocator, []const u8, usize, usize) anyerror![]u8) ImageLoader {
        return ImageLoader{
            .allocator = allocator,
            .request_queue = RequestQueue.init(allocator),
            .result_queue = ResultQueue.init(allocator),
            .worker_thread = null,
            .should_stop = Atomic(bool).init(false),
            .cbz_files_ptr = cbz_files_ptr,
            .extract_fn = extract_fn,
        };
    }

    pub fn deinit(self: *ImageLoader) void {
        self.stop();
        self.request_queue.deinit();
        self.result_queue.deinit();
    }

    /// Start the background worker thread
    pub fn start(self: *ImageLoader) !void {
        if (self.worker_thread != null) return; // Already started

        self.should_stop.store(false, .monotonic);
        self.worker_thread = try Thread.spawn(.{}, workerThread, .{self});
    }

    /// Stop the background worker thread
    pub fn stop(self: *ImageLoader) void {
        if (self.worker_thread == null) return; // Not started

        self.should_stop.store(true, .monotonic);

        // Wake up the worker thread if it's waiting
        self.request_queue.condition.signal();

        // Wait for worker thread to finish
        self.worker_thread.?.join();
        self.worker_thread = null;
    }

    /// Request loading of a page image
    pub fn requestLoad(self: *ImageLoader, page_idx: usize, file_idx: usize, local_idx: usize, image_name: []const u8, priority: i32) !void {
        const name_copy = try self.allocator.dupe(u8, image_name);

        const request = LoadRequest{
            .page_idx = page_idx,
            .file_idx = file_idx,
            .local_idx = local_idx,
            .image_name = name_copy,
            .priority = priority,
        };

        try self.request_queue.push(request);
    }

    /// Get next loaded result (call from main thread)
    pub fn getResult(self: *ImageLoader) ?LoadResult {
        return self.result_queue.pop();
    }

    /// Cancel loading requests for pages outside the given range
    pub fn cancelOutsideRange(self: *ImageLoader, start_page: usize, end_page: usize) void {
        self.request_queue.cancelOutsideRange(start_page, end_page);
    }

    /// Get queue sizes for debugging
    pub fn getQueueSizes(self: *ImageLoader) struct { requests: usize, results: usize } {
        return .{
            .requests = self.request_queue.size(),
            .results = self.result_queue.size(),
        };
    }
};

/// Worker thread function
fn workerThread(loader: *ImageLoader) void {
    std.debug.print("Background image loader thread started\n", .{});

    while (!loader.should_stop.load(.monotonic)) {
        // Wait for a request
        const request_opt = loader.request_queue.waitForRequest();
        if (request_opt == null) continue;

        var request = request_opt.?;
        defer request.deinit(loader.allocator);

        // Check if we should stop
        if (loader.should_stop.load(.monotonic)) break;

        // Process the request
        const result = processLoadRequest(loader, &request);

        // Add result to queue
        loader.result_queue.push(result) catch |err| {
            std.debug.print("Error adding result to queue: {}\n", .{err});
        };
    }

    std.debug.print("Background image loader thread stopped\n", .{});
}

/// Process a single load request (extract and decode image)
fn processLoadRequest(loader: *ImageLoader, request: *const LoadRequest) LoadResult {
    // Extract image data using the provided function
    const image_data = loader.extract_fn(loader.cbz_files_ptr, loader.allocator, request.image_name, request.file_idx, request.local_idx) catch |err| {
        std.debug.print("Error extracting image {s}: {}\n", .{ request.image_name, err });
        return LoadResult{
            .page_idx = request.page_idx,
            .width = 0,
            .height = 0,
            .format = 0,
            .pixel_data = &[_]u8{},
            .success = false,
        };
    };
    defer loader.allocator.free(image_data);

    // Detect image format
    const file_ext = if (std.mem.endsWith(u8, request.image_name, ".png")) ".png" else if (std.mem.endsWith(u8, request.image_name, ".jpeg")) ".jpeg" else ".jpg";

    // Load image from memory (this is the heavy operation we're moving to background)
    const img = rl.LoadImageFromMemory(file_ext, image_data.ptr, @intCast(image_data.len));
    defer rl.UnloadImage(img);

    if (img.data == null) {
        std.debug.print("Failed to decode image: {s}\n", .{request.image_name});
        return LoadResult{
            .page_idx = request.page_idx,
            .width = 0,
            .height = 0,
            .format = 0,
            .pixel_data = &[_]u8{},
            .success = false,
        };
    }

    // Calculate pixel data size
    const pixel_size: usize = switch (img.format) {
        1 => 1, // PIXELFORMAT_UNCOMPRESSED_GRAYSCALE
        2 => 2, // PIXELFORMAT_UNCOMPRESSED_GRAY_ALPHA
        3 => 3, // PIXELFORMAT_UNCOMPRESSED_R8G8B8
        4 => 4, // PIXELFORMAT_UNCOMPRESSED_R8G8B8A8
        else => 4, // Default to RGBA
    };

    const data_size = @as(usize, @intCast(img.width * img.height)) * pixel_size;

    // Copy pixel data
    const pixel_data = loader.allocator.alloc(u8, data_size) catch |err| {
        std.debug.print("Error allocating pixel data: {}\n", .{err});
        return LoadResult{
            .page_idx = request.page_idx,
            .width = 0,
            .height = 0,
            .format = 0,
            .pixel_data = &[_]u8{},
            .success = false,
        };
    };

    @memcpy(pixel_data, @as([*]u8, @ptrCast(img.data))[0..data_size]);

    return LoadResult{
        .page_idx = request.page_idx,
        .width = img.width,
        .height = img.height,
        .format = img.format,
        .pixel_data = pixel_data,
        .success = true,
    };
}
