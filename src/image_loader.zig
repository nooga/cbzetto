const std = @import("std");
const rl = @cImport(@cInclude("raylib.h"));
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;
const Atomic = std.atomic.Value;

// Reference to debug mode from main.zig
// extern var debug_mode: bool; // Removed as per edit hint

fn debugPrint(debug_mode: bool, comptime fmt: []const u8, args: anytype) void {
    if (debug_mode) {
        std.debug.print(fmt, args);
    }
}

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
    slice_index: usize, // 0-based index of this slice (0 for non-sliced images)
    total_slices: usize, // Total number of slices (1 for non-sliced images)

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
    pending_pages: std.AutoHashMap(usize, void), // Track pending page requests

    pub fn init(allocator: Allocator) RequestQueue {
        return RequestQueue{
            .items = ArrayList(LoadRequest).init(allocator),
            .mutex = Mutex{},
            .condition = Condition{},
            .allocator = allocator,
            .pending_pages = std.AutoHashMap(usize, void).init(allocator),
        };
    }

    pub fn deinit(self: *RequestQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.items.items) |*request| {
            request.deinit(self.allocator);
        }
        self.items.deinit();
        self.pending_pages.deinit();
    }

    /// Add a request to the queue (sorted by priority)
    pub fn push(self: *RequestQueue, request: LoadRequest) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if we already have a pending request for this page
        if (self.pending_pages.contains(request.page_idx)) {
            // Free the duplicate request's memory
            self.allocator.free(request.image_name);
            return; // Skip duplicate request
        }

        // Mark this page as pending
        try self.pending_pages.put(request.page_idx, {});

        // Find insertion point to maintain priority order (higher priority first)
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
    pub fn waitForRequest(self: *RequestQueue, should_stop: *const Atomic(bool)) ?LoadRequest {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.items.items.len == 0 and !should_stop.load(.monotonic)) {
            self.condition.wait(&self.mutex);
        }

        // If we're stopping and no items, return null
        if (should_stop.load(.monotonic) and self.items.items.len == 0) {
            return null;
        }

        // If we have items, return the first one
        if (self.items.items.len > 0) {
            const request = self.items.orderedRemove(0);
            // Remove from pending set when we start processing
            _ = self.pending_pages.remove(request.page_idx);
            return request;
        }

        return null;
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
                // Remove from pending set when canceling
                _ = self.pending_pages.remove(request.page_idx);
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

    /// Clear a page from pending set (called when processing is complete)
    pub fn clearPending(self: *RequestQueue, page_idx: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.pending_pages.remove(page_idx);
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
    debug_mode: bool, // Added as per edit hint

    pub fn init(allocator: Allocator, cbz_files_ptr: *anyopaque, extract_fn: *const fn (*anyopaque, Allocator, []const u8, usize, usize) anyerror![]u8, debug_mode: bool) ImageLoader {
        return ImageLoader{
            .allocator = allocator,
            .request_queue = RequestQueue.init(allocator),
            .result_queue = ResultQueue.init(allocator),
            .worker_thread = null,
            .should_stop = Atomic(bool).init(false),
            .cbz_files_ptr = cbz_files_ptr,
            .extract_fn = extract_fn,
            .debug_mode = debug_mode, // Added as per edit hint
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
    debugPrint(loader.debug_mode, "Background image loader thread started\n", .{});

    while (!loader.should_stop.load(.monotonic)) {
        // Wait for a request
        const request_opt = loader.request_queue.waitForRequest(&loader.should_stop);
        if (request_opt == null) continue;

        var request = request_opt.?;
        defer request.deinit(loader.allocator);

        // Check if we should stop
        if (loader.should_stop.load(.monotonic)) break;

        // Process the request - this may generate multiple results for sliced images
        processLoadRequestWithSlicing(loader, &request);
    }

    debugPrint(loader.debug_mode, "Background image loader thread stopped\n", .{});
}

/// Process a load request, potentially generating multiple results for sliced images
fn processLoadRequestWithSlicing(loader: *ImageLoader, request: *const LoadRequest) void {
    // Extract image data using the provided function
    const image_data = loader.extract_fn(loader.cbz_files_ptr, loader.allocator, request.image_name, request.file_idx, request.local_idx) catch |err| {
        debugPrint(loader.debug_mode, "Error extracting image {s}: {}\n", .{ request.image_name, err });
        const result = LoadResult{
            .page_idx = request.page_idx,
            .width = 0,
            .height = 0,
            .format = 0,
            .pixel_data = &[_]u8{},
            .success = false,
            .slice_index = 0,
            .total_slices = 1,
        };
        loader.result_queue.push(result) catch {};
        return;
    };
    defer loader.allocator.free(image_data);

    // Detect image format
    const file_ext = if (std.mem.endsWith(u8, request.image_name, ".png")) ".png" else if (std.mem.endsWith(u8, request.image_name, ".jpeg")) ".jpeg" else ".jpg";

    // Load image from memory
    const img = rl.LoadImageFromMemory(file_ext, image_data.ptr, @intCast(image_data.len));
    defer rl.UnloadImage(img);

    if (img.data == null) {
        debugPrint(loader.debug_mode, "Failed to decode image: {s}\n", .{request.image_name});
        const result = LoadResult{
            .page_idx = request.page_idx,
            .width = 0,
            .height = 0,
            .format = 0,
            .pixel_data = &[_]u8{},
            .success = false,
            .slice_index = 0,
            .total_slices = 1,
        };
        loader.result_queue.push(result) catch {};
        return;
    }

    const max_texture_size: i32 = 2048;

    // Check if this is a very long image that should be sliced
    // We slice if: height > max_texture_size AND aspect ratio < 0.6 (height is much larger than width)
    const aspect_ratio = @as(f32, @floatFromInt(img.width)) / @as(f32, @floatFromInt(img.height));
    const should_slice = img.height > max_texture_size and aspect_ratio < 0.6;

    if (should_slice) {
        debugPrint(loader.debug_mode, "Slicing long image for page {} ({}x{}) into multiple textures\n", .{ request.page_idx, img.width, img.height });
        sliceAndPushResults(loader, request, img);
    } else {
        // Handle normally (resize if needed)
        const result = processNormalImage(loader, request, img);
        loader.result_queue.push(result) catch |err| {
            debugPrint(loader.debug_mode, "Error adding result to queue: {}\n", .{err});
        };
    }
}

/// Slice a long image into multiple textures and push results
fn sliceAndPushResults(loader: *ImageLoader, request: *const LoadRequest, img: rl.Image) void {
    const max_texture_size: i32 = 2048;
    const slice_height = max_texture_size;
    const total_slices = @as(usize, @intCast(@divTrunc((img.height + slice_height - 1), slice_height))); // Ceiling division

    var y_offset: i32 = 0;
    for (0..total_slices) |slice_idx| {
        const current_slice_height = @min(slice_height, img.height - y_offset);

        // Create a slice of the image
        const slice_rect = rl.Rectangle{
            .x = 0,
            .y = @floatFromInt(y_offset),
            .width = @floatFromInt(img.width),
            .height = @floatFromInt(current_slice_height),
        };

        const slice_img = rl.ImageFromImage(img, slice_rect);
        defer rl.UnloadImage(slice_img);

        // Calculate pixel data size for this slice
        const pixel_size: usize = switch (slice_img.format) {
            1 => 1, // PIXELFORMAT_UNCOMPRESSED_GRAYSCALE
            2 => 2, // PIXELFORMAT_UNCOMPRESSED_GRAY_ALPHA
            3 => 3, // PIXELFORMAT_UNCOMPRESSED_R8G8B8
            4 => 4, // PIXELFORMAT_UNCOMPRESSED_R8G8B8A8
            else => 4, // Default to RGBA
        };

        const data_size = @as(usize, @intCast(slice_img.width * slice_img.height)) * pixel_size;

        // Copy pixel data for this slice
        const pixel_data = loader.allocator.alloc(u8, data_size) catch |err| {
            debugPrint(loader.debug_mode, "Error allocating pixel data for slice {}: {}\n", .{ slice_idx, err });
            // Push error result for this slice
            const error_result = LoadResult{
                .page_idx = request.page_idx,
                .width = 0,
                .height = 0,
                .format = 0,
                .pixel_data = &[_]u8{},
                .success = false,
                .slice_index = slice_idx,
                .total_slices = total_slices,
            };
            loader.result_queue.push(error_result) catch {};
            y_offset += current_slice_height;
            continue;
        };

        @memcpy(pixel_data, @as([*]u8, @ptrCast(slice_img.data))[0..data_size]);

        // Create result for this slice
        const result = LoadResult{
            .page_idx = request.page_idx,
            .width = slice_img.width,
            .height = slice_img.height,
            .format = slice_img.format,
            .pixel_data = pixel_data,
            .success = true,
            .slice_index = slice_idx,
            .total_slices = total_slices,
        };

        loader.result_queue.push(result) catch |err| {
            debugPrint(loader.debug_mode, "Error adding slice result to queue: {}\n", .{err});
            // Clean up pixel data if we couldn't add to queue
            loader.allocator.free(pixel_data);
        };

        y_offset += current_slice_height;
    }

    debugPrint(loader.debug_mode, "Sliced image into {} textures\n", .{total_slices});
}

/// Process a normal image (with resizing if needed)
fn processNormalImage(loader: *ImageLoader, request: *const LoadRequest, img: rl.Image) LoadResult {
    const max_texture_size: i32 = 2048;
    var final_img = img;
    var needs_resize = false;

    if (img.width > max_texture_size or img.height > max_texture_size) {
        debugPrint(loader.debug_mode, "Background downsampling large texture for page {} from ({}x{}) ", .{ request.page_idx, img.width, img.height });

        // Calculate new dimensions maintaining aspect ratio
        const aspect_ratio = @as(f32, @floatFromInt(img.width)) / @as(f32, @floatFromInt(img.height));
        var new_width: i32 = max_texture_size;
        var new_height: i32 = max_texture_size;

        if (aspect_ratio > 1.0) {
            // Width is larger, scale height down
            new_height = @intFromFloat(@as(f32, @floatFromInt(max_texture_size)) / aspect_ratio);
        } else {
            // Height is larger, scale width down
            new_width = @intFromFloat(@as(f32, @floatFromInt(max_texture_size)) * aspect_ratio);
        }

        // Create a copy of the image to resize (since original has defer rl.UnloadImage)
        final_img = rl.ImageCopy(img);

        // Validate the copied image
        if (final_img.data == null) {
            debugPrint(loader.debug_mode, "Failed to copy image for resizing\n", .{});
            return LoadResult{
                .page_idx = request.page_idx,
                .width = 0,
                .height = 0,
                .format = 0,
                .pixel_data = &[_]u8{},
                .success = false,
                .slice_index = 0,
                .total_slices = 1,
            };
        }

        // Resize the copied image
        rl.ImageResize(&final_img, new_width, new_height);

        // Validate the resized image
        if (final_img.data == null) {
            debugPrint(loader.debug_mode, "Failed to resize image\n", .{});
            rl.UnloadImage(final_img);
            return LoadResult{
                .page_idx = request.page_idx,
                .width = 0,
                .height = 0,
                .format = 0,
                .pixel_data = &[_]u8{},
                .success = false,
                .slice_index = 0,
                .total_slices = 1,
            };
        }

        needs_resize = true;

        debugPrint(loader.debug_mode, "to ({}x{})\n", .{ new_width, new_height });
    }

    // Calculate pixel data size
    debugPrint(loader.debug_mode, "Calculating pixel data size for format: {}\n", .{final_img.format});
    const pixel_size: usize = switch (final_img.format) {
        1 => 1, // PIXELFORMAT_UNCOMPRESSED_GRAYSCALE
        2 => 2, // PIXELFORMAT_UNCOMPRESSED_GRAY_ALPHA
        3 => 3, // PIXELFORMAT_UNCOMPRESSED_R8G8B8
        4 => 4, // PIXELFORMAT_UNCOMPRESSED_R8G8B8A8
        else => 4, // Default to RGBA
    };

    const data_size = @as(usize, @intCast(final_img.width * final_img.height)) * pixel_size;
    debugPrint(loader.debug_mode, "Pixel size: {}, Data size: {}, Image dimensions: {}x{}\n", .{ pixel_size, data_size, final_img.width, final_img.height });

    // Copy pixel data
    debugPrint(loader.debug_mode, "Allocating {} bytes for pixel data\n", .{data_size});
    const pixel_data = loader.allocator.alloc(u8, data_size) catch |err| {
        debugPrint(loader.debug_mode, "Error allocating pixel data: {}\n", .{err});
        if (needs_resize) {
            rl.UnloadImage(final_img);
        }
        return LoadResult{
            .page_idx = request.page_idx,
            .width = 0,
            .height = 0,
            .format = 0,
            .pixel_data = &[_]u8{},
            .success = false,
            .slice_index = 0,
            .total_slices = 1,
        };
    };

    debugPrint(loader.debug_mode, "Successfully allocated pixel data buffer\n", .{});

    // Validate final image data before copying
    if (final_img.data == null) {
        debugPrint(loader.debug_mode, "Final image data is null, cannot copy pixel data\n", .{});
        loader.allocator.free(pixel_data);
        if (needs_resize) {
            rl.UnloadImage(final_img);
        }
        return LoadResult{
            .page_idx = request.page_idx,
            .width = 0,
            .height = 0,
            .format = 0,
            .pixel_data = &[_]u8{},
            .success = false,
            .slice_index = 0,
            .total_slices = 1,
        };
    }

    // Verify data size matches what raylib expects
    const expected_data_size = @as(usize, @intCast(rl.GetPixelDataSize(final_img.width, final_img.height, final_img.format)));
    debugPrint(loader.debug_mode, "Calculated data size: {}, raylib expected size: {}\n", .{ data_size, expected_data_size });

    if (data_size != expected_data_size) {
        debugPrint(loader.debug_mode, "Data size mismatch! Using raylib's expected size instead\n", .{});
        // Free the incorrectly sized buffer and allocate correct size
        loader.allocator.free(pixel_data);
        const correct_pixel_data = loader.allocator.alloc(u8, expected_data_size) catch |err| {
            debugPrint(loader.debug_mode, "Error reallocating correct pixel data size: {}\n", .{err});
            if (needs_resize) {
                rl.UnloadImage(final_img);
            }
            return LoadResult{
                .page_idx = request.page_idx,
                .width = 0,
                .height = 0,
                .format = 0,
                .pixel_data = &[_]u8{},
                .success = false,
                .slice_index = 0,
                .total_slices = 1,
            };
        };

        debugPrint(loader.debug_mode, "About to copy {} bytes from image data (corrected size)\n", .{expected_data_size});
        @memcpy(correct_pixel_data, @as([*]u8, @ptrCast(final_img.data))[0..expected_data_size]);
        debugPrint(loader.debug_mode, "Successfully copied pixel data\n", .{});

        // Clean up resized image if needed
        if (needs_resize) {
            rl.UnloadImage(final_img);
        }

        return LoadResult{
            .page_idx = request.page_idx,
            .width = final_img.width,
            .height = final_img.height,
            .format = final_img.format,
            .pixel_data = correct_pixel_data,
            .success = true,
            .slice_index = 0,
            .total_slices = 1,
        };
    }

    debugPrint(loader.debug_mode, "About to copy {} bytes from image data\n", .{data_size});
    @memcpy(pixel_data, @as([*]u8, @ptrCast(final_img.data))[0..data_size]);
    debugPrint(loader.debug_mode, "Successfully copied pixel data\n", .{});

    // Clean up resized image if needed
    if (needs_resize) {
        rl.UnloadImage(final_img);
    }

    return LoadResult{
        .page_idx = request.page_idx,
        .width = final_img.width,
        .height = final_img.height,
        .format = final_img.format,
        .pixel_data = pixel_data,
        .success = true,
        .slice_index = 0,
        .total_slices = 1,
    };
}

/// Process a single load request (extract and decode image)
fn processLoadRequest(loader: *ImageLoader, request: *const LoadRequest) LoadResult {
    // Extract image data using the provided function
    const image_data = loader.extract_fn(loader.cbz_files_ptr, loader.allocator, request.image_name, request.file_idx, request.local_idx) catch |err| {
        debugPrint(loader.debug_mode, "Error extracting image {s}: {}\n", .{ request.image_name, err });
        return LoadResult{
            .page_idx = request.page_idx,
            .width = 0,
            .height = 0,
            .format = 0,
            .pixel_data = &[_]u8{},
            .success = false,
            .slice_index = 0,
            .total_slices = 1,
        };
    };
    defer loader.allocator.free(image_data);

    // Detect image format
    const file_ext = if (std.mem.endsWith(u8, request.image_name, ".png")) ".png" else if (std.mem.endsWith(u8, request.image_name, ".jpeg")) ".jpeg" else ".jpg";

    // Load image from memory (this is the heavy operation we're moving to background)
    const img = rl.LoadImageFromMemory(file_ext, image_data.ptr, @intCast(image_data.len));
    defer rl.UnloadImage(img);

    if (img.data == null) {
        debugPrint(loader.debug_mode, "Failed to decode image: {s}\n", .{request.image_name});
        return LoadResult{
            .page_idx = request.page_idx,
            .width = 0,
            .height = 0,
            .format = 0,
            .pixel_data = &[_]u8{},
            .success = false,
            .slice_index = 0,
            .total_slices = 1,
        };
    }

    // Check for large textures and downsample if needed
    const max_texture_size: i32 = 2048;
    var final_img = img;
    var needs_resize = false;

    if (img.width > max_texture_size or img.height > max_texture_size) {
        debugPrint(loader.debug_mode, "Background downsampling large texture for page {} from ({}x{}) ", .{ request.page_idx, img.width, img.height });

        // Calculate new dimensions maintaining aspect ratio
        const aspect_ratio = @as(f32, @floatFromInt(img.width)) / @as(f32, @floatFromInt(img.height));
        var new_width: i32 = max_texture_size;
        var new_height: i32 = max_texture_size;

        if (aspect_ratio > 1.0) {
            // Width is larger, scale height down
            new_height = @intFromFloat(@as(f32, @floatFromInt(max_texture_size)) / aspect_ratio);
        } else {
            // Height is larger, scale width down
            new_width = @intFromFloat(@as(f32, @floatFromInt(max_texture_size)) * aspect_ratio);
        }

        // Create a copy of the image to resize (since original has defer rl.UnloadImage)
        final_img = rl.ImageCopy(img);
        rl.ImageResize(&final_img, new_width, new_height);
        needs_resize = true;

        debugPrint(loader.debug_mode, "to ({}x{})\n", .{ new_width, new_height });
    }

    // Calculate pixel data size
    const pixel_size: usize = switch (final_img.format) {
        1 => 1, // PIXELFORMAT_UNCOMPRESSED_GRAYSCALE
        2 => 2, // PIXELFORMAT_UNCOMPRESSED_GRAY_ALPHA
        3 => 3, // PIXELFORMAT_UNCOMPRESSED_R8G8B8
        4 => 4, // PIXELFORMAT_UNCOMPRESSED_R8G8B8A8
        else => 4, // Default to RGBA
    };

    const data_size = @as(usize, @intCast(final_img.width * final_img.height)) * pixel_size;

    // Copy pixel data
    const pixel_data = loader.allocator.alloc(u8, data_size) catch |err| {
        debugPrint(loader.debug_mode, "Error allocating pixel data: {}\n", .{err});
        if (needs_resize) {
            rl.UnloadImage(final_img);
        }
        return LoadResult{
            .page_idx = request.page_idx,
            .width = 0,
            .height = 0,
            .format = 0,
            .pixel_data = &[_]u8{},
            .success = false,
            .slice_index = 0,
            .total_slices = 1,
        };
    };

    @memcpy(pixel_data, @as([*]u8, @ptrCast(final_img.data))[0..data_size]);

    // Clean up resized image if needed
    if (needs_resize) {
        rl.UnloadImage(final_img);
    }

    return LoadResult{
        .page_idx = request.page_idx,
        .width = final_img.width,
        .height = final_img.height,
        .format = final_img.format,
        .pixel_data = pixel_data,
        .success = true,
        .slice_index = 0, // Default to 0 for non-sliced images
        .total_slices = 1, // Default to 1 for non-sliced images
    };
}
