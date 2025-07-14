const std = @import("std");
const rl = @cImport(@cInclude("raylib.h"));

// Import only the Objective-C runtime (no AppKit headers)
const objc = @cImport({
    @cInclude("objc/objc.h");
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});

// Additional runtime functions we need
extern fn object_getClass(obj: ?*anyopaque) ?*anyopaque;
extern fn class_addMethod(cls: ?*anyopaque, name: objc.SEL, imp: ?*anyopaque, types: [*:0]const u8) bool;

// Constants for NSApplicationActivationPolicy
const NSApplicationActivationPolicyRegular: c_long = 0;

// Global flag to track when user selects "Open..." from menu
var should_open_file: bool = false;

// Target object for handling menu actions
var menu_target: ?*anyopaque = null;

// Simple callback function for "Open..." menu item
export fn openFileCallback(self: ?*anyopaque, selector: objc.SEL) void {
    _ = self;
    _ = selector;
    should_open_file = true;
}

// Helper function to convert C string to NSString
fn nsString(str: [*:0]const u8) ?*anyopaque {
    const NSString = objc.objc_getClass("NSString");
    const selector = objc.sel_registerName("stringWithUTF8String:");
    const msgSend = @as(*const fn (?*anyopaque, objc.SEL, [*:0]const u8) callconv(.C) ?*anyopaque, @ptrCast(&objc.objc_msgSend));
    return msgSend(NSString, selector, str);
}

// Get shared application instance
fn getSharedApplication() ?*anyopaque {
    const NSApplication = objc.objc_getClass("NSApplication");
    const selector = objc.sel_registerName("sharedApplication");
    const msgSend = @as(*const fn (?*anyopaque, objc.SEL) callconv(.C) ?*anyopaque, @ptrCast(&objc.objc_msgSend));
    return msgSend(NSApplication, selector);
}

// Set the application icon
pub fn setAppIcon(icon_path: [*:0]const u8) void {
    const sharedApplication = getSharedApplication() orelse return;

    const NSImage = objc.objc_getClass("NSImage");
    const allocSelector = objc.sel_registerName("alloc");
    const initWithContentsOfFile = objc.sel_registerName("initWithContentsOfFile:");

    const allocMsg = @as(*const fn (?*anyopaque, objc.SEL) callconv(.C) ?*anyopaque, @ptrCast(&objc.objc_msgSend));
    const initMsg = @as(*const fn (?*anyopaque, objc.SEL, ?*anyopaque) callconv(.C) ?*anyopaque, @ptrCast(&objc.objc_msgSend));

    const imageAlloc = allocMsg(NSImage, allocSelector);
    const nsStringPath = nsString(icon_path);
    const image = initMsg(imageAlloc, initWithContentsOfFile, nsStringPath);

    if (image != null) {
        const setApplicationIconImage = objc.sel_registerName("setApplicationIconImage:");
        const setIconMsg = @as(*const fn (?*anyopaque, objc.SEL, ?*anyopaque) callconv(.C) ?*anyopaque, @ptrCast(&objc.objc_msgSend));
        _ = setIconMsg(sharedApplication, setApplicationIconImage, image);
    }
}

