// Screenshot helper injected into the screenshots-only Mac build: lets the app
// capture its own windows (no Screen Recording permission needed) on request.
#import <Cocoa/Cocoa.h>
#import <dlfcn.h>

typedef CGImageRef (*FromArrayFn)(CGRect, CFArrayRef, uint32_t);

static NSWindow *findWindow(NSString *needle) {
    for (NSWindow *w in NSApp.windows) {
        if (!w.isVisible || w.level != NSNormalWindowLevel || w.sheetParent) continue;
        if ([needle isEqual:@"reader"]) { if (w.titlebarAppearsTransparent && w.title.length == 0) return w; continue; }
        if ([needle isEqual:@"*"] || [w.title localizedCaseInsensitiveContainsString:needle]) return w;
    }
    return nil;
}

static void collect(NSWindow *w, NSMutableArray *ids) {
    [ids addObject:@(w.windowNumber)];
    for (NSWindow *s in w.sheets) collect(s, ids);
    for (NSWindow *c in w.childWindows) if (c.isVisible) collect(c, ids);
}

static void findMenus(NSView *v, NSMutableArray *out) {
    if ([v respondsToSelector:@selector(menu)] && [v isKindOfClass:NSPopUpButton.class]) [out addObject:((NSPopUpButton *)v).menu];
    for (NSView *c in v.subviews) findMenus(c, out);
}

static void findButtons(NSView *v, NSMutableArray *out) {
    if ([v isKindOfClass:NSPopUpButton.class]) [out addObject:v];
    for (NSView *c in v.subviews) findButtons(c, out);
}

static BOOL pressMenuItem(NSMenu *m, NSString *needle, NSMutableString *log) {
    if ([m.delegate respondsToSelector:@selector(menuNeedsUpdate:)]) [m.delegate menuNeedsUpdate:m];
    [m update];
    for (NSInteger i = 0; i < m.numberOfItems; i++) {
        NSMenuItem *it = [m itemAtIndex:i];
        [log appendFormat:@"item '%@'\n", it.title];
        if ([it.title localizedCaseInsensitiveContainsString:needle]) {
            [m cancelTrackingWithoutAnimation];
            dispatch_async(dispatch_get_main_queue(), ^{ [m performActionForItemAtIndex:i]; });
            return YES;
        }
        if (it.submenu && pressMenuItem(it.submenu, needle, log)) return YES;
    }
    return NO;
}

