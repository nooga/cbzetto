const std = @import("std");
const rl = @cImport(@cInclude("raylib.h"));
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const embedded_font = @import("embedded_font.zig");
const image_loader = @import("image_loader.zig");
const json = std.json;
const posix = std.posix;
const macos_wrapper = @import("macos_wrapper.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

const PageSize = struct { width: i32, height: i32 };

pub const CBZFile = struct {
    file: std.fs.File,
    images: ArrayList([]const u8),
    page_sizes: ArrayList(PageSize),
    file_name: []const u8,

    fn deinit(self: *CBZFile) void {
        self.file.close();
        for (self.images.items) |img_name| {
            allocator.free(img_name);
        }
        self.images.deinit();
        self.page_sizes.deinit();
        allocator.free(self.file_name);
    }
};

const PageInfo = struct {
    file_idx: usize,
    local_idx: usize,
    texture: rl.Texture2D,
    loaded: bool,
    loading_in_progress: bool,
    height: f32,
};

var cbz_files: ArrayList(CBZFile) = undefined;
var pages: ArrayList(PageInfo) = undefined;
var file_page_starts: ArrayList(usize) = undefined;
var cumulative_heights: ArrayList(f32) = undefined;
var total_height: f32 = 0.0;
var total_pages: usize = 0;
var camera: rl.Camera2D = undefined;
var current_scroll: f32 = 0.0;
var last_scroll: f32 = -1.0; // Track last scroll position to avoid unnecessary updates
var zoom_level: f32 = 1.0; // Current zoom level
var folder_path: ?[]const u8 = null;
var ui_font: rl.Font = undefined;
var force_render_frames: u32 = 0; // Force rendering for initial frames after state restoration
var needs_render: bool = true; // Track when rendering is actually needed
var show_help: bool = false; // Show keyboard shortcuts help
var bg_image_loader: image_loader.ImageLoader = undefined;
var bg_process_counter: u32 = 0; // Throttling counter for background processing
var debug_mode: bool = false; // Enable debug output when -d flag is used
var loaded_texture_count: u32 = 0; // Track number of loaded textures
const max_loaded_textures: u32 = 50; // Limit to prevent GPU memory issues
var background_is_white: bool = false; // Toggle between black and white background

// Dynamic FPS system for power efficiency
var activity_detected: bool = false;
var last_activity_time: f64 = 0.0;
var current_fps: i32 = 60;
const active_fps: i32 = 60;
const idle_fps: i32 = 10;
const activity_timeout: f64 = 2.0; // Seconds of inactivity before dropping FPS (increased)
var needs_redraw: bool = true; // Track if we need to redraw the screen
var last_fps_change: f64 = 0.0; // Prevent rapid FPS switching

fn debugPrint(comptime fmt: []const u8, args: anytype) void {
    if (debug_mode) {
        std.debug.print(fmt, args);
    }
}

// Mark that user activity has been detected
fn markActivity() void {
    activity_detected = true;
    last_activity_time = rl.GetTime();
    needs_redraw = true;
}

// Update FPS based on activity state
fn updateDynamicFPS() void {
    const current_time = rl.GetTime();
    const time_since_activity = current_time - last_activity_time;
    const time_since_fps_change = current_time - last_fps_change;

    // Throttle FPS changes to prevent rapid switching
    const fps_change_cooldown = 0.5; // Half second between FPS changes

    // Check if we should drop to idle FPS
    if (activity_detected and time_since_activity > activity_timeout and time_since_fps_change > fps_change_cooldown) {
        activity_detected = false;
        if (current_fps != idle_fps) {
            current_fps = idle_fps;
            rl.SetTargetFPS(current_fps);
            last_fps_change = current_time;
            needs_redraw = true; // Ensure we render one final frame at idle FPS
            debugPrint("Switching to idle FPS: {}\n", .{idle_fps});
            // Save state when going idle to preserve reading progress
            saveState();
        }
    }

    // Check if we should raise to active FPS - NO cooldown for ramp-up to ensure instant response
    if (activity_detected and current_fps != active_fps) {
        current_fps = active_fps;
        rl.SetTargetFPS(current_fps);
        last_fps_change = current_time;
        needs_redraw = true; // Ensure we render when returning to active FPS
        debugPrint("Switching to active FPS: {}\n", .{active_fps});
    }
}

// Check for any input activity and mark it
fn detectInputActivity() void {
    // Check for mouse activity
    if (rl.GetMouseWheelMove() != 0) {
        markActivity();
        return; // Exit early to avoid redundant checks
    }

    // Check for window resize
    if (rl.IsWindowResized()) {
        markActivity();
        return;
    }

    // Check for ongoing texture loading
    if (force_render_frames > 0) {
        markActivity();
        return;
    }

    // Simplified keyboard check - only major navigation keys
    if (rl.IsKeyPressed(rl.KEY_UP) or rl.IsKeyPressed(rl.KEY_DOWN) or
        rl.IsKeyPressed(rl.KEY_PAGE_UP) or rl.IsKeyPressed(rl.KEY_PAGE_DOWN))
    {
        markActivity();
        return;
    }
}

fn signalHandler(sig: i32) callconv(.C) void {
    debugPrint("Received signal {d}, saving state...\n", .{sig});
    saveState();
    std.process.exit(0);
}

const StateData = struct {
    scroll_pos: f32, // Keep for backward compatibility
    page_number: ?usize = null, // 0-based page index
    page_progress: ?f32 = null, // 0.0 to 1.0 progress through the page
    zoom_level: ?f32 = null, // Current zoom level
    window_width: ?i32 = null, // Window width
    window_height: ?i32 = null, // Window height
    window_x: ?i32 = null, // Window X position
    window_y: ?i32 = null, // Window Y position
    background_is_white: ?bool = null, // Background color toggle state
};

fn saveState() void {
    if (folder_path == null) return;

    const state_path = std.fmt.allocPrint(allocator, "{s}/.cbzviewer_state.json", .{folder_path.?}) catch return;
    defer allocator.free(state_path);

    // Calculate current page and progress within that page
    var current_page: usize = 0;
    var page_progress: f32 = 0.0;

    if (cumulative_heights.items.len > 0) {
        // Find which page we're currently viewing
        for (cumulative_heights.items, 0..) |cum_height, i| {
            if (cum_height > current_scroll) {
                current_page = i;
                if (i > 0) {
                    const page_start = cumulative_heights.items[i - 1];
                    const page_height = cum_height - page_start;
                    if (page_height > 0) {
                        page_progress = (current_scroll - page_start) / page_height;
                    }
                }
                break;
            }
        }
    }

    const state = StateData{
        .scroll_pos = current_scroll, // Keep for backward compatibility
        .page_number = current_page,
        .page_progress = page_progress,
        .zoom_level = zoom_level,
        .window_width = rl.GetScreenWidth(),
        .window_height = rl.GetScreenHeight(),
        .window_x = @as(i32, @intFromFloat(rl.GetWindowPosition().x)),
        .window_y = @as(i32, @intFromFloat(rl.GetWindowPosition().y)),
        .background_is_white = background_is_white,
    };

    const file = std.fs.cwd().createFile(state_path, .{}) catch |err| {
        debugPrint("Error creating state file: {}\n", .{err});
        return;
    };
    defer file.close();

    const writer = file.writer();
    json.stringify(state, .{}, writer) catch |err| {
        debugPrint("Error writing state: {}\n", .{err});
        return;
    };

    debugPrint("Saved state: page {d}, progress {d:.2}, zoom {d:.2}, window {}x{} at ({},{})\n", .{ current_page, page_progress, zoom_level, rl.GetScreenWidth(), rl.GetScreenHeight(), @as(i32, @intFromFloat(rl.GetWindowPosition().x)), @as(i32, @intFromFloat(rl.GetWindowPosition().y)) });
}

fn loadState() void {
    if (folder_path == null) return;

    const state_path = std.fmt.allocPrint(allocator, "{s}/.cbzviewer_state.json", .{folder_path.?}) catch return;
    defer allocator.free(state_path);

    const file = std.fs.cwd().openFile(state_path, .{}) catch {
        // File doesn't exist, that's okay
        return;
    };
    defer file.close();

    const file_size = file.getEndPos() catch return;
    const contents = allocator.alloc(u8, file_size) catch return;
    defer allocator.free(contents);

    _ = file.readAll(contents) catch return;

    const parsed = json.parseFromSlice(StateData, allocator, contents, .{}) catch |err| {
        debugPrint("Error parsing state file: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    // Use page-based restoration if available (new format)
    if (parsed.value.page_number != null and parsed.value.page_progress != null) {
        const page_num = parsed.value.page_number.?;
        const progress = parsed.value.page_progress.?;

        // Ensure page number is valid
        if (page_num < cumulative_heights.items.len) {
            const page_start = if (page_num == 0) 0.0 else cumulative_heights.items[page_num - 1];
            const page_end = cumulative_heights.items[page_num];
            const page_height = page_end - page_start;

            current_scroll = page_start + (progress * page_height);
            debugPrint("Restored state: page {d}, progress {d:.2} -> scroll {d}\n", .{ page_num, progress, current_scroll });
        } else {
            debugPrint("Invalid page number {d}, falling back to absolute position\n", .{page_num});
            current_scroll = parsed.value.scroll_pos;
        }
    } else {
        // Fallback to old absolute position method
        current_scroll = parsed.value.scroll_pos;
        debugPrint("Restored scroll position (legacy): {d}\n", .{current_scroll});
    }

    // Restore zoom level if available
    if (parsed.value.zoom_level != null) {
        zoom_level = parsed.value.zoom_level.?;
        // Clamp zoom to valid range
        const min_zoom: f32 = 0.1;
        const max_zoom: f32 = 5.0;
        zoom_level = std.math.clamp(zoom_level, min_zoom, max_zoom);
        debugPrint("Restored zoom level: {d:.2}\n", .{zoom_level});
    }

    // Restore background color if available
    if (parsed.value.background_is_white != null) {
        background_is_white = parsed.value.background_is_white.?;
        debugPrint("Restored background color: {s}\n", .{if (background_is_white) "white" else "black"});
    }

    // Clamp to valid range
    const max_scroll = @max(0.0, total_height - @as(f32, @floatFromInt(rl.GetScreenHeight())));
    current_scroll = std.math.clamp(current_scroll, 0.0, max_scroll);
}

fn restoreWindowProperties() void {
    if (folder_path == null) return;

    const state_path = std.fmt.allocPrint(allocator, "{s}/.cbzviewer_state.json", .{folder_path.?}) catch return;
    defer allocator.free(state_path);

    const file = std.fs.cwd().openFile(state_path, .{}) catch {
        // File doesn't exist, that's okay
        debugPrint("No state file found, using default window properties\n", .{});
        return;
    };
    defer file.close();

    const file_size = file.getEndPos() catch return;
    const contents = allocator.alloc(u8, file_size) catch return;
    defer allocator.free(contents);

    _ = file.readAll(contents) catch return;

    const parsed = json.parseFromSlice(StateData, allocator, contents, .{}) catch |err| {
        debugPrint("Error parsing state file for window properties: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    debugPrint("Restoring window properties from state file\n", .{});
    debugPrint("Current window size: {}x{}\n", .{ rl.GetScreenWidth(), rl.GetScreenHeight() });
    debugPrint("Current window position: {}, {}\n", .{ @as(i32, @intFromFloat(rl.GetWindowPosition().x)), @as(i32, @intFromFloat(rl.GetWindowPosition().y)) });

    var size_restored = false;
    var position_restored = false;

    // Restore window size if available
    if (parsed.value.window_width != null and parsed.value.window_height != null) {
        const width = parsed.value.window_width.?;
        const height = parsed.value.window_height.?;

        debugPrint("State file window size: {}x{}\n", .{ width, height });

        // Validate window size (more permissive ranges)
        if (width >= 300 and height >= 200 and width <= 5120 and height <= 2880) {
            // Check if current size is different from desired size
            if (rl.GetScreenWidth() != width or rl.GetScreenHeight() != height) {
                debugPrint("Setting window size to: {}x{}\n", .{ width, height });
                rl.SetWindowSize(width, height);
                size_restored = true;

                // Wait for size change to take effect
                std.time.sleep(50 * std.time.ns_per_ms); // 50ms delay for size
            } else {
                debugPrint("Window size already matches saved state\n", .{});
            }
        } else {
            debugPrint("Window size validation failed: {}x{} (out of range)\n", .{ width, height });
        }
    } else {
        debugPrint("No window size data in state file\n", .{});
    }

    // Restore window position if available
    if (parsed.value.window_x != null and parsed.value.window_y != null) {
        const x = parsed.value.window_x.?;
        const y = parsed.value.window_y.?;

        debugPrint("State file window position: {}, {}\n", .{ x, y });

        // Very permissive position validation for multi-monitor setups
        // Allow wide ranges to accommodate various monitor configurations
        if (x >= -5120 and y >= -200 and x <= 10240 and y <= 5760) {
            const current_x = @as(i32, @intFromFloat(rl.GetWindowPosition().x));
            const current_y = @as(i32, @intFromFloat(rl.GetWindowPosition().y));

            // Check if current position is different from desired position
            if (current_x != x or current_y != y) {
                debugPrint("Setting window position to: {}, {}\n", .{ x, y });
                rl.SetWindowPosition(x, y);
                position_restored = true;

                // Wait for position change to take effect
                std.time.sleep(50 * std.time.ns_per_ms); // 50ms delay for position
            } else {
                debugPrint("Window position already matches saved state\n", .{});
            }
        } else {
            debugPrint("Window position validation failed: {}, {} (out of range)\n", .{ x, y });
        }
    } else {
        debugPrint("No window position data in state file\n", .{});
    }

    // Final verification
    if (size_restored or position_restored) {
        std.time.sleep(100 * std.time.ns_per_ms); // Extra delay for macOS
        debugPrint("Final window size: {}x{}\n", .{ rl.GetScreenWidth(), rl.GetScreenHeight() });
        debugPrint("Final window position: {}, {}\n", .{ @as(i32, @intFromFloat(rl.GetWindowPosition().x)), @as(i32, @intFromFloat(rl.GetWindowPosition().y)) });
    }
}

pub fn main() !void {
    defer _ = gpa.deinit();

    cbz_files = ArrayList(CBZFile).init(allocator);
    defer {
        for (cbz_files.items) |*cbz| {
            cbz.deinit();
        }
        cbz_files.deinit();
    }

    pages = ArrayList(PageInfo).init(allocator);
    defer {
        for (pages.items) |*page| {
            if (page.loaded) {
                rl.UnloadTexture(page.texture);
            }
        }
        pages.deinit();
    }

    file_page_starts = ArrayList(usize).init(allocator);
    defer file_page_starts.deinit();

    cumulative_heights = ArrayList(f32).init(allocator);
    defer cumulative_heights.deinit();

    // Clean up folder_path if allocated
    defer {
        if (folder_path) |path| {
            allocator.free(path);
        }
    }

    camera = rl.Camera2D{
        .zoom = 1.0,
        .target = rl.Vector2{ .x = 0, .y = 0 },
        .offset = rl.Vector2{ .x = 0, .y = 0 },
        .rotation = 0,
    };

    var args = std.process.args();
    _ = args.skip(); // skip executable

    var file_path: ?[]const u8 = null;

    // Parse arguments
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--debug")) {
            debug_mode = true;
            std.debug.print("Debug mode enabled\n", .{});
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown option: {s}\n", .{arg});
            std.debug.print("Usage: cbzt [-d|--debug] <path_to_cbz_or_folder>\n", .{});
            return;
        } else {
            if (file_path == null) {
                file_path = arg;
            } else {
                std.debug.print("Too many arguments\n", .{});
                std.debug.print("Usage: cbzt [-d|--debug] <path_to_cbz_or_folder>\n", .{});
                return;
            }
        }
    }

    // Set raylib log level based on debug flag
    if (debug_mode) {
        rl.SetTraceLogLevel(rl.LOG_INFO); // Show all raylib logs in debug mode
    } else {
        rl.SetTraceLogLevel(rl.LOG_ERROR); // Only show errors in normal mode
    }

    // Disable escape key from closing window (in case gesture detection enabled it)
    rl.SetExitKey(rl.KEY_NULL); // Use KEY_NULL instead of 0

    var path: []const u8 = undefined;
    var dialog_path: ?[]u8 = null;

    if (file_path) |fp| {
        path = fp;
    } else {
        // No command line argument provided, show file dialog
        dialog_path = macos_wrapper.openFileDialog(allocator);
        if (dialog_path) |dp| {
            path = dp;
        } else {
            // User canceled the dialog
            return;
        }
    }

    // Clean up dialog path when done
    defer {
        if (dialog_path) |dp| {
            allocator.free(dp);
        }
    }

    // Set window flags before initialization
    rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE | rl.FLAG_VSYNC_HINT);

    // Initialize window
    rl.InitWindow(800, 600, "CBZT");
    defer rl.CloseWindow();
    rl.SetTargetFPS(active_fps); // Start with active FPS

    // Load the file path early
    try loadPath(path);

    // Initialize macOS-specific features (icon, menu bar, etc.)
    macos_wrapper.initializeMacOSFeatures();

    // Set up native macOS magnification gesture for trackpad pinch-to-zoom
    macos_wrapper.installPinchRecognizer(rl.GetWindowHandle());

    // Register signal handlers for graceful shutdown
    const sigaction = posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = posix.empty_sigset,
        .flags = 0,
    };
    _ = posix.sigaction(posix.SIG.INT, &sigaction, null) catch |err| {
        debugPrint("Warning: Could not register SIGINT handler: {}\n", .{err});
    };
    _ = posix.sigaction(posix.SIG.TERM, &sigaction, null) catch |err| {
        debugPrint("Warning: Could not register SIGTERM handler: {}\n", .{err});
    };

    // Initialize camera
    camera = rl.Camera2D{
        .offset = .{ .x = 0, .y = 0 },
        .target = .{ .x = 0, .y = 0 },
        .rotation = 0.0,
        .zoom = 1.0,
    };

    // Load embedded JetBrains Mono font at 2x size for crisp rendering
    ui_font = embedded_font.loadEmbeddedFontForSize(18);
    if (ui_font.texture.id == 0) {
        // Try external file as fallback, also at 2x size
        ui_font = rl.LoadFontEx("fonts/ttf/JetBrainsMono-Regular.ttf", 36, null, 0);
    }
    if (ui_font.texture.id == 0) {
        // Final fallback to default font
        ui_font = rl.GetFontDefault();
        debugPrint("Using default font (embedded JetBrains Mono failed to load)\n", .{});
    } else {
        debugPrint("Loaded embedded JetBrains Mono font successfully\n", .{});
    }
    defer if (ui_font.texture.id != rl.GetFontDefault().texture.id) rl.UnloadFont(ui_font);

    updateCumulative();

    // Initialize background image loader
    bg_image_loader = image_loader.ImageLoader.init(allocator, @ptrCast(&cbz_files), extractImageForBackground, debug_mode);
    try bg_image_loader.start();
    defer {
        bg_image_loader.stop(); // Stop the worker thread first
        bg_image_loader.deinit(); // Then clean up resources
    }

    // Load saved state after everything is initialized
    loadState();

    // Update camera with restored position
    updateCamera();

    // Force rendering for the first few frames to ensure textures are loaded and displayed
    force_render_frames = 5;

    // Force initial lazy loading to prevent black screen at restored position
    updateLazyLoading();

    // Initialize activity tracking
    markActivity(); // Start with activity so we begin at high FPS

    // Restore window properties (size and position) after all initialization is complete
    restoreWindowProperties();

    while (!rl.WindowShouldClose()) {
        // Handle escape key explicitly to prevent window closing
        if (rl.IsKeyPressed(rl.KEY_ESCAPE)) {
            if (show_help) {
                show_help = false;
            }
            // Don't let escape close the window - consume the key press
            continue;
        }

        // Check if user selected "Open..." from menu
        if (macos_wrapper.shouldOpenFile()) {
            macos_wrapper.resetOpenFileFlag();
            if (macos_wrapper.openFileDialog(allocator)) |new_path| {
                defer allocator.free(new_path);
                // Clean up current state before loading new file
                for (pages.items) |*page| {
                    if (page.loaded) {
                        rl.UnloadTexture(page.texture);
                        page.loaded = false;
                    }
                }
                pages.clearAndFree();
                for (cbz_files.items) |*cbz| {
                    cbz.deinit();
                }
                cbz_files.clearAndFree();
                file_page_starts.clearAndFree();
                cumulative_heights.clearAndFree();
                total_height = 0.0;
                total_pages = 0;
                current_scroll = 0.0;
                last_scroll = -1.0;
                // Reset camera
                camera.target = rl.Vector2{ .x = 0, .y = 0 };
                // Load new file
                loadPath(new_path) catch |err| {
                    std.debug.print("Error loading new file: {}\n", .{err});
                };
                needs_render = true; // Force render after loading new file
            }
        }

        // Detect input activity before processing input
        detectInputActivity();

        handleInput();
        updateCamera();

        // Update dynamic FPS based on activity
        updateDynamicFPS();

        // Check if we need to render
        const scroll_changed = @abs(current_scroll - last_scroll) > 5.0 or last_scroll == -1.0;
        const has_forced_frames = force_render_frames > 0;
        const window_resized = rl.IsWindowResized();
        needs_render = activity_detected or scroll_changed or has_forced_frames or show_help or window_resized;

        // Only update lazy loading when scroll position changes significantly, or when forced
        if (scroll_changed or has_forced_frames) {
            updateLazyLoading();
            last_scroll = current_scroll;
            if (force_render_frames > 0) {
                force_render_frames -= 1;
            }
        }

        // Process background loading results
        bg_process_counter += 1;
        if (bg_process_counter % 3 == 0) { // Only process every 3rd frame
            const had_results = processBackgroundResults();
            if (had_results) {
                markActivity(); // Mark activity when new textures are loaded
                needs_render = true; // Force a render when new textures are loaded
            }
        }

        // Always do the raylib frame cycle to process events properly
        rl.BeginDrawing();

        // Only do actual rendering when needed
        if (needs_render) {
            const bg_color = if (background_is_white) rl.WHITE else rl.BLACK;
            rl.ClearBackground(bg_color);
            rl.BeginMode2D(camera);

            renderPages();

            rl.EndMode2D();
            drawIndicator();

            if (show_help) {
                drawHelp();
            }
        }
        // When idle, we still call BeginDrawing/EndDrawing to process events
        // but skip the actual drawing - the screen keeps the previous frame

        rl.EndDrawing();
    }

    // Save state before exiting
    saveState();
}

fn loadPath(path: []const u8) !void {
    const stat = std.fs.cwd().statFile(path) catch |err| {
        debugPrint("Error accessing path: {}\n", .{err});
        return;
    };

    if (stat.kind == .directory) {
        try loadFolder(path);
    } else {
        try loadSingleCBZ(path);
    }
}

fn loadFolder(path: []const u8) !void {
    folder_path = try allocator.dupe(u8, path);

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();

    var files = ArrayList([]const u8).init(allocator);
    defer {
        for (files.items) |file| {
            allocator.free(file);
        }
        files.deinit();
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .file and (std.mem.endsWith(u8, entry.name, ".cbz") or std.mem.endsWith(u8, entry.name, ".zip"))) {
            const full_path = try std.fs.path.join(allocator, &.{ path, entry.name });
            try files.append(full_path);
        }
    }

    // Sort files alphabetically
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var global_page_idx: usize = 0;
    try file_page_starts.append(0);

    for (files.items) |file_path| {
        const cbz = loadCBZ(file_path) catch |err| {
            debugPrint("Error loading {s}: {}\n", .{ file_path, err });
            continue;
        };

        try cbz_files.append(cbz);
        const file_idx = cbz_files.items.len - 1;

        for (0..cbz.images.items.len) |local_idx| {
            const page_info = PageInfo{
                .file_idx = file_idx,
                .local_idx = local_idx,
                .texture = rl.Texture2D{ .id = 0, .width = 0, .height = 0, .mipmaps = 0, .format = 0 },
                .loaded = false,
                .loading_in_progress = false,
                .height = 0,
            };
            try pages.append(page_info);
            global_page_idx += 1;
        }

        try file_page_starts.append(global_page_idx);
    }

    total_pages = global_page_idx;
    debugPrint("Loaded {} CBZ files with {} total pages\n", .{ cbz_files.items.len, total_pages });
}