// Create a simple menu bar with basic items
pub fn createMenuBar() void {
    const sharedApplication = getSharedApplication() orelse return;

    const NSMenu = objc.objc_getClass("NSMenu");
    const NSMenuItem = objc.objc_getClass("NSMenuItem");
    const allocSelector = objc.sel_registerName("alloc");
    const initSelector = objc.sel_registerName("init");
    const initWithTitleSelector = objc.sel_registerName("initWithTitle:action:keyEquivalent:");

    const allocMsg = @as(*const fn (?*anyopaque, objc.SEL) callconv(.C) ?*anyopaque, @ptrCast(&objc.objc_msgSend));
    const initMsg = @as(*const fn (?*anyopaque, objc.SEL) callconv(.C) ?*anyopaque, @ptrCast(&objc.objc_msgSend));
    const initWithTitleMsg = @as(*const fn (?*anyopaque, objc.SEL, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.C) ?*anyopaque, @ptrCast(&objc.objc_msgSend));

    // Create main menu bar
    const mainMenuAlloc = allocMsg(NSMenu, allocSelector);
    const mainMenu = initMsg(mainMenuAlloc, initSelector);

    // Create app menu
    const appMenuAlloc = allocMsg(NSMenu, allocSelector);
    const appMenu = initMsg(appMenuAlloc, initSelector);
    const appMenuItemAlloc = allocMsg(NSMenuItem, allocSelector);
    const appMenuItem = initMsg(appMenuItemAlloc, initSelector);

    // Create quit menu item
    const quitItemAlloc = allocMsg(NSMenuItem, allocSelector);
    const terminateSelector = objc.sel_registerName("terminate:");
    const quitItem = initWithTitleMsg(quitItemAlloc, initWithTitleSelector, nsString("Quit CBZT"), terminateSelector, nsString("q"));

    // Add quit item to app menu
    const addItemSelector = objc.sel_registerName("addItem:");
    const addItemMsg = @as(*const fn (?*anyopaque, objc.SEL, ?*anyopaque) callconv(.C) void, @ptrCast(&objc.objc_msgSend));
    addItemMsg(appMenu, addItemSelector, quitItem);

    // Set submenu
    const setSubmenuSelector = objc.sel_registerName("setSubmenu:");
    const setSubmenuMsg = @as(*const fn (?*anyopaque, objc.SEL, ?*anyopaque) callconv(.C) void, @ptrCast(&objc.objc_msgSend));
    setSubmenuMsg(appMenuItem, setSubmenuSelector, appMenu);

    // Add app menu to main menu
    addItemMsg(mainMenu, addItemSelector, appMenuItem);

    // Create File menu
    const fileMenuAlloc = allocMsg(NSMenu, allocSelector);
    const fileMenu = initMsg(fileMenuAlloc, initSelector);
    const fileMenuItemAlloc = allocMsg(NSMenuItem, allocSelector);
    const fileMenuItem = initMsg(fileMenuItemAlloc, initSelector);

    // Create menu target if not already created
    if (menu_target == null) {
        const NSObject = objc.objc_getClass("NSObject");
        const menuTargetAlloc = allocMsg(NSObject, allocSelector);
        menu_target = initMsg(menuTargetAlloc, initSelector);

        // Add the openFile: method to our target object
        const targetClass = object_getClass(menu_target);
        const openFileAction = objc.sel_registerName("openFile:");
        const method_added = class_addMethod(targetClass, openFileAction, @constCast(@ptrCast(&openFileCallback)), "v@:");
        _ = method_added; // Ignore result for now
    }

    // Create "Open..." menu item with Cmd+O shortcut
    const openItemAlloc = allocMsg(NSMenuItem, allocSelector);
    const openItem = initWithTitleMsg(openItemAlloc, initWithTitleSelector, nsString("Open..."), null, nsString("o"));

    // Set up the action properly
    const setActionSelector = objc.sel_registerName("setAction:");
    const setActionMsg = @as(*const fn (?*anyopaque, objc.SEL, objc.SEL) callconv(.C) void, @ptrCast(&objc.objc_msgSend));
    const openFileAction = objc.sel_registerName("openFile:");
    setActionMsg(openItem, setActionSelector, openFileAction);

    // Set target to our menu target object
    const setTargetSelector = objc.sel_registerName("setTarget:");
    const setTargetMsg = @as(*const fn (?*anyopaque, objc.SEL, ?*anyopaque) callconv(.C) void, @ptrCast(&objc.objc_msgSend));
    setTargetMsg(openItem, setTargetSelector, menu_target);

    // Add open item to file menu
    addItemMsg(fileMenu, addItemSelector, openItem);

    // Set file menu title and add to main menu
    const setTitleSelector = objc.sel_registerName("setTitle:");
    const setTitleMsg = @as(*const fn (?*anyopaque, objc.SEL, ?*anyopaque) callconv(.C) void, @ptrCast(&objc.objc_msgSend));
    setTitleMsg(fileMenuItem, setTitleSelector, nsString("File"));
    setSubmenuMsg(fileMenuItem, setSubmenuSelector, fileMenu);
    addItemMsg(mainMenu, addItemSelector, fileMenuItem);

    // Set the main menu
    const setMainMenuSelector = objc.sel_registerName("setMainMenu:");
    const setMainMenuMsg = @as(*const fn (?*anyopaque, objc.SEL, ?*anyopaque) callconv(.C) void, @ptrCast(&objc.objc_msgSend));
    setMainMenuMsg(sharedApplication, setMainMenuSelector, mainMenu);
}