static void tick(void) {
    NSString *tmp = [NSHomeDirectory() stringByAppendingPathComponent:@"tmp"];
    NSString *req = [tmp stringByAppendingPathComponent:@"cap_request"];
    NSString *cmd = [NSString stringWithContentsOfFile:req encoding:NSUTF8StringEncoding error:nil];
    if (!cmd) return;
    [[NSFileManager defaultManager] removeItemAtPath:req error:nil];
    NSArray<NSString *> *p = [[cmd stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                              componentsSeparatedByString:@"|"];
    NSMutableString *log = [NSMutableString string];
    if ([p[0] isEqual:@"list"]) {
        for (NSWindow *w in NSApp.windows)
            [log appendFormat:@"%ld vis=%d level=%ld sheetParent=%d '%@' %@\n", (long)w.windowNumber, w.isVisible,
             (long)w.level, w.sheetParent != nil, w.title, NSStringFromRect(w.frame)];
    } else if ([p[0] isEqual:@"menu"] && p.count >= 3) {
        NSWindow *w = findWindow(p[1]);
        NSMutableArray *menus = [NSMutableArray array];
        for (NSToolbarItem *it in w.toolbar.items) {
            if ([it isKindOfClass:NSMenuToolbarItem.class]) [menus addObject:((NSMenuToolbarItem *)it).menu];
            if (it.view) findMenus(it.view, menus);
        }
        findMenus(w.contentView.superview, menus);
        BOOL ok = NO;
        for (NSMenu *m in menus) if (pressMenuItem(m, p[2], log)) { ok = YES; break; }
        [log appendFormat:@"menus=%lu pressed=%d\n", (unsigned long)menus.count, ok];
    } else if ([p[0] isEqual:@"menuopen"] && p.count >= 3) {
        NSWindow *w = findWindow(p[1]);
        NSMutableArray *btns = [NSMutableArray array];
        for (NSToolbarItem *it in w.toolbar.items) if (it.view) findButtons(it.view, btns);
        findButtons(w.contentView.superview, btns);
        NSInteger i = p[2].integerValue;
        [log appendFormat:@"buttons=%lu\n", (unsigned long)btns.count];
        if (i < (NSInteger)btns.count) {
            NSPopUpButton *b = btns[i];
            dispatch_async(dispatch_get_main_queue(), ^{ [b performClick:nil]; });
        }
    } else if ([p[0] isEqual:@"menucancel"]) {
        NSWindow *w = findWindow(p[1]);
        NSMutableArray *btns = [NSMutableArray array];
        for (NSToolbarItem *it in w.toolbar.items) if (it.view) findButtons(it.view, btns);
        findButtons(w.contentView.superview, btns);
        for (NSPopUpButton *b in btns) [b.menu cancelTrackingWithoutAnimation];
    } else if ([p[0] isEqual:@"appearance"] && p.count >= 2) {
        NSApp.appearance = [NSAppearance appearanceNamed:[p[1] isEqual:@"dark"] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        [log appendFormat:@"appearance %@\n", p[1]];
    } else if ([p[0] isEqual:@"resize"] && p.count >= 4) {
        NSWindow *w = findWindow(p[1]);
        if (w) {
            NSRect vf = w.screen.visibleFrame;
            CGFloat W = p[2].doubleValue, H = p[3].doubleValue;
            [w setFrame:NSMakeRect(vf.origin.x + 20, NSMaxY(vf) - H, W, H) display:YES animate:NO];
            [log appendFormat:@"resized '%@' %@\n", w.title, NSStringFromRect(w.frame)];
        } else [log appendString:@"no window\n"];
    } else if ([p[0] isEqual:@"shot"] && p.count >= 3) {
        NSWindow *w = findWindow(p[2]);
        if (w) {
            NSMutableArray *ids = [NSMutableArray array];
            collect(w, ids);
            // Menus / popovers float above the normal level and are not children.
            for (NSWindow *o in NSApp.windows)
                if (o.isVisible && o.level > NSNormalWindowLevel && ![ids containsObject:@(o.windowNumber)]
                    && NSIntersectsRect(o.frame, w.frame)) [ids addObject:@(o.windowNumber)];
            CFMutableArrayRef arr = CFArrayCreateMutable(NULL, 0, NULL);
            for (NSNumber *n in ids.reverseObjectEnumerator) CFArrayAppendValue(arr, (void *)(uintptr_t)n.unsignedIntValue);
            FromArrayFn fn = (FromArrayFn)dlsym(RTLD_DEFAULT, "CGWindowListCreateImageFromArray");
            CGImageRef img = fn ? fn(CGRectNull, arr, (1 << 0) | (1 << 3)) : NULL; // ignoreFraming | bestResolution
            CFRelease(arr);
            // Each window on its own too, with its frame, for compositing offline.
            int k = 0;
            for (NSNumber *n in ids) {
                CFMutableArrayRef one = CFArrayCreateMutable(NULL, 0, NULL);
                CFArrayAppendValue(one, (void *)(uintptr_t)n.unsignedIntValue);
                CGImageRef part = fn ? fn(CGRectNull, one, (1 << 0) | (1 << 3)) : NULL;
                CFRelease(one);
                NSWindow *pw = [NSApp windowWithWindowNumber:n.integerValue];
                if (part && pw) {
                    NSBitmapImageRep *r = [[NSBitmapImageRep alloc] initWithCGImage:part];
                    NSString *o = [tmp stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.part%d.png", p[1], k]];
                    [[r representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:o atomically:YES];
                    [log appendFormat:@"part %d %g %g %g %g\n", k, pw.frame.origin.x - w.frame.origin.x,
                     NSMaxY(w.frame) - NSMaxY(pw.frame), pw.frame.size.width, pw.frame.size.height];
                    k++;
                }
                if (part) CGImageRelease(part);
            }
            if (img) {
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
                NSString *out = [tmp stringByAppendingPathComponent:[p[1] stringByAppendingString:@".png"]];
                [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:out atomically:YES];
                [log appendFormat:@"shot %@ %zux%zu windows=%@\n", out, CGImageGetWidth(img), CGImageGetHeight(img), ids];
                CGImageRelease(img);
            } else [log appendString:@"capture failed\n"];
        } else [log appendString:@"no window\n"];
    }
    [log writeToFile:[tmp stringByAppendingPathComponent:@"cap_result"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

__attribute__((constructor)) static void install(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimer *t = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *_) { tick(); }];
        [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    });
}