fn loadSingleCBZ(file_path: []const u8) !void {
    const cbz = try loadCBZ(file_path);
    try cbz_files.append(cbz);

    try file_page_starts.append(0);

    for (0..cbz.images.items.len) |local_idx| {
        const page_info = PageInfo{
            .file_idx = 0,
            .local_idx = local_idx,
            .texture = rl.Texture2D{ .id = 0, .width = 0, .height = 0, .mipmaps = 0, .format = 0 },
            .loaded = false,
            .loading_in_progress = false,
            .height = 0,
        };
        try pages.append(page_info);
    }

    try file_page_starts.append(cbz.images.items.len);
    total_pages = cbz.images.items.len;

    folder_path = try allocator.dupe(u8, std.fs.path.dirname(file_path) orelse ".");
}

fn loadCBZ(file_path: []const u8) !CBZFile {
    debugPrint("Loading CBZ: {s}\n", .{file_path});

    const file = try std.fs.cwd().openFile(file_path, .{});
    // Don't close the file here - we need to keep it open for ZIP reading

    var seekable = file.seekableStream();
    var zip_iterator = try std.zip.Iterator(@TypeOf(seekable)).init(seekable);

    var images = ArrayList([]const u8).init(allocator);
    var page_sizes = ArrayList(PageSize).init(allocator);

    // Collect image entries
    var image_entries = ArrayList([]const u8).init(allocator);
    defer {
        for (image_entries.items) |entry| {
            allocator.free(entry);
        }
        image_entries.deinit();
    }

    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try zip_iterator.next()) |entry| {
        const filename_len = entry.filename_len;
        const filename = filename_buf[0..filename_len];

        try seekable.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        _ = try seekable.context.reader().readAll(filename);

        if (std.mem.endsWith(u8, filename, ".jpg") or
            std.mem.endsWith(u8, filename, ".jpeg") or
            std.mem.endsWith(u8, filename, ".png"))
        {
            const name_copy = try allocator.dupe(u8, filename);
            try image_entries.append(name_copy);
        }
    }

    // Sort images by name
    std.mem.sort([]const u8, image_entries.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    // Process sorted images
    for (image_entries.items) |image_name| {
        const name_copy = try allocator.dupe(u8, image_name);
        try images.append(name_copy);

        // Use default dimensions - will be updated when image is loaded
        try page_sizes.append(.{ .width = 800, .height = 1000 });
    }

    const file_name = try allocator.dupe(u8, std.fs.path.basename(file_path));

    return CBZFile{
        .file = file,
        .images = images,
        .page_sizes = page_sizes,
        .file_name = file_name,
    };
}

