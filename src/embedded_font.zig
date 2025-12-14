const std = @import("std");
const rl = @cImport(@cInclude("raylib.h"));
const font_data = @import("embedded_font_data.zig");

// GLFW functions declared directly (linked via raylib)
const GLFWwindow = opaque {};
const GLFWmonitor = opaque {};
extern fn glfwGetCurrentContext() ?*GLFWwindow;
extern fn glfwGetPrimaryMonitor() ?*GLFWmonitor;
extern fn glfwGetWindowMonitor(window: *GLFWwindow) ?*GLFWmonitor;
extern fn glfwGetMonitorContentScale(monitor: *GLFWmonitor, xscale: *f32, yscale: *f32) void;
extern fn glfwGetCocoaWindow(window: *GLFWwindow) ?*anyopaque;

pub fn loadEmbeddedFont(fontSize: i32) rl.Font {
    // Load font from embedded Zig data at the requested size
    const data_ptr = @as([*]const u8, @ptrCast(&font_data.font_data[0]));
    const data_size = @as(i32, @intCast(font_data.font_size));

    return rl.LoadFontFromMemory(".ttf", data_ptr, data_size, fontSize, null, 0);
}

pub fn loadEmbeddedFontForSize(targetSize: i32) rl.Font {
    // Load font at 2x size for crisp rendering on all displays
    // This provides high-quality glyphs that look good when scaled down
    const load_size = targetSize * 2;

    const data_ptr = @as([*]const u8, @ptrCast(&font_data.font_data[0]));
    const data_size = @as(i32, @intCast(font_data.font_size));

    return rl.LoadFontFromMemory(".ttf", data_ptr, data_size, load_size, null, 0);
}

pub fn getContentScale() f32 {
    // Get the current monitor's content scale using GLFW
    // This is the proper way to detect high DPI displays
    const monitor = glfwGetPrimaryMonitor();
    if (monitor == null) {
        return 1.0;
    }

    var xscale: f32 = 1.0;
    var yscale: f32 = 1.0;
    glfwGetMonitorContentScale(monitor.?, &xscale, &yscale);

    // Use the larger of the two scales (they should usually be the same)
    return @max(xscale, yscale);
}

pub fn getWindowContentScale() f32 {
    // Get the content scale for the current window's monitor
    // This is more accurate than using the primary monitor
    const window = glfwGetCurrentContext();
    if (window == null) {
        return getContentScale();
    }

    const monitor = glfwGetWindowMonitor(window.?);
    const target_monitor = if (monitor != null) monitor else glfwGetPrimaryMonitor();

    if (target_monitor == null) {
        return 1.0;
    }

    var xscale: f32 = 1.0;
    var yscale: f32 = 1.0;
    glfwGetMonitorContentScale(target_monitor.?, &xscale, &yscale);

    return @max(xscale, yscale);
}

pub fn getScaledFontSize(targetSize: i32) f32 {
    // Return the target size as float for rendering
    // The font is loaded at 2x but we render at the target size
    return @as(f32, @floatFromInt(targetSize));
}

// Get the native Cocoa NSWindow handle for the current GLFW window
pub fn getCocoaWindow() ?*anyopaque {
    const window = glfwGetCurrentContext();
    if (window == null) return null;
    return glfwGetCocoaWindow(window.?);
}
