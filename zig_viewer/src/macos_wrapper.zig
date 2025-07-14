const std = @import("std");
const rl = @cImport(@cInclude("raylib.h"));

// Import only the Objective-C runtime (no AppKit headers)
const objc = @cImport({
    @cInclude("objc/objc.h");
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});

// Constants for NSApplicationActivationPolicy
const NSApplicationActivationPolicyRegular: c_long = 0;

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

    // Set the main menu
    const setMainMenuSelector = objc.sel_registerName("setMainMenu:");
    const setMainMenuMsg = @as(*const fn (?*anyopaque, objc.SEL, ?*anyopaque) callconv(.C) void, @ptrCast(&objc.objc_msgSend));
    setMainMenuMsg(sharedApplication, setMainMenuSelector, mainMenu);
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