fn updateCumulative() void {
    cumulative_heights.clearRetainingCapacity();
    var cum: f32 = 0.0;
    cumulative_heights.append(0.0) catch return;

    const screen_width = @as(f32, @floatFromInt(rl.GetScreenWidth()));

    for (pages.items) |*page| {
        const cbz = &cbz_files.items[page.file_idx];
        const page_size = cbz.page_sizes.items[page.local_idx];

        const scale_factor = if (page_size.width > 0) screen_width / @as(f32, @floatFromInt(page_size.width)) else 1.0;
        const height = if (page_size.height > 0) @as(f32, @floatFromInt(page_size.height)) * scale_factor else 100.0;

        page.height = height;
        cum += height;
        cumulative_heights.append(cum) catch return;
    }

    total_height = cum;
}

fn jumpToPreviousPage() void {
    if (total_pages == 0) return;

    // Find current page
    var current_page: usize = 0;
    for (cumulative_heights.items, 0..) |cum_height, i| {
        if (cum_height > current_scroll) {
            current_page = i;
            break;
        }
    }

    // Jump to previous page
    if (current_page > 0) {
        current_scroll = if (current_page == 1) 0.0 else cumulative_heights.items[current_page - 2];
    }

    // Force rendering and lazy loading update
    force_render_frames = 3;
    updateLazyLoading();
    last_scroll = -1.0; // Force update on next frame
}