// Show file dialog and return selected file path
pub fn openFileDialog(allocator: std.mem.Allocator) ?[]u8 {
    const NSOpenPanel = objc.objc_getClass("NSOpenPanel");
    const openPanelSelector = objc.sel_registerName("openPanel");
    const openPanelMsg = @as(*const fn (?*anyopaque, objc.SEL) callconv(.C) ?*anyopaque, @ptrCast(&objc.objc_msgSend));

    const openPanel = openPanelMsg(NSOpenPanel, openPanelSelector);
    if (openPanel == null) return null;

    // For now, we'll skip file type filtering to avoid NSArray issues
    // Users can still select any file, and the app will handle invalid files gracefully

    const setCanChooseDirectoriesSelector = objc.sel_registerName("setCanChooseDirectories:");
    const setCanChooseDirectoriesMsg = @as(*const fn (?*anyopaque, objc.SEL, bool) callconv(.C) void, @ptrCast(&objc.objc_msgSend));
    setCanChooseDirectoriesMsg(openPanel, setCanChooseDirectoriesSelector, true);

    const setCanChooseFilesSelector = objc.sel_registerName("setCanChooseFiles:");
    const setCanChooseFilesMsg = @as(*const fn (?*anyopaque, objc.SEL, bool) callconv(.C) void, @ptrCast(&objc.objc_msgSend));
    setCanChooseFilesMsg(openPanel, setCanChooseFilesSelector, true);

    const setAllowsMultipleSelectionSelector = objc.sel_registerName("setAllowsMultipleSelection:");
    const setAllowsMultipleSelectionMsg = @as(*const fn (?*anyopaque, objc.SEL, bool) callconv(.C) void, @ptrCast(&objc.objc_msgSend));
    setAllowsMultipleSelectionMsg(openPanel, setAllowsMultipleSelectionSelector, false);

    // Set title
    const setTitleSelector = objc.sel_registerName("setTitle:");
    const setTitleMsg = @as(*const fn (?*anyopaque, objc.SEL, ?*anyopaque) callconv(.C) void, @ptrCast(&objc.objc_msgSend));
    setTitleMsg(openPanel, setTitleSelector, nsString("Open Comic Book Archive or Folder"));

    // Run the dialog
    const runModalSelector = objc.sel_registerName("runModal");
    const runModalMsg = @as(*const fn (?*anyopaque, objc.SEL) callconv(.C) c_long, @ptrCast(&objc.objc_msgSend));
    const result = runModalMsg(openPanel, runModalSelector);

    // NSModalResponseOK = 1
    if (result != 1) return null;

    // Get the selected URL
    const URLsSelector = objc.sel_registerName("URLs");
    const URLsMsg = @as(*const fn (?*anyopaque, objc.SEL) callconv(.C) ?*anyopaque, @ptrCast(&objc.objc_msgSend));
    const urls = URLsMsg(openPanel, URLsSelector);

    if (urls == null) return null;

    // Get first URL from array
    const firstObjectSelector = objc.sel_registerName("firstObject");
    const firstObjectMsg = @as(*const fn (?*anyopaque, objc.SEL) callconv(.C) ?*anyopaque, @ptrCast(&objc.objc_msgSend));
    const firstUrl = firstObjectMsg(urls, firstObjectSelector);

    if (firstUrl == null) return null;

    // Get path from URL
    const pathSelector = objc.sel_registerName("path");
    const pathMsg = @as(*const fn (?*anyopaque, objc.SEL) callconv(.C) ?*anyopaque, @ptrCast(&objc.objc_msgSend));
    const nsPath = pathMsg(firstUrl, pathSelector);

    if (nsPath == null) return null;

    // Convert NSString to C string
    const UTF8StringSelector = objc.sel_registerName("UTF8String");
    const UTF8StringMsg = @as(*const fn (?*anyopaque, objc.SEL) callconv(.C) [*:0]const u8, @ptrCast(&objc.objc_msgSend));
    const cPath = UTF8StringMsg(nsPath, UTF8StringSelector);

    // Copy to Zig-owned memory
    const path_len = std.mem.len(cPath);
    const owned_path = allocator.alloc(u8, path_len) catch return null;
    std.mem.copyForwards(u8, owned_path, cPath[0..path_len]);

    return owned_path;
}

// Check if user selected "Open..." from menu
pub fn shouldOpenFile() bool {
    return should_open_file;
}

// Reset the open file flag
pub fn resetOpenFileFlag() void {
    should_open_file = false;
}

// Initialize macOS-specific features
pub fn initializeMacOSFeatures() void {
    const sharedApplication = getSharedApplication() orelse return;

    // Set activation policy to regular (shows in dock)
    const setActivationPolicySelector = objc.sel_registerName("setActivationPolicy:");
    const setActivationPolicyMsg = @as(*const fn (?*anyopaque, objc.SEL, c_long) callconv(.C) bool, @ptrCast(&objc.objc_msgSend));
    _ = setActivationPolicyMsg(sharedApplication, setActivationPolicySelector, NSApplicationActivationPolicyRegular);

    // Create and set the menu bar
    createMenuBar();

    // Set the app icon (placeholder path for now)
    setAppIcon("resources/icon.png");

    // Activate the app
    const activateSelector = objc.sel_registerName("activateIgnoringOtherApps:");
    const activateMsg = @as(*const fn (?*anyopaque, objc.SEL, bool) callconv(.C) void, @ptrCast(&objc.objc_msgSend));
    activateMsg(sharedApplication, activateSelector, true);
}