fn jumpToNextPage() void {
    if (total_pages == 0) return;

    // Find current page
    var current_page: usize = 0;
    for (cumulative_heights.items, 0..) |cum_height, i| {
        if (cum_height > current_scroll) {
            current_page = i;
            break;
        }
    }

    // Jump to next page
    if (current_page < cumulative_heights.items.len - 1) {
        current_scroll = cumulative_heights.items[current_page];
    }

    // Force rendering and lazy loading update
    force_render_frames = 3;
    updateLazyLoading();
    last_scroll = -1.0; // Force update on next frame
}

fn jumpToPreviousFile() void {
    if (cbz_files.items.len == 0) return;

    // Find current file
    var current_file: usize = 0;
    var current_page: usize = 0;
    for (cumulative_heights.items, 0..) |cum_height, i| {
        if (cum_height > current_scroll) {
            current_page = i;
            break;
        }
    }

    // Find which file this page belongs to
    for (file_page_starts.items, 0..) |start, i| {
        if (i + 1 < file_page_starts.items.len and current_page >= start and current_page < file_page_starts.items[i + 1]) {
            current_file = i;
            break;
        } else if (i + 1 == file_page_starts.items.len and current_page >= start) {
            current_file = i;
            break;
        }
    }

    // Jump to previous file
    if (current_file > 0) {
        const prev_file_start = file_page_starts.items[current_file - 1];
        current_scroll = if (prev_file_start == 0) 0.0 else cumulative_heights.items[prev_file_start - 1];
    } else {
        // Already at first file, jump to beginning
        current_scroll = 0.0;
    }

    // Force rendering and lazy loading update to prevent black screen
    force_render_frames = 5;
    updateLazyLoading();
    last_scroll = -1.0; // Force update on next frame
}

fn jumpToNextFile() void {
    if (cbz_files.items.len == 0) return;

    // Find current file
    var current_file: usize = 0;
    var current_page: usize = 0;
    for (cumulative_heights.items, 0..) |cum_height, i| {
        if (cum_height > current_scroll) {
            current_page = i;
            break;
        }
    }

    // Find which file this page belongs to
    for (file_page_starts.items, 0..) |start, i| {
        if (i + 1 < file_page_starts.items.len and current_page >= start and current_page < file_page_starts.items[i + 1]) {
            current_file = i;
            break;
        } else if (i + 1 == file_page_starts.items.len and current_page >= start) {
            current_file = i;
            break;
        }
    }

    // Jump to next file
    if (current_file + 1 < file_page_starts.items.len) {
        const next_file_start = file_page_starts.items[current_file + 1];
        current_scroll = if (next_file_start == 0) 0.0 else cumulative_heights.items[next_file_start - 1];
    }

    // Force rendering and lazy loading update to prevent black screen
    force_render_frames = 5;
    updateLazyLoading();
    last_scroll = -1.0; // Force update on next frame
}

fn handleInput() void {
    const wheel = rl.GetMouseWheelMove();

    // Keyboard controls
    const screen_height = @as(f32, @floatFromInt(rl.GetScreenHeight()));
    const shift_pressed = rl.IsKeyDown(rl.KEY_LEFT_SHIFT) or rl.IsKeyDown(rl.KEY_RIGHT_SHIFT);
    const cmd_pressed = rl.IsKeyDown(rl.KEY_LEFT_SUPER) or rl.IsKeyDown(rl.KEY_RIGHT_SUPER);
    const ctrl_pressed = rl.IsKeyDown(rl.KEY_LEFT_CONTROL) or rl.IsKeyDown(rl.KEY_RIGHT_CONTROL);

    // Handle mouse wheel - zoom if modifier key is pressed, otherwise scroll
    if (wheel != 0) {
        if (ctrl_pressed or cmd_pressed) {
            // Ctrl/Cmd + mouse wheel for zoom (more reliable on macOS)
            const zoom_speed: f32 = 0.1;
            const min_zoom: f32 = 0.1;
            const max_zoom: f32 = 5.0;
            const zoom_delta = wheel * zoom_speed;
            zoom_level = std.math.clamp(zoom_level + zoom_delta, min_zoom, max_zoom);
        } else {
            // Regular scrolling
            current_scroll -= wheel * 100.0;
        }
    }

    // Arrow key navigation
    if (rl.IsKeyPressed(rl.KEY_UP)) {
        if ((cmd_pressed or ctrl_pressed) and shift_pressed) {
            // Cmd/Ctrl + Shift + Up: Jump to previous file
            jumpToPreviousFile();
        } else if (shift_pressed) {
            // Shift + Up: Jump to previous page
            jumpToPreviousPage();
        } else {
            // Up: Jump up one screen
            current_scroll -= screen_height;
        }
    }

    if (rl.IsKeyPressed(rl.KEY_DOWN)) {
        if ((cmd_pressed or ctrl_pressed) and shift_pressed) {
            // Cmd/Ctrl + Shift + Down: Jump to next file
            jumpToNextFile();
        } else if (shift_pressed) {
            // Shift + Down: Jump to next page
            jumpToNextPage();
        } else {
            // Down: Jump down one screen
            current_scroll += screen_height;
        }
    }

    // Additional useful controls
    if (rl.IsKeyPressed(rl.KEY_HOME)) {
        // Home: Jump to beginning
        current_scroll = 0.0;
    }

    if (rl.IsKeyPressed(rl.KEY_END)) {
        // End: Jump to end
        current_scroll = total_height - screen_height;
    }

    if (rl.IsKeyPressed(rl.KEY_PAGE_UP)) {
        // Page Up: Jump up one screen (same as Up arrow)
        current_scroll -= screen_height;
    }

    if (rl.IsKeyPressed(rl.KEY_PAGE_DOWN)) {
        // Page Down: Jump down one screen (same as Down arrow)
        current_scroll += screen_height;
    }

    // Help toggle
    if (rl.IsKeyPressed(rl.KEY_H) or rl.IsKeyPressed(rl.KEY_F1)) {
        show_help = !show_help;
    }

    // Background color toggle
    if (rl.IsKeyPressed(rl.KEY_B)) {
        background_is_white = !background_is_white;
        markActivity(); // Mark activity when background changes
    }

    // Zoom controls
    const zoom_speed: f32 = 0.1;
    const min_zoom: f32 = 0.1;
    const max_zoom: f32 = 5.0;

    // Keyboard zoom controls
    if (rl.IsKeyPressed(rl.KEY_EQUAL) or rl.IsKeyPressed(rl.KEY_KP_ADD)) {
        // + key: Zoom in
        zoom_level = std.math.clamp(zoom_level + zoom_speed, min_zoom, max_zoom);
    }

    if (rl.IsKeyPressed(rl.KEY_MINUS) or rl.IsKeyPressed(rl.KEY_KP_SUBTRACT)) {
        // - key: Zoom out
        zoom_level = std.math.clamp(zoom_level - zoom_speed, min_zoom, max_zoom);
    }

    if (rl.IsKeyPressed(rl.KEY_ZERO) or rl.IsKeyPressed(rl.KEY_KP_0)) {
        // 0 key: Reset zoom
        zoom_level = 1.0;
    }

    // Native macOS trackpad pinch-to-zoom
    const magnification = macos_wrapper.consumeMagnifyDelta();
    if (magnification != 0.0) {
        zoom_level = std.math.clamp(zoom_level + magnification, min_zoom, max_zoom);
        markActivity();
    }

    const max_scroll = @max(0.0, total_height - screen_height);
    current_scroll = std.math.clamp(current_scroll, 0.0, max_scroll);

    if (rl.IsWindowResized()) {
        // Calculate which page we're currently viewing before resize
        var current_page: usize = 0;
        var page_progress: f32 = 0.0; // How far through the current page (0.0 to 1.0)

        for (cumulative_heights.items, 0..) |cum_height, i| {
            if (cum_height > current_scroll) {
                current_page = i;
                if (i > 0) {
                    const page_start = cumulative_heights.items[i - 1];
                    const page_height = cum_height - page_start;
                    if (page_height > 0) {
                        page_progress = (current_scroll - page_start) / page_height;
                    }
                }
                break;
            }
        }

        // Update page heights based on new window size
        updateCumulative();

        // Restore scroll position to maintain same page and progress
        if (current_page < cumulative_heights.items.len) {
            const page_start = if (current_page > 0) cumulative_heights.items[current_page - 1] else 0.0;
            const page_end = cumulative_heights.items[current_page];
            const page_height = page_end - page_start;

            current_scroll = page_start + (page_progress * page_height);

            // Clamp to valid range
            const max_scroll_after_resize = @max(0.0, total_height - @as(f32, @floatFromInt(rl.GetScreenHeight())));
            current_scroll = std.math.clamp(current_scroll, 0.0, max_scroll_after_resize);
        }

        // Force lazy loading update on resize to prevent black screen
        updateLazyLoading();
        // Reset last_scroll to force update on next frame
        last_scroll = -1.0;
    }
}

fn updateCamera() void {
    camera.target.y = current_scroll;

    // Center content horizontally when zoomed out
    const screen_width = @as(f32, @floatFromInt(rl.GetScreenWidth()));
    if (zoom_level < 1.0) {
        // When zoomed out, center the content
        camera.target.x = -(screen_width * (1.0 - zoom_level)) / (2.0 * zoom_level);
    } else {
        // When zoomed in or at 100%, keep content left-aligned
        camera.target.x = 0;
    }

    camera.offset.x = 0;
    camera.offset.y = 0;
    camera.zoom = zoom_level;
}

fn processBackgroundResults() bool {
    // Process completed background loading results
    var had_results = false;
    while (bg_image_loader.getResult()) |result| {
        had_results = true;
        defer {
            var mut_result = result;
            mut_result.deinit(allocator);
        }

        if (!result.success) {
            debugPrint("Background loading failed for page {}\n", .{result.page_idx});
            // Clear loading flag for failed loads
            if (result.page_idx < pages.items.len) {
                pages.items[result.page_idx].loading_in_progress = false;
            }
            continue;
        }

        if (result.page_idx >= pages.items.len) {
            debugPrint("Invalid page index from background loader: {}\n", .{result.page_idx});
            continue;
        }

        const page = &pages.items[result.page_idx];

        // Always clear the loading_in_progress flag when processing results
        page.loading_in_progress = false;

        if (page.loaded) {
            // Page already loaded synchronously, skip
            continue;
        }

        // Create texture from pre-decoded pixel data
        // We need to copy the pixel data because the result will be freed
        const pixel_data_size = result.pixel_data.len;

        // Check if we've hit the texture limit
        if (loaded_texture_count >= max_loaded_textures) {
            debugPrint("Skipping texture creation for page {} - too many textures loaded ({})\n", .{ result.page_idx, loaded_texture_count });
            continue;
        }

        const pixel_data_copy = allocator.alloc(u8, pixel_data_size) catch {
            debugPrint("Failed to allocate memory for pixel data copy\n", .{});
            continue;
        };
        @memcpy(pixel_data_copy, result.pixel_data);

        const img = rl.Image{
            .data = @ptrCast(pixel_data_copy.ptr),
            .width = result.width,
            .height = result.height,
            .mipmaps = 1,
            .format = result.format,
        };

        page.texture = rl.LoadTextureFromImage(img);

        // Check if texture creation failed
        if (page.texture.id == 0) {
            debugPrint("Failed to create texture for page {}\n", .{result.page_idx});
            allocator.free(pixel_data_copy);
            continue;
        }

        page.loaded = true;
        loaded_texture_count += 1;

        // Free the copied pixel data after texture creation
        allocator.free(pixel_data_copy);

        // Update page size with actual dimensions
        const cbz = &cbz_files.items[page.file_idx];
        cbz.page_sizes.items[page.local_idx] = .{ .width = result.width, .height = result.height };

        debugPrint("Background loaded page {} ({}x{})\n", .{ result.page_idx, result.width, result.height });
    }

    return had_results;
}

fn updateLazyLoading() void {
    if (total_pages == 0) return;

    const screen_height = @as(f32, @floatFromInt(rl.GetScreenHeight()));
    const visible_start = current_scroll;
    const visible_end = current_scroll + screen_height;

    // Find the first page that's partially visible
    var start_page: usize = 0;
    for (cumulative_heights.items, 0..) |cum_height, i| {
        if (i >= cumulative_heights.items.len) break; // Bounds check
        if (cum_height >= visible_start) {
            start_page = i;
            break;
        }
    }

    // Find the last page that's partially visible
    var end_page: usize = start_page;
    for (start_page..cumulative_heights.items.len) |i| {
        if (i >= cumulative_heights.items.len) break; // Bounds check
        const page_top = if (i == 0) 0.0 else cumulative_heights.items[i - 1];
        if (page_top <= visible_end) {
            end_page = i;
        } else {
            break;
        }
    }

    // Apply 5-page buffer around visible range
    const buffer_size: usize = 5;
    const load_start = if (start_page >= buffer_size) start_page - buffer_size else 0;
    const load_end = @min(total_pages - 1, end_page + buffer_size);

    // Count currently loaded textures
    var loaded_count: usize = 0;
    for (pages.items) |page| {
        if (page.loaded) loaded_count += 1;
    }

    // Debug output - show when lazy loading actually happens (commented out for performance)
    // std.debug.print("LAZY LOAD: Visible pages {}-{}, Loading range {}-{}, Currently loaded: {}\n", .{ start_page, end_page, load_start, load_end, loaded_count });

    // Request background loading for pages in range and beyond
    // Load conservatively in background - just a small buffer
    const bg_load_start = if (load_start >= 2) load_start - 2 else 0;
    const bg_load_end = @min(total_pages - 1, load_end + 3);

    for (bg_load_start..bg_load_end + 1) |i| {
        if (i < pages.items.len and !pages.items[i].loaded and !pages.items[i].loading_in_progress) {
            const page = &pages.items[i];
            const cbz = &cbz_files.items[page.file_idx];
            const image_name = cbz.images.items[page.local_idx];

            // Mark as loading in progress to prevent duplicate requests
            page.loading_in_progress = true;

            // Calculate priority: higher for visible pages, lower for buffer pages
            const distance_from_visible = if (i < start_page) start_page - i else if (i > end_page) i - end_page else 0;
            const priority = 1000 - @as(i32, @intCast(distance_from_visible));

            bg_image_loader.requestLoad(i, page.file_idx, page.local_idx, image_name, priority) catch |err| {
                debugPrint("Error requesting background load for page {}: {}\n", .{ i, err });
                // If request failed, clear the loading flag
                page.loading_in_progress = false;
            };
        }
    }

    // Cancel background requests for pages far outside the current range
    bg_image_loader.cancelOutsideRange(bg_load_start, bg_load_end);

    // Synchronous fallback for immediately visible pages if background loading is slow
    var textures_loaded_this_frame: usize = 0;
    const max_sync_loads_per_frame: usize = if (force_render_frames > 0) 5 else 1; // Reduced since background loading handles most

    for (start_page..end_page + 1) |i| {
        if (i < pages.items.len and !pages.items[i].loaded) {
            if (textures_loaded_this_frame >= max_sync_loads_per_frame) {
                break; // Don't load more than max textures per frame synchronously
            }
            loadPageTexture(i) catch |err| {
                debugPrint("Error loading page {}: {}\n", .{ i, err });
            };
            textures_loaded_this_frame += 1;
        }
    }

    // Unload pages outside range
    for (pages.items, 0..) |*page, i| {
        if (page.loaded and (i < load_start or i > load_end)) {
            rl.UnloadTexture(page.texture);
            page.loaded = false;
            page.loading_in_progress = false; // Clear any background loading state
            page.texture = rl.Texture2D{ .id = 0, .width = 0, .height = 0, .mipmaps = 0, .format = 0 };
            if (loaded_texture_count > 0) {
                loaded_texture_count -= 1;
            }
        }
    }
}

fn loadPageTexture(page_idx: usize) !void {
    if (page_idx >= pages.items.len) return;

    const page = &pages.items[page_idx];
    if (page.loaded) return;

    const cbz = &cbz_files.items[page.file_idx];
    const image_name = cbz.images.items[page.local_idx];

    // Extract image data from CBZ file
    const image_data = try extractImageFromCBZ(cbz, image_name);
    defer allocator.free(image_data);

    // Detect image format from filename
    const file_ext = if (std.mem.endsWith(u8, image_name, ".png")) ".png" else if (std.mem.endsWith(u8, image_name, ".jpeg")) ".jpeg" else ".jpg";

    // Load image from memory
    const img = rl.LoadImageFromMemory(file_ext, image_data.ptr, @intCast(image_data.len));
    defer rl.UnloadImage(img);

    if (img.data == null) {
        debugPrint("Failed to load image: {s}\n", .{image_name});
        return;
    }

    // Check for large textures and downsample if needed
    const max_texture_size: i32 = 2048;
    var final_img = img;
    var needs_resize = false;

    if (img.width > max_texture_size or img.height > max_texture_size) {
        debugPrint("Downsampling large texture for page {} from ({}x{}) ", .{ page_idx, img.width, img.height });

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

        debugPrint("to ({}x{})\n", .{ new_width, new_height });
    }

    // Check if we've hit the texture limit
    if (loaded_texture_count >= max_loaded_textures) {
        debugPrint("Skipping texture creation for page {} - too many textures loaded ({})\n", .{ page_idx, loaded_texture_count });
        if (needs_resize) {
            rl.UnloadImage(final_img);
        }
        return;
    }

    // Update page size with actual image dimensions (use original dimensions for layout)
    cbz.page_sizes.items[page.local_idx] = .{ .width = img.width, .height = img.height };

    // Create texture from image
    page.texture = rl.LoadTextureFromImage(final_img);

    // If we resized, unload the resized image
    if (needs_resize) {
        rl.UnloadImage(final_img);
    }

    // Check if texture creation failed
    if (page.texture.id == 0) {
        debugPrint("Failed to create texture for page {}\n", .{page_idx});
        return;
    }

    page.loaded = true;
    page.loading_in_progress = false; // Clear any pending background loading
    loaded_texture_count += 1;
}

fn extractImageForBackground(cbz_files_ptr: *anyopaque, alloc: Allocator, image_name: []const u8, file_idx: usize, local_idx: usize) ![]u8 {
    _ = local_idx; // unused for now
    _ = alloc; // unused in this function
    const cbz_list = @as(*ArrayList(CBZFile), @ptrCast(@alignCast(cbz_files_ptr)));

    if (file_idx >= cbz_list.items.len) {
        return error.InvalidFileIndex;
    }

    const cbz = &cbz_list.items[file_idx];
    return extractImageFromCBZ(cbz, image_name);
}

fn extractImageFromCBZ(cbz: *const CBZFile, image_name: []const u8) ![]u8 {
    var seekable = cbz.file.seekableStream();
    var zip_iterator = try std.zip.Iterator(@TypeOf(seekable)).init(seekable);

    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try zip_iterator.next()) |entry| {
        const filename_len = entry.filename_len;
        const filename = filename_buf[0..filename_len];

        try seekable.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        _ = try seekable.context.reader().readAll(filename);

        if (std.mem.eql(u8, filename, image_name)) {
            // Found the image, extract its data
            const compressed_size = entry.compressed_size;
            const uncompressed_size = entry.uncompressed_size;

            // Seek to the local file header
            try seekable.seekTo(entry.file_offset);

            // Read local file header to get actual data offset
            const local_header: std.zip.LocalFileHeader = try seekable.context.reader().readStruct(std.zip.LocalFileHeader);

            // Skip filename and extra field
            try seekable.seekBy(local_header.filename_len + local_header.extra_len);

            // Read compressed data
            const compressed_data = try allocator.alloc(u8, compressed_size);
            defer allocator.free(compressed_data);
            _ = try seekable.context.reader().readAll(compressed_data);

            // Decompress if needed
            if (entry.compression_method == .store) {
                // No compression - just copy the data
                return try allocator.dupe(u8, compressed_data);
            } else if (entry.compression_method == .deflate) {
                // Deflate compression
                const decompressed = try allocator.alloc(u8, uncompressed_size);
                var stream = std.io.fixedBufferStream(compressed_data);
                var decompressor = std.compress.flate.decompressor(stream.reader());

                const bytes_read = try decompressor.reader().readAll(decompressed);
                if (bytes_read != uncompressed_size) {
                    allocator.free(decompressed);
                    return error.DecompressionError;
                }

                return decompressed;
            } else {
                return error.UnsupportedCompressionMethod;
            }
        }
    }

    return error.ImageNotFound;
}

fn renderPages() void {
    var y: f32 = 0.0;

    for (pages.items, 0..) |*page, i| {
        // Bounds check to prevent segfaults
        if (i >= pages.items.len) break;

        if (page.loaded and page.texture.id != 0) {
            const width = @as(f32, @floatFromInt(rl.GetScreenWidth()));
            rl.DrawTexturePro(
                page.texture,
                rl.Rectangle{ .x = 0, .y = 0, .width = @floatFromInt(page.texture.width), .height = @floatFromInt(page.texture.height) },
                rl.Rectangle{ .x = 0, .y = y, .width = width, .height = page.height },
                rl.Vector2{ .x = 0, .y = 0 },
                0,
                rl.WHITE,
            );
        }
        y += page.height;
    }
}

fn drawIndicator() void {
    if (total_pages == 0) return;

    // Calculate current page based on scroll position
    var current_page: usize = 1;
    for (cumulative_heights.items, 0..) |cum_height, i| {
        if (current_scroll < cum_height) {
            current_page = i;
            break;
        }
    }

    // Find current file
    var file_idx: usize = 0;
    for (file_page_starts.items, 0..) |start, i| {
        if (i + 1 < file_page_starts.items.len and current_page >= start and current_page < file_page_starts.items[i + 1]) {
            file_idx = i;
            break;
        } else if (i + 1 == file_page_starts.items.len and current_page >= start) {
            file_idx = i;
            break;
        }
    }

    const global_percentage = if (total_height > 0) @as(i32, @intFromFloat((current_scroll / total_height) * 100.0)) else 0;

    const current_file = if (file_idx < cbz_files.items.len) cbz_files.items[file_idx].file_name else "Unknown";
    const local_page = if (file_idx < file_page_starts.items.len) current_page - file_page_starts.items[file_idx] + 1 else 1;
    const local_total = if (file_idx < cbz_files.items.len) cbz_files.items[file_idx].images.items.len else 0;
    const local_percentage = if (local_total > 0) @as(i32, @intFromFloat((@as(f32, @floatFromInt(local_page)) / @as(f32, @floatFromInt(local_total))) * 100.0)) else 0;

    // Update window title with current file name
    var title_buf: [512]u8 = undefined;
    const title = std.fmt.bufPrintZ(title_buf[0..], "CBZetto - {s}", .{current_file}) catch "CBZetto";
    rl.SetWindowTitle(title.ptr);

    // Create text buffer with null terminator (without filename, now in title)
    var text_buf: [512]u8 = undefined;
    const text = std.fmt.bufPrintZ(text_buf[0..], "Page {d}/{d} ({d}%) | {d}/{d} ({d}%)", .{ local_page, local_total, local_percentage, current_page, total_pages, global_percentage }) catch "Error";

    // Measure text with the UI font using scaled size
    const font_size = embedded_font.getScaledFontSize(18);
    const text_size = rl.MeasureTextEx(ui_font, text.ptr, font_size, 1.0);

    // Position at absolute bottom right corner with small padding
    const screen_width = rl.GetScreenWidth();
    const screen_height = rl.GetScreenHeight();
    const padding = 4;

    const bg_width = @as(i32, @intFromFloat(text_size.x)) + (padding * 2);
    const bg_height = @as(i32, @intFromFloat(text_size.y)) + (padding * 2);
    const bg_x = screen_width - bg_width;
    const bg_y = screen_height - bg_height;
    const text_x = bg_x + padding;
    const text_y = bg_y + padding;

    // Draw background
    rl.DrawRectangle(bg_x, bg_y, bg_width, bg_height, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 180 });

    // Draw text with better font
    rl.DrawTextEx(ui_font, text.ptr, rl.Vector2{ .x = @floatFromInt(text_x), .y = @floatFromInt(text_y) }, font_size, 1.0, rl.WHITE);
}

fn drawHelp() void {
    const screen_width = rl.GetScreenWidth();
    const screen_height = rl.GetScreenHeight();

    // Draw semi-transparent background
    rl.DrawRectangle(0, 0, screen_width, screen_height, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 200 });

    const help_lines = [_][]const u8{ "CBZetto - Keyboard Controls", "", "Navigation:", "  ↑/↓ Arrow Keys    - Jump up/down one screen", "  Shift + ↑/↓       - Jump to previous/next page", "  Ctrl/Cmd+Shift+↑/↓ - Jump to previous/next file", "  Page Up/Down      - Jump up/down one screen", "  Home              - Jump to beginning", "  End               - Jump to end", "", "Zoom:", "  + or =            - Zoom in", "  - or _            - Zoom out", "  0                 - Reset zoom to 100%", "  Ctrl/Cmd + Wheel  - Zoom in/out", "  Pinch gestures    - Zoom in/out (macOS)", "", "Other:", "  B                 - Toggle background (black/white)", "  H or F1           - Show/hide this help", "  Escape            - Close help", "  Mouse Wheel       - Scroll up/down", "", "Press H or F1 to close this help" };

    const font_size = embedded_font.getScaledFontSize(16);
    const line_height = @as(i32, @intFromFloat(font_size * 1.25));
    const margin = 50;

    // Calculate text dimensions
    const text_width = 400;
    const text_height = @as(i32, @intCast(help_lines.len)) * line_height;

    // Center the help box
    const box_x = @divTrunc(screen_width - text_width, 2);
    const box_y = @divTrunc(screen_height - text_height, 2);

    // Draw help box background
    rl.DrawRectangle(box_x - margin, box_y - margin, text_width + margin * 2, text_height + margin * 2, rl.Color{ .r = 40, .g = 40, .b = 40, .a = 240 });
    rl.DrawRectangleLines(box_x - margin, box_y - margin, text_width + margin * 2, text_height + margin * 2, rl.WHITE);

    // Draw help text line by line
    for (help_lines, 0..) |line, i| {
        const text_color = if (std.mem.startsWith(u8, line, "CBZetto")) rl.Color{ .r = 255, .g = 255, .b = 100, .a = 255 } else rl.WHITE;

        // Create null-terminated string for raylib
        var line_buf: [256]u8 = undefined;
        const line_z = std.fmt.bufPrintZ(line_buf[0..], "{s}", .{line}) catch blk: {
            // Fallback: create a null-terminated copy
            @memcpy(line_buf[0..line.len], line);
            line_buf[line.len] = 0;
            break :blk line_buf[0..line.len :0];
        };

        const y_pos = @as(f32, @floatFromInt(box_y)) + @as(f32, @floatFromInt(@as(i32, @intCast(i)) * line_height));
        rl.DrawTextEx(ui_font, line_z, rl.Vector2{ .x = @as(f32, @floatFromInt(box_x)), .y = y_pos }, font_size, 1.0, text_color);
    }
}
