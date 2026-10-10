// Runtime layout fixes for YNAB Classic 3.4.3 on notched / Dynamic Island / home-indicator devices.
// The app predates safe areas: most screens sit inside a UINavigationController (which handles the
// top inset by itself), but a few views use hand-placed frames that assume a 20pt status bar and no
// home indicator. Loaded via an LC_LOAD_DYLIB injected by modernize.sh.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static const CGFloat kLegacyStatusBarHeight = 20;
static const CGFloat kAddButtonMinBottomGap = 11; // the app's original gap below "Add Transaction"
static const void *kFillerKey = &kFillerKey;   // lifted view / toolbar -> its filler strip
static const void *kLiftedKey = &kLiftedKey;   // lifted view -> the maxY we gave it

static UIWindow *YBWindow(UIView *view) {
    if (view.window) return view.window;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (!w.hidden) return w;
    }
    return nil;
}

// How far the bottom safe area (home indicator) reaches into `view`, in its coordinates.
static CGFloat YBBottomOverlap(UIView *view) {
    UIWindow *window = YBWindow(view);
    if (!window) return 0;
    if (!view.window) return window.safeAreaInsets.bottom; // not on screen yet: assume full height
    CGFloat safeBottom = CGRectGetMaxY(window.bounds) - window.safeAreaInsets.bottom;
    CGRect inWindow = [view convertRect:view.bounds toView:window];
    return MAX(0, CGRectGetMaxY(inWindow) - safeBottom);
}

#pragma mark - Screens with a hand-drawn 20pt status bar (side menu, budget picker, ...)

// Some screens don't use a navigation bar: they paint a 20pt status-bar strip at the top of their
// view and lay out everything else with fixed frames below it. Rather than touching every frame,
// scroll the whole view's bounds so the content starts below the real safe area. The full-height
// gradient background is stretched over the revealed band; the status strip is either stretched up
// to the screen edge too or, for the side menu (where the gradient should run to the top), hidden.

static const void *kStatusStripKey = &kStatusStripKey; // status strip view -> @YES

// The 20pt status-bar strips at the top of the view. Screens may add a fresh one every time they
// refresh (the side menu does after each modal sheet closes), so all of them are handled. Strips are
// marked once found, since stretching changes their frame.
static NSArray<UIView *> *YBLegacyStatusStrips(UIView *view) {
    NSMutableArray<UIView *> *strips = [NSMutableArray array];
    for (UIView *sub in view.subviews) {
        CGRect f = sub.frame;
        BOOL marked = objc_getAssociatedObject(sub, kStatusStripKey) != nil;
        if (marked || (CGRectGetMinY(f) == 0 && CGRectGetHeight(f) == kLegacyStatusBarHeight &&
                       CGRectGetWidth(f) >= CGRectGetWidth(view.bounds) && sub.backgroundColor)) {
            objc_setAssociatedObject(sub, kStatusStripKey, @YES, OBJC_ASSOCIATION_RETAIN);
            [strips addObject:sub];
        }
    }
    return strips;
}

static BOOL YBFixLegacyStatusBarScreen(UIViewController *vc, BOOL hideStrip) {
    UIView *view = vc.view;
    UIWindow *window = view.window;
    if (!window) return NO;
    NSArray<UIView *> *strips = YBLegacyStatusStrips(view);
    if (!strips.count) return NO;
    // Only screens whose top edge is the top of the screen are affected.
    if (fabs([view convertPoint:view.bounds.origin toView:window].y) > 0.5) return NO;

    UIEdgeInsets insets = window.safeAreaInsets;
    CGFloat shift = MAX(0, insets.top - kLegacyStatusBarHeight);

    CGRect bounds = view.bounds;
    if (bounds.origin.y != -shift) {
        bounds.origin.y = -shift;
        view.bounds = bounds;
    }

    for (UIView *strip in strips) {
        if (hideStrip) {
            strip.hidden = YES;
        } else {
            CGRect f = CGRectMake(0, -shift, CGRectGetWidth(strip.frame), kLegacyStatusBarHeight + shift);
            if (!CGRectEqualToRect(strip.frame, f)) strip.frame = f;
        }
    }

    static Class gradientClass;
    if (!gradientClass) gradientClass = objc_getClass("YBGradientView") ?: [NSNull class];
    for (UIView *sub in view.subviews) {
        // The full-height gradient background: cover exactly the visible area.
        if ([sub isKindOfClass:gradientClass]) {
            if (!CGRectEqualToRect(sub.frame, view.bounds)) sub.frame = view.bounds;
        }
        // Lists run to the bottom of the view; keep their last rows clear of the home indicator.
        if ([sub isKindOfClass:UITableView.class]) {
            UITableView *table = (UITableView *)sub;
            CGFloat bottom = shift + insets.bottom;
            if (table.contentInset.bottom != bottom) {
                UIEdgeInsets ci = table.contentInset;
                ci.bottom = bottom;
                table.contentInset = ci;
                UIEdgeInsets si = table.verticalScrollIndicatorInsets;
                si.bottom = bottom;
                table.verticalScrollIndicatorInsets = si;
            }
        }
    }
    return YES;
}

#pragma mark - Floating "Add Transaction" / "Save Transaction" buttons

// These buttons (YBAddTransactionButton, YBSaveTransactionButton, YBBottomDoneButton) are placed ~10pt above the bottom of full-height screens, under the home indicator.
// Whenever it's given a frame that ends inside the bottom safe area, lift it so its gap to the
// bottom edge is at least the safe-area inset. Off-screen frames (used by its hide/show
// animations) end below the view and are left alone.

static IMP sAddButtonSetFrame, sSaveButtonSetFrame, sDoneButtonSetFrame;

static CGRect YBLiftedFloatingButtonFrame(UIView *button, CGRect frame) {
    UIView *parent = button.superview;
    CGFloat height = CGRectGetHeight(parent.bounds);
    if (parent && height >= 200) { // i.e. floating over a screen, not placed in a nav bar
        CGFloat wantedGap = MAX(kAddButtonMinBottomGap, YBBottomOverlap(parent));
        CGFloat gap = CGRectGetMaxY(parent.bounds) - CGRectGetMaxY(frame);
        if (gap >= 0 && gap < wantedGap) frame.origin.y -= wantedGap - gap;
    }
    return frame;
}

static void YBDoneButton_setFrame(UIView *self, SEL _cmd, CGRect frame) {
    ((void (*)(id, SEL, CGRect))sDoneButtonSetFrame)(self, _cmd, YBLiftedFloatingButtonFrame(self, frame));
}

static void YBSaveButton_setFrame(UIView *self, SEL _cmd, CGRect frame) {
    ((void (*)(id, SEL, CGRect))sSaveButtonSetFrame)(self, _cmd, YBLiftedFloatingButtonFrame(self, frame));
}

static void YBAddButton_setFrame(UIView *self, SEL _cmd, CGRect frame) {
    ((void (*)(id, SEL, CGRect))sAddButtonSetFrame)(self, _cmd, YBLiftedFloatingButtonFrame(self, frame));
}

#pragma mark - Bottom toolbars (e.g. All Accounts edit mode)

// Some screens slide a UIToolbar in from below by animating its center or frame, with no layout pass
// in between, so it's fixed in -setCenter:/-setFrame:. Whenever the app puts a toolbar flush with
// the bottom, it's lifted above the home indicator, with a strip in the bar's colour hanging below
// it to the screen edge. The strip is a subview of the toolbar, so it slides away with it. (Growing
// the bar instead doesn't work: with this app's SDK, UIToolbar centres its items in the full height.)

static IMP sToolbarSetFrame, sToolbarSetCenter;

static BOOL YBIsAppRootView(UIView *view) {
    UIResponder *owner = view.nextResponder;
    return [owner isKindOfClass:UIViewController.class] && [NSStringFromClass(owner.class) hasPrefix:@"YB"];
}

static CGRect YBToolbarTargetFrame(UIToolbar *toolbar, CGRect frame) {
    UIView *parent = toolbar.superview;
    if (!parent || !YBIsAppRootView(parent)) return frame;
    CGFloat overlap = YBBottomOverlap(parent);
    if (overlap <= 0 || fabs(CGRectGetMaxY(frame) - CGRectGetMaxY(parent.bounds)) >= 0.5) return frame;

    frame.origin.y -= overlap;
    UIView *strip = objc_getAssociatedObject(toolbar, kFillerKey);
    if (!strip) {
        strip = [[UIView alloc] init];
        strip.userInteractionEnabled = NO;
        objc_setAssociatedObject(toolbar, kFillerKey, strip, OBJC_ASSOCIATION_RETAIN);
    }
    strip.backgroundColor = toolbar.backgroundColor ?: toolbar.barTintColor;
    strip.frame = CGRectMake(0, CGRectGetHeight(frame), CGRectGetWidth(frame), overlap);
    if (strip.superview != toolbar) [toolbar insertSubview:strip atIndex:0];
    return frame;
}

static void YBToolbar_setFrame(UIToolbar *self, SEL _cmd, CGRect frame) {
    ((void (*)(id, SEL, CGRect))sToolbarSetFrame)(self, _cmd, YBToolbarTargetFrame(self, frame));
}

static void YBToolbar_setCenter(UIToolbar *self, SEL _cmd, CGPoint center) {
    CGSize size = self.bounds.size;
    CGRect frame = CGRectMake(center.x - size.width / 2, center.y - size.height / 2, size.width, size.height);
    CGRect target = YBToolbarTargetFrame(self, frame);
    center.y += CGRectGetMinY(target) - CGRectGetMinY(frame);
    ((void (*)(id, SEL, CGPoint))sToolbarSetCenter)(self, _cmd, center);
}

#pragma mark - Active search bar (UISearchDisplayController)

// While searching, the search bar sits right under the status bar of the 375x812 layout the app runs
// in, only a few points below the Dynamic Island once scaled up to a modern phone. Push the bar's
// contents (text field and Cancel button) down a little; the bar is taller than its contents, so they
// still fit. The push is proportional to how far the bar has slid up under the status bar (set by
// YBPinSearchBar from inside the slide animation), so it moves on exactly the same frames as the bar.

static const CGFloat kActiveSearchExtraTop = 7;
static const void *kSearchRowStateKey = &kSearchRowStateKey; // row view -> @[y we set, extra in it]
static const void *kSearchBarExtraKey = &kSearchBarExtraKey; // search bar -> @(slide progress, 0...1)
static IMP sSearchBarLayoutSubviews, sSearchBarDidMoveToSuperview;

static void YBCollectSearchBarRowViews(UIView *view, NSMutableArray<UIView *> *out) {
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:UITextField.class] || [sub isKindOfClass:UIButton.class]) {
            [out addObject:sub];
        } else {
            YBCollectSearchBarRowViews(sub, out);
        }
    }
}

static const void *kActiveFieldBaseKey = &kActiveFieldBaseKey; // search bar -> @(field y UIKit uses while searching)

// Moves the field and button so that, at full progress, they sit kActiveSearchExtraTop below where
// UIKit puts them in search mode. UIKit uses two layouts: the normal one (56pt bar, field 10pt down)
// and a compact one while the Cancel button shows (55pt bar, field 4pt down), and it switches between
// them partway through the transition. The push is computed for whichever layout is current, so the
// field's on-screen position stays continuous across the switch.
static void YBApplySearchBarExtra(UISearchBar *bar) {
    CGFloat progress = [objc_getAssociatedObject(bar, kSearchBarExtraKey) doubleValue];
    BOOL compact = bar.showsCancelButton;
    NSMutableArray<UIView *> *rowViews = [NSMutableArray array];
    YBCollectSearchBarRowViews(bar, rowViews);
    for (UIView *v in rowViews) {
        NSArray<NSNumber *> *state = objc_getAssociatedObject(v, kSearchRowStateKey);
        CGRect f = v.frame;
        // If the view is still where we put it, strip our old push; otherwise UIKit re-laid it out.
        CGFloat base = (state && fabs(f.origin.y - state[0].doubleValue) < 0.25) ? f.origin.y - state[1].doubleValue : f.origin.y;
        if ([v isKindOfClass:UITextField.class] && compact) {
            objc_setAssociatedObject(bar, kActiveFieldBaseKey, @(base), OBJC_ASSOCIATION_RETAIN);
        }
        NSNumber *activeBase = objc_getAssociatedObject(bar, kActiveFieldBaseKey);
        // Buttons (Cancel) only exist in the compact layout.
        CGFloat target = compact || ![v isKindOfClass:UITextField.class]
            ? base + kActiveSearchExtraTop
            : (activeBase ? activeBase.doubleValue : base - 6) + kActiveSearchExtraTop;
        CGFloat wanted = (target - base) * progress;
        if (fabs(f.origin.y - (base + wanted)) >= 0.01) {
            f.origin.y = base + wanted;
            v.frame = f;
        }
        objc_setAssociatedObject(v, kSearchRowStateKey, @[@(f.origin.y), @(wanted)], OBJC_ASSOCIATION_RETAIN);
    }
}

static void YBSetSearchBarExtra(UISearchBar *bar, CGFloat extra) {
    if (fabs([objc_getAssociatedObject(bar, kSearchBarExtraKey) doubleValue] - extra) < 0.01) return;
    objc_setAssociatedObject(bar, kSearchBarExtraKey, @(extra), OBJC_ASSOCIATION_RETAIN);
    YBApplySearchBarExtra(bar); // runs inside the caller's animation, if any
}

static void YBSearchBar_layoutSubviews(UISearchBar *self, SEL _cmd) {
    ((void (*)(id, SEL))sSearchBarLayoutSubviews)(self, _cmd);
    YBApplySearchBarExtra(self);
}

// The bar is laid out before UISearchDisplayController moves it into its container (and back), so
// lay it out again whenever it changes parent.
static void YBSearchBar_didMoveToSuperview(UISearchBar *self, SEL _cmd) {
    ((void (*)(id, SEL))sSearchBarDidMoveToSuperview)(self, _cmd);
    [self setNeedsLayout];
}

#pragma mark - Views pinned to the bottom edge

// Some screens pin small views (e.g. the version footer in Settings) flush to the bottom of a view
// that runs under the home indicator. Lift them above it, and fill the gap left below with the
// view's own background colour so it still reads as reaching the screen edge.

static void YBFixBottomPinnedViews(UIViewController *vc) {
    UIView *root = vc.view;
    CGFloat overlap = YBBottomOverlap(root);
    if (overlap <= 0 || !root.window) return;

    CGFloat bottom = CGRectGetMaxY(root.bounds);
    Class addButton = objc_getClass("YBAddTransactionButton");
    for (UIView *sub in root.subviews.copy) {
        if (sub.hidden || [sub isKindOfClass:UIScrollView.class] || [sub isKindOfClass:addButton] ||
            [sub isKindOfClass:objc_getClass("YBSaveTransactionButton")] ||
            [sub isKindOfClass:objc_getClass("YBBottomDoneButton")]) continue;
        if ([sub isKindOfClass:UIToolbar.class]) continue; // handled by YBToolbar_setFrame
        CGRect f = sub.frame;
        if (CGRectGetHeight(f) > CGRectGetHeight(root.bounds) / 2) continue; // backgrounds, containers

        // Lift views flush with the bottom edge; re-target ones we lifted before (the inset may have
        // changed), unless the app has since moved them somewhere else.
        NSNumber *liftedMaxY = objc_getAssociatedObject(sub, kLiftedKey);
        BOOL pinned = fabs(CGRectGetMaxY(f) - bottom) < 0.5;
        BOOL ours = liftedMaxY && fabs(CGRectGetMaxY(f) - liftedMaxY.doubleValue) < 0.5;
        if (!pinned && !ours) continue;

        CGFloat targetMaxY = bottom - overlap;
        if (fabs(CGRectGetMaxY(f) - targetMaxY) >= 0.5) {
            f.origin.y = targetMaxY - CGRectGetHeight(f);
            sub.frame = f;
        }
        objc_setAssociatedObject(sub, kLiftedKey, @(targetMaxY), OBJC_ASSOCIATION_RETAIN);

        // The filler is a subview hanging below the lifted view, so it moves (and leaves) with it
        // when the app animates the view elsewhere.
        UIView *filler = objc_getAssociatedObject(sub, kFillerKey);
        if (!filler && sub.backgroundColor && !sub.clipsToBounds) {
            filler = [[UIView alloc] init];
            filler.userInteractionEnabled = NO;
            objc_setAssociatedObject(sub, kFillerKey, filler, OBJC_ASSOCIATION_RETAIN);
        }
        if (filler) {
            filler.backgroundColor = sub.backgroundColor;
            filler.frame = CGRectMake(0, CGRectGetHeight(f), CGRectGetWidth(f), overlap);
            if (filler.superview != sub) [sub insertSubview:filler atIndex:0];
        }
    }
}

#pragma mark - Search bar table headers

// Lists put their UISearchBar in a 44pt table header view, the search bar height of the SDK the app
// was built with. Current iOS draws it 56pt tall, so its bottom hangs under the first section header
// and the search field looks cut off (most visibly while the "Syncing..." pull-to-refresh banner is
// shown). Grow the header to fit; re-assigning tableHeaderView makes the table re-measure it.

static void YBFixSearchBarHeaders(UIViewController *vc) {
    for (UIView *sub in vc.view.subviews) {
        if (![sub isKindOfClass:UITableView.class]) continue;
        UITableView *table = (UITableView *)sub;
        UIView *header = table.tableHeaderView;
        if (!header || [header isKindOfClass:UISearchBar.class]) continue;
        for (UIView *bar in header.subviews) {
            if (![bar isKindOfClass:UISearchBar.class] || bar.hidden) continue;
            CGFloat needed = CGRectGetMaxY(bar.frame);
            if (needed > CGRectGetHeight(header.frame) + 0.5) {
                CGRect f = header.frame;
                f.size.height = needed;
                header.frame = f;
                table.tableHeaderView = header;
            }
            break;
        }
    }
}

#pragma mark - Searchable lists: smooth search transitions

// UISearchDisplayController slides the navigation bar away while searching, and the screen's content
// view moves up with it by the nav bar *and* status bar height, so its top edge ends up under the
// Dynamic Island. The search bar rides along (still in the list's header), then lands 44pt lower when
// it's moved into the search container; ending the search does the reverse, leaving a white gap that
// snaps shut. The controller was written for a 20pt status bar it could simply overlap.
//
// Fix: whenever the content view is moved, keep the search bar pinned just below the status bar —
// while it sits in the list's header via a matching top inset on the table, and while it sits in the
// search container via a matching offset on its holder view. These are applied from inside the
// content view's own frame change, so they follow the same animation curve.
//
// Automatic safe-area insets are also switched off on the searched table during the search, since
// iOS would otherwise add its own top inset when the content slides under the status bar.

static IMP sSearchDisplaySetActive;
static const void *kSavedInsetBehaviorKey = &kSavedInsetBehaviorKey; // table -> @(behavior)
static const void *kPinnedTopKey = &kPinnedTopKey;                   // table -> @(top inset we added)
static const void *kSearchHostVCKey = &kSearchHostVCKey;             // content view -> its view controller

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations" // the app's own search API

static const void *kSettingActiveKey = &kSettingActiveKey; // search controller -> @YES inside setActive:animated:

static UITableView *YBSearchedTable(UIViewController *vc) {
    for (UIView *sub in vc.view.subviews) {
        if ([sub isKindOfClass:UITableView.class]) return (UITableView *)sub;
    }
    return nil;
}

// Height of the status bar the app's navigation bar is laid out under. Usually the same as the
// window's top safe-area inset, but in iOS 26's compatibility mode the safe area is larger (58pt in a
// 375x812 layout on an iPhone 17 Pro) while the status bar and navigation bar stay at 44pt.
static CGFloat YBStatusBarHeight(UIWindow *window) {
    CGFloat h = CGRectGetHeight(window.windowScene.statusBarManager.statusBarFrame);
    return h > 0 ? h : window.safeAreaInsets.top;
}

// How far the content view's top edge is above the bottom of the status bar.
static CGFloat YBContentOverlapWithStatusBar(UIView *view) {
    UIWindow *window = view.window;
    if (!window || !view.superview) return 0;
    CGFloat top = [view.superview convertPoint:view.frame.origin toView:window].y;
    return MAX(0, YBStatusBarHeight(window) - top);
}

static void YBInstallFrameHook(UIView *view, NSString *prefix, IMP setFrameImp, IMP setCenterImp);
static void YBSearchBarHolder_setFrame(UIView *self, SEL _cmd, CGRect frame);
static CGFloat YBSearchBarHolderTop(UIViewController *vc);
static void YBSearchBarHolder_setCenter(UIView *self, SEL _cmd, CGPoint center);
static void YBDimmingHolder_setFrame(UIView *self, SEL _cmd, CGRect frame);
static void YBDimmingHolder_setCenter(UIView *self, SEL _cmd, CGPoint center);

// The pull-to-refresh code gives the list absolute top insets (60pt while the "Syncing..." banner
// shows, 0 when it's hidden), which would wipe out the pin added below for the search, so the list
// jumped and left a gap when a sync started, updated or ended during a search. The searched list gets
// a private subclass whose setContentInset: remembers the app's top inset and applies the pin on top.
// While a search is active the banner's space is left out: the banner is hidden then and the list
// belongs right under the search bar; it comes back as the search ends.
static const void *kAppTopInsetKey = &kAppTopInsetKey; // searched table -> @(top inset the app asked for)
static const void *kSearchedTableVCKey = &kSearchedTableVCKey; // searched table -> its view controller

static CGFloat YBSearchedTableTop(UITableView *table) {
    UIViewController *vc = objc_getAssociatedObject(table, kSearchedTableVCKey);
    CGFloat pinned = [objc_getAssociatedObject(table, kPinnedTopKey) doubleValue];
    CGFloat appTop = [objc_getAssociatedObject(table, kAppTopInsetKey) doubleValue];
    return pinned + (vc.searchDisplayController.active ? 0 : appTop);
}

static void YBSearchedTable_setContentInset(UITableView *self, SEL _cmd, UIEdgeInsets inset) {
    if (fabs(inset.top - YBSearchedTableTop(self)) >= 0.5) {
        objc_setAssociatedObject(self, kAppTopInsetKey, @(inset.top), OBJC_ASSOCIATION_RETAIN);
        inset.top = YBSearchedTableTop(self);
    }
    struct objc_super sup = { self, class_getSuperclass(object_getClass(self)) };
    ((void (*)(struct objc_super *, SEL, UIEdgeInsets))objc_msgSendSuper)(&sup, _cmd, inset);
}

static void YBInstallSearchedTableHook(UITableView *table, UIViewController *vc) {
    Class base = object_getClass(table);
    if ([NSStringFromClass(base) hasPrefix:@"YBSearchedTable_"]) return;
    objc_setAssociatedObject(table, kSearchedTableVCKey, vc, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(table, kAppTopInsetKey,
                             @(table.contentInset.top - [objc_getAssociatedObject(table, kPinnedTopKey) doubleValue]),
                             OBJC_ASSOCIATION_RETAIN);
    NSString *name = [@"YBSearchedTable_" stringByAppendingString:NSStringFromClass(base)];
    Class host = NSClassFromString(name);
    if (!host) {
        host = objc_allocateClassPair(base, name.UTF8String, 0);
        if (!host) return;
        class_addMethod(host, @selector(setContentInset:), (IMP)YBSearchedTable_setContentInset,
                        method_getTypeEncoding(class_getInstanceMethod(base, @selector(setContentInset:))));
        objc_registerClassPair(host);
    }
    object_setClass(table, host);
}

static void YBPinSearchBar(UIViewController *vc) {
    UISearchDisplayController *sdc = vc.searchDisplayController;
    UITableView *table = YBSearchedTable(vc);
    UISearchBar *bar = sdc.searchBar;
    if (!sdc || !table || !bar) return;
    CGFloat overlap = YBContentOverlapWithStatusBar(vc.view);

    // Field/Cancel push, proportional to how far the bar has slid under the status bar. Only the
    // search's own start/end animation drives it: while a search stays active, the content view is
    // also moved by navigation transitions (e.g. coming back from a category opened from the results),
    // which must not take the push away and put it back afterwards.
    CGFloat statusTop = vc.view.window ? YBStatusBarHeight(vc.view.window) : 0;
    CGFloat progress = statusTop > kLegacyStatusBarHeight ? MIN(1, overlap / statusTop) : 0;
    if (sdc.active && !objc_getAssociatedObject(sdc, kSettingActiveKey)) progress = 1;
    YBSetSearchBarExtra(bar, progress);

    // The list (and the search bar while it's in the list's header). Its top inset is the app's own
    // (the "Syncing..." banner's space) plus the pin; the offset moves by the same amount, so the list
    // keeps its place relative to the bar.
    YBInstallSearchedTableHook(table, vc);
    objc_setAssociatedObject(table, kPinnedTopKey, @(overlap), OBJC_ASSOCIATION_RETAIN);
    CGFloat wanted = YBSearchedTableTop(table);
    CGFloat delta = wanted - table.contentInset.top;
    if (fabs(delta) >= 0.5) {
        UIEdgeInsets inset = table.contentInset;
        inset.top = wanted;
        CGPoint offset = table.contentOffset;
        offset.y -= delta;
        table.contentInset = inset; // already the value the hook wants, so it passes through
        table.contentOffset = offset;
    }

    // The search bar's holder inside the search container (UIKit offsets it by the full status bar
    // height, assuming the container starts at the top of the screen).
    UIView *holder = bar.superview;
    if (holder && holder != table && ![holder isKindOfClass:UITableView.class] && holder.superview &&
        [NSStringFromClass(holder.superview.class) containsString:@"SearchDisplayControllerContainerView"]) {
        YBInstallFrameHook(holder, @"YBSearchBarHolder_", (IMP)YBSearchBarHolder_setFrame, (IMP)YBSearchBarHolder_setCenter);
        if (fabs(CGRectGetMinY(holder.frame) - YBSearchBarHolderTop(vc)) >= 0.5) holder.frame = holder.frame; // re-clamped by the hook

        // The dimming view's holder (re-clamped by its hook, in the same animation as the bar's).
        for (UIView *sub in holder.superview.subviews) {
            if ([NSStringFromClass(object_getClass(sub)) hasPrefix:@"YBDimmingHolder_"]) sub.frame = sub.frame;
        }
    }
}

// The view in the search container that holds the dimming view over the list. UIKit gives it a fixed
// place in the container, which slides up with the screen's content view (88pt as the navigation bar
// goes away), while the search bar, pinned below the status bar, moves only half that. So when a search
// starts, the darkening's top edge starts well below the bar and catches up, and seems to grow out of
// the first section header. Keep its top glued to the bottom of the search bar instead. The hook goes
// on as soon as the dimming view is added, before UIKit positions its holder for the first search.
static IMP sDimmingViewDidMoveToSuperview;

static void YBDimmingView_didMoveToSuperview(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))sDimmingViewDidMoveToSuperview)(self, _cmd);
    if (self.superview) YBInstallFrameHook(self.superview, @"YBDimmingHolder_", (IMP)YBDimmingHolder_setFrame, (IMP)YBDimmingHolder_setCenter);
}

// The bottom of the search bar, in the container's coordinates. Inside an animation this is where the
// bar and container are going (so the holder animates on the same curve as the bar); outside one it's
// where the bar is on screen right now, relative to the content view, as a newly added container
// hasn't been drawn yet and has no on-screen position of its own.
static CGFloat YBDimmingHolderTop(UIView *dimHolder) {
    UIView *container = dimHolder.superview;
    if (![NSStringFromClass(container.class) containsString:@"SearchDisplayControllerContainerView"]) return NAN;
    UIViewController *vc = objc_getAssociatedObject(container.superview, kSearchHostVCKey);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UISearchBar *bar = vc.searchDisplayController.searchBar;
#pragma clang diagnostic pop
    if (!bar.window || bar.window != container.window) return NAN;
    if ([UIView inheritedAnimationDuration] > 0) return CGRectGetMaxY([bar convertRect:bar.bounds toView:container]);
    CALayer *barLayer = bar.layer.presentationLayer ?: bar.layer;
    CALayer *contentLayer = container.superview.layer.presentationLayer ?: container.superview.layer;
    return CGRectGetMaxY([barLayer convertRect:barLayer.bounds toLayer:contentLayer]) - CGRectGetMinY(container.frame);
}

static void YBDimmingHolder_setFrame(UIView *self, SEL _cmd, CGRect frame) {
    CGFloat top = YBDimmingHolderTop(self);
    if (!isnan(top)) {
        frame.origin.y = top;
        frame.size.height = MAX(0, CGRectGetHeight(self.superview.bounds) - top);
    }
    struct objc_super sup = { self, class_getSuperclass(object_getClass(self)) };
    ((void (*)(struct objc_super *, SEL, CGRect))objc_msgSendSuper)(&sup, _cmd, frame);
}

// UIKit moves the holder by its centre when the search ends, keeping a height worked out for an
// earlier position, so its bottom edge would rise off the screen edge as the content view slides back
// down, uncovering a white strip under the Add Transaction button. Treat it like a frame change, so
// the holder always reaches the bottom of the container.
static void YBDimmingHolder_setCenter(UIView *self, SEL _cmd, CGPoint center) {
    struct objc_super sup = { self, class_getSuperclass(object_getClass(self)) };
    if (isnan(YBDimmingHolderTop(self))) {
        ((void (*)(struct objc_super *, SEL, CGPoint))objc_msgSendSuper)(&sup, _cmd, center);
        return;
    }
    CGRect frame = self.frame;
    frame.origin.x = center.x - CGRectGetWidth(frame) / 2;
    YBDimmingHolder_setFrame(self, @selector(setFrame:), frame);
}

// The search bar's holder inside the search container: UIKit keeps re-placing it at the full status
// bar height, so clamp every frame it's given to the content view's current overlap instead.
static UIViewController *YBHolderContentsVC(UIView *holder) {
    UIView *container = holder.superview;
    if (![NSStringFromClass(container.class) containsString:@"SearchDisplayControllerContainerView"]) return nil;
    return objc_getAssociatedObject(container.superview, kSearchHostVCKey);
}

// Where the search bar's holder belongs: just below the status bar, plus, while the search ends
// during a sync, the "Syncing..." banner's space the list now has above its header, so the bar lands
// in the header without a gap below it or a drop at the end.
static CGFloat YBSearchBarHolderTop(UIViewController *vc) {
    CGFloat top = YBContentOverlapWithStatusBar(vc.view);
    UITableView *table = YBSearchedTable(vc);
    if (table && !vc.searchDisplayController.active) top += [objc_getAssociatedObject(table, kAppTopInsetKey) doubleValue];
    return top;
}

static void YBSearchBarHolder_setFrame(UIView *self, SEL _cmd, CGRect frame) {
    UIViewController *vc = YBHolderContentsVC(self);
    if (vc) frame.origin.y = YBSearchBarHolderTop(vc);
    struct objc_super sup = { self, class_getSuperclass(object_getClass(self)) };
    ((void (*)(struct objc_super *, SEL, CGRect))objc_msgSendSuper)(&sup, _cmd, frame);
}

static void YBSearchBarHolder_setCenter(UIView *self, SEL _cmd, CGPoint center) {
    UIViewController *vc = YBHolderContentsVC(self);
    if (vc) center.y = YBSearchBarHolderTop(vc) + CGRectGetHeight(self.bounds) / 2;
    struct objc_super sup = { self, class_getSuperclass(object_getClass(self)) };
    ((void (*)(struct objc_super *, SEL, CGPoint))objc_msgSendSuper)(&sup, _cmd, center);
}

static void YBInstallFrameHook(UIView *view, NSString *prefix, IMP setFrameImp, IMP setCenterImp) {
    Class base = object_getClass(view);
    if ([NSStringFromClass(base) hasPrefix:prefix]) return;
    NSString *name = [prefix stringByAppendingString:NSStringFromClass(base)];
    Class host = NSClassFromString(name);
    if (!host) {
        host = objc_allocateClassPair(base, name.UTF8String, 0);
        if (!host) return;
        class_addMethod(host, @selector(setFrame:), setFrameImp,
                        method_getTypeEncoding(class_getInstanceMethod(base, @selector(setFrame:))));
        class_addMethod(host, @selector(setCenter:), setCenterImp,
                        method_getTypeEncoding(class_getInstanceMethod(base, @selector(setCenter:))));
        objc_registerClassPair(host);
    }
    object_setClass(view, host);
}

// The floating buttons (Add Transaction, ...) have no autoresizing, so when the search hides the
// navigation bar and the content view grows by its height, they'd keep their old y and ride up the
// screen with the list. Move them by the change in height instead, so they keep their distance to the
// bottom edge (also for off-screen, hidden positions) and stay put on screen.
static void YBKeepFloatingButtonsAtBottom(UIView *view, CGFloat oldHeight) {
    CGFloat delta = CGRectGetHeight(view.bounds) - oldHeight;
    if (fabs(delta) < 0.5) return;
    for (UIView *sub in view.subviews) {
        if (![sub isKindOfClass:objc_getClass("YBAddTransactionButton")] &&
            ![sub isKindOfClass:objc_getClass("YBSaveTransactionButton")] &&
            ![sub isKindOfClass:objc_getClass("YBBottomDoneButton")]) continue;
        CGRect f = sub.frame;
        f.origin.y += delta;
        sub.frame = f;
    }
}

static void YBSearchHost_setFrame(UIView *self, SEL _cmd, CGRect frame) {
    CGFloat oldHeight = CGRectGetHeight(self.bounds);
    struct objc_super sup = { self, class_getSuperclass(object_getClass(self)) };
    ((void (*)(struct objc_super *, SEL, CGRect))objc_msgSendSuper)(&sup, _cmd, frame);
    YBKeepFloatingButtonsAtBottom(self, oldHeight);
    UIViewController *vc = objc_getAssociatedObject(self, kSearchHostVCKey);
    if (vc) YBPinSearchBar(vc);
}

static void YBSearchHost_setCenter(UIView *self, SEL _cmd, CGPoint center) {
    struct objc_super sup = { self, class_getSuperclass(object_getClass(self)) };
    ((void (*)(struct objc_super *, SEL, CGPoint))objc_msgSendSuper)(&sup, _cmd, center);
    UIViewController *vc = objc_getAssociatedObject(self, kSearchHostVCKey);
    if (vc) YBPinSearchBar(vc);
}

// Gives the content view of a screen with a search controller a private subclass that watches its
// frame (like KVO does), so nothing else in the app pays for the hook.
static void YBInstallSearchHost(UIViewController *vc) {
    UIView *view = vc.view;
    if (!vc.searchDisplayController || objc_getAssociatedObject(view, kSearchHostVCKey)) return;
    YBInstallFrameHook(view, @"YBSearchHost_", (IMP)YBSearchHost_setFrame, (IMP)YBSearchHost_setCenter);
    objc_setAssociatedObject(view, kSearchHostVCKey, vc, OBJC_ASSOCIATION_ASSIGN);
    // Track the list's own top inset (the "Syncing..." banner's space) from the start, so it's known
    // when the first search begins.
    UITableView *table = YBSearchedTable(vc);
    if (table) YBInstallSearchedTableHook(table, vc);
}

static UIColor *YBNavigationBarColor(UINavigationBar *bar) {
    if (bar.barTintColor) return bar.barTintColor;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:bar];
    while (queue.count) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (v != bar && v.backgroundColor && CGColorGetAlpha(v.backgroundColor.CGColor) > 0.99 &&
            CGRectGetHeight(v.bounds) >= 44) return v.backgroundColor;
        [queue addObjectsFromArray:v.subviews];
    }
    return nil;
}

static UIImage *YBSolidImage(UIColor *color) {
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(1, 1)];
    return [[r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [color setFill];
        [ctx fillRect:CGRectMake(0, 0, 1, 1)];
    }] resizableImageWithCapInsets:UIEdgeInsetsZero];
}

static const void *kSavedTableColorKey = &kSavedTableColorKey; // table -> colour strip above its content

// While searching (and while the search animates away):
//  - the strip of list above the search bar that gets exposed shows the bar's own colour instead of
//    the white pull-to-refresh view;
//  - the search bar keeps the app's colour when it's pinned under the status bar (instead of iOS grey);
//  - any gap between the sliding navigation bar and the content shows the navigation bar's colour.
static void YBSetSearchCosmetics(UISearchDisplayController *sdc, UITableView *table, BOOL searching) {
    UISearchBar *bar = sdc.searchBar;
    UIColor *barColor = bar.backgroundColor;
    for (UIView *sub in table.subviews) {
        if ([NSStringFromClass(sub.class) containsString:@"PullToRefresh"]) sub.hidden = searching;
    }
    UIView *strip = objc_getAssociatedObject(table, kSavedTableColorKey);
    if (searching) {
        // Colour only the area above the list's content, not the gaps between its sections.
        if (barColor) {
            if (!strip) {
                strip = [[UIView alloc] init];
                strip.userInteractionEnabled = NO;
                objc_setAssociatedObject(table, kSavedTableColorKey, strip, OBJC_ASSOCIATION_RETAIN);
            }
            // Mid-sync the strip fills the hidden "Syncing..." banner's space as the list slides up;
            // give it the grey the search bar turns while searching rather than a block of bar colour.
            BOOL syncing = [objc_getAssociatedObject(table, kAppTopInsetKey) doubleValue] > 0;
            strip.backgroundColor = syncing ? [UIColor colorWithRed:0xc1/255.0 green:0xc7/255.0 blue:0xcc/255.0 alpha:1] : barColor;
            strip.frame = CGRectMake(0, -2000, MAX(CGRectGetWidth(table.bounds), 2000), 2000);
            strip.hidden = NO;
            [table insertSubview:strip atIndex:0];
        }
        if (barColor && ![bar backgroundImageForBarPosition:UIBarPositionTopAttached barMetrics:UIBarMetricsDefault]) {
            [bar setBackgroundImage:YBSolidImage(barColor) forBarPosition:UIBarPositionTopAttached barMetrics:UIBarMetricsDefault];
        }
        UINavigationController *nav = sdc.searchContentsController.navigationController;
        UIColor *navColor = YBNavigationBarColor(nav.navigationBar);
        if (navColor) nav.view.backgroundColor = navColor;
    } else {
        strip.hidden = YES;
    }
}

// When a search ends, the app reloads the list (from refreshView:) just before UIKit starts the
// slide-back animation, so its rows are only recreated during that animation. Rows created then
// start from a stale position about 16pt off and slide into place, so the categories jump up and
// drift relative to their section headers. Lay the list out straight after that reload, outside any
// animation, so the rows are already in place when the animation starts.
static IMP sTableReloadData;
static const void *kEndingSearchKey = &kEndingSearchKey; // searched table -> @YES while its search ends

static void YBTable_reloadData(UITableView *self, SEL _cmd) {
    ((void (*)(id, SEL))sTableReloadData)(self, _cmd);
    if (objc_getAssociatedObject(self, kEndingSearchKey)) {
        [UIView performWithoutAnimation:^{ [self layoutIfNeeded]; }];
    }
}

static void YBSearchDisplay_setActive(UISearchDisplayController *self, SEL _cmd, BOOL active, BOOL animated) {
    UIViewController *contents = self.searchContentsController;
    UITableView *table = contents.isViewLoaded ? YBSearchedTable(contents) : nil;
    if (active && table && !objc_getAssociatedObject(table, kSavedInsetBehaviorKey)) {
        objc_setAssociatedObject(table, kSavedInsetBehaviorKey, @(table.contentInsetAdjustmentBehavior), OBJC_ASSOCIATION_RETAIN);
        table.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        YBSetSearchCosmetics(self, table, YES);
    }
    // UIKit already insets the results list by the status bar and search bar; the automatic safe-area
    // inset on top of that left an empty row's worth of space above the first result.
    if (active) self.searchResultsTableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    if (!active && table) {
        objc_setAssociatedObject(table, kEndingSearchKey, @YES, OBJC_ASSOCIATION_RETAIN);
        // Mid-sync the list slides back down with the "Syncing..." banner's space above the search
        // bar, so show the banner right away; it slides in with the list. It starts out under the
        // status bar, before the navigation bar has slid back over that strip, so cover the strip with
        // the navigation bar's colour for the length of the animation.
        if ([objc_getAssociatedObject(table, kAppTopInsetKey) doubleValue] > 0) {
            for (UIView *sub in table.subviews) {
                if ([NSStringFromClass(sub.class) containsString:@"PullToRefresh"]) sub.hidden = NO;
            }
            // The banner is narrower than the screen; its sides belong white, not the bar colour.
            [objc_getAssociatedObject(table, kSavedTableColorKey) setHidden:YES];
            UINavigationController *nav = contents.navigationController;
            UIColor *navColor = YBNavigationBarColor(nav.navigationBar);
            UIWindow *window = nav.view.window;
            if (navColor && window && nav.isViewLoaded) {
                UIView *cover = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(nav.view.bounds), YBStatusBarHeight(window))];
                cover.backgroundColor = navColor;
                cover.userInteractionEnabled = NO;
                // The navigation bar is out of the hierarchy while searching; the cover only spans the
                // status bar strip, above the bar's buttons and title, so it can simply go on top.
                [nav.view addSubview:cover];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((animated ? 0.6 : 0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [cover removeFromSuperview];
                });
            }
        }
    }
    objc_setAssociatedObject(self, kSettingActiveKey, @YES, OBJC_ASSOCIATION_RETAIN);
    ((void (*)(id, SEL, BOOL, BOOL))sSearchDisplaySetActive)(self, _cmd, active, animated);
    objc_setAssociatedObject(self, kSettingActiveKey, nil, OBJC_ASSOCIATION_RETAIN);
    if (table) objc_setAssociatedObject(table, kEndingSearchKey, nil, OBJC_ASSOCIATION_RETAIN);
    if (!active && table) {
        // Restore automatic insets once the navigation bar is back (nothing changes at that point).
        __weak UISearchDisplayController *weakSelf = self;
        __weak UITableView *weakTable = table;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((animated ? 0.6 : 0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UITableView *t = weakTable;
            if (!t || weakSelf.active) return;
            NSNumber *saved = objc_getAssociatedObject(t, kSavedInsetBehaviorKey);
            if (!saved) return;
            t.contentInsetAdjustmentBehavior = saved.integerValue;
            objc_setAssociatedObject(t, kSavedInsetBehaviorKey, nil, OBJC_ASSOCIATION_RETAIN);
            YBSetSearchCosmetics(weakSelf, t, NO);
        });
    }
}

#pragma clang diagnostic pop

// The search results list fills the whole search container, including the strip behind the status
// bar, where the search bar's background is translucent; once results show, that strip turns a lighter
// grey than the rest of the bar. Mask the list off above the bottom of the status bar so the strip
// shows the same thing as before anything was typed. The mask isn't moved during animations: when the
// search ends the list is laid out for where it's going, and moving the mask there at once would show
// the white list behind the status bar while it slides away.
static IMP sSearchResultsLayoutSubviews;

static void YBSearchResults_layoutSubviews(UITableView *self, SEL _cmd) {
    ((void (*)(id, SEL))sSearchResultsLayoutSubviews)(self, _cmd);
    UIWindow *window = self.window;
    if (!window || (self.layer.mask && [UIView inheritedAnimationDuration] > 0)) return;
    CGFloat top = [self convertPoint:CGPointMake(0, YBStatusBarHeight(window)) fromView:nil].y;
    CALayer *mask = self.layer.mask;
    if (!mask) {
        mask = [CALayer layer];
        mask.backgroundColor = UIColor.blackColor.CGColor;
        self.layer.mask = mask;
    }
    CGRect frame = CGRectMake(0, top, CGRectGetWidth(self.bounds), MAX(0, CGRectGetMaxY(self.bounds) - top));
    if (!CGRectEqualToRect(mask.frame, frame)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        mask.frame = frame;
        [CATransaction commit];
    }
}

#pragma mark - Amount keypad (YBKeypad) and amount block

// The keypad sizes its keys from the screen width and stacks them at the bottom of the "available
// height" it's given (the whole screen below the navigation bar), so on tall screens its last row sits
// under the home indicator and there's an empty band above it. Give it the height above the home
// indicator instead (it lays out all keys, including the NEXT/DONE key it rebuilds, from that), and
// grow the amount block to fill the band. The amount block height is the app's theme value, which the
// transaction details screen and the screen-change snapshot also use, so they stay in step.

static IMP sKeypadAvailableHeight, sInitInflowOutflowButtons;
static CGFloat sAmountAreaExtra;
static BOOL sAmountAreaExtraLoaded;

// The extra height is measured on the amount entry screen the first time it's shown, then remembered
// per screen geometry so later launches use it from the start (e.g. when editing a transaction opens
// the details screen before any amount screen has been built).
static NSString *YBAmountExtraDefaultsKey(void) {
    UIWindow *window = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) { if (!w.hidden) { window = w; break; } }
    if (!window) return nil;
    CGSize screen = UIScreen.mainScreen.bounds.size;
    UIEdgeInsets i = window.safeAreaInsets;
    return [NSString stringWithFormat:@"YBModernAmountAreaExtra-%.0fx%.0f-%.0f-%.0f", screen.width, screen.height, i.top, i.bottom];
}

static void YBLoadAmountAreaExtra(void) {
    if (sAmountAreaExtraLoaded) return;
    NSString *key = YBAmountExtraDefaultsKey();
    if (!key) return;
    sAmountAreaExtraLoaded = YES;
    sAmountAreaExtra = MAX(sAmountAreaExtra, [NSUserDefaults.standardUserDefaults doubleForKey:key]);
}

static CGFloat YBHomeIndicatorInset(void) {
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        if (!w.hidden) return w.safeAreaInsets.bottom;
    }
    return 0;
}

static CGFloat YBKeypad_availableHeight(id self, SEL _cmd) {
    CGFloat h = ((double (*)(id, SEL))sKeypadAvailableHeight)(self, _cmd);
    return MAX(0, h - YBHomeIndicatorInset());
}

// Every theme class that implements transactionAmountAreaHeight (the app uses a subclass) gets the
// extra height added on top of its own value.
static void YBHookAmountAreaHeight(void) {
    Class base = objc_getClass("YBTheme");
    SEL sel = sel_registerName("transactionAmountAreaHeight");
    if (!base) return;
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        BOOL isTheme = NO;
        for (Class c = cls; c; c = class_getSuperclass(c)) { if (c == base) { isTheme = YES; break; } }
        if (!isTheme) continue;
        unsigned int n = 0;
        Method *methods = class_copyMethodList(cls, &n);
        for (unsigned int j = 0; j < n; j++) {
            if (method_getName(methods[j]) != sel) continue;
            IMP orig = method_getImplementation(methods[j]);
            method_setImplementation(methods[j], imp_implementationWithBlock(^CGFloat(id theme) {
                YBLoadAmountAreaExtra();
                return ((double (*)(id, SEL))orig)(theme, sel) + sAmountAreaExtra;
            }));
        }
        free(methods);
    }
    free(classes);
}

// The transaction details screen shows the amount as its first row, sized from the theme. If it was
// built before the extra height was known (e.g. when editing an existing transaction), resize it.
static void YBRefreshTransactionDetailScreens(UIViewController *root) {
    if (!root) return;
    static Class detailClass;
    if (!detailClass) detailClass = objc_getClass("YBTransactionDetailViewController") ?: [NSNull class];
    if ([root isKindOfClass:detailClass] && root.isViewLoaded) {
        id theme = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("YBTheme"), sel_registerName("currentTheme"));
        CGFloat height = ((double (*)(id, SEL))objc_msgSend)(theme, sel_registerName("transactionAmountAreaHeight"));
        UITableViewCell *cell = nil;
        @try { cell = [root valueForKey:@"amountCell"]; } @catch (NSException *e) {}
        UIView *label = [cell.contentView viewWithTag:123];
        if (label) {
            CGRect f = label.frame;
            f.size.height = height;
            label.frame = f;
        }
        for (UIView *sub in root.view.subviews) {
            if ([sub isKindOfClass:UITableView.class]) [(UITableView *)sub reloadData];
        }
    }
    for (UIViewController *child in root.childViewControllers) YBRefreshTransactionDetailScreens(child);
    YBRefreshTransactionDetailScreens(root.presentedViewController);
}

// Runs once the amount entry screen has laid out its amount block and Expense/Income buttons (the
// keypad already exists). Measures the gap above the keypad and grows the block into it. Once the
// theme includes the extra height, later screens are built at the right size and the gap is zero.
static void YBAmountEntry_initInflowAndOutflowButtons(UIViewController *self, SEL _cmd) {
    ((void (*)(id, SEL))sInitInflowOutflowButtons)(self, _cmd);
    UIView *background = nil, *outflow = nil, *inflow = nil, *keypad = nil;
    @try {
        background = [self valueForKey:@"amountBackground"];
        outflow = [self valueForKey:@"outflowButton"];
        inflow = [self valueForKey:@"inflowButton"];
        keypad = [self valueForKey:@"keypad"];
    } @catch (NSException *e) { return; }
    SEL firstRow = sel_registerName("yForFirstRow");
    if (!background || !outflow || ![keypad respondsToSelector:firstRow]) return;
    CGFloat keypadTop = ((double (*)(id, SEL))objc_msgSend)(keypad, firstRow);
    CGFloat gap = floor(keypadTop - CGRectGetMaxY(outflow.frame));
    // Negative when a remembered value no longer fits (e.g. different system font metrics): shrink.
    gap = MAX(gap, -sAmountAreaExtra);
    if (fabs(gap) < 1) return;

    sAmountAreaExtra += gap;
    NSString *key = YBAmountExtraDefaultsKey();
    if (key) [NSUserDefaults.standardUserDefaults setDouble:sAmountAreaExtra forKey:key];
    CGFloat oldHeight = CGRectGetHeight(background.frame);
    CGRect f = background.frame;
    f.size.height += gap;
    background.frame = f;
    for (UIView *v in self.view.subviews) {
        if (v == background || v == keypad) continue;
        CGRect vf = v.frame;
        if (fabs(CGRectGetHeight(vf) - oldHeight) < 0.5 && CGRectGetMinY(vf) <= CGRectGetMinY(background.frame) + 0.5) {
            vf.size.height += gap; // e.g. the amount label, kept vertically centred in the block
        } else if (v == outflow || v == inflow || CGRectGetMinY(vf) >= CGRectGetMaxY(background.frame) - gap - 16) {
            vf.origin.y += gap;    // the Expense/Income buttons below the block
        } else {
            continue;
        }
        v.frame = vf;
    }
    for (UIView *v in background.subviews) {
        CGRect vf = v.frame;
        if (fabs(CGRectGetHeight(vf) - oldHeight) < 0.5) {
            vf.size.height += gap;
            v.frame = vf;
        }
    }
    for (UIWindow *w in UIApplication.sharedApplication.windows) YBRefreshTransactionDetailScreens(w.rootViewController);
}

#pragma mark - Add Transaction: frozen amount header during screen changes

// While moving between the transaction screens, YBTransactionNavigationController covers the top of
// the screen (navigation bar + amount area) with a snapshot so the amount stays put while the rest
// slides. It sizes the snapshot as nav bar bottom + amount height - status bar height, which with a
// 44pt status bar ends 44pt into the amount, so the amount's lower half slides away with the screen.
// Re-take the snapshot at the full height.

static IMP sUpdateFloatingAmountView;

// iOS 26 no longer calls navigationController:didShowViewController:animated: for the first screen
// of a modally presented navigation controller, which is where the app removes the snapshot, so it
// stayed on screen (a frozen second copy of the amount and Payee row over the navigation bar).
// During the presentation itself there's nothing to keep still, so no snapshot is shown, and
// didShow is called by hand when a transition ends without it.

static IMP sTxnNavWillShow, sTxnNavDidShow;
static const void *kDidShowPendingKey = &kDidShowPendingKey;

static void YBTransactionNav_didShow(id self, SEL _cmd, UINavigationController *nav, UIViewController *vc, BOOL animated) {
    objc_setAssociatedObject(self, kDidShowPendingKey, nil, OBJC_ASSOCIATION_RETAIN);
    ((void (*)(id, SEL, id, id, BOOL))sTxnNavDidShow)(self, _cmd, nav, vc, animated);
}

static void YBTransactionNav_willShow(UINavigationController *self, SEL _cmd, UINavigationController *nav, UIViewController *vc, BOOL animated) {
    ((void (*)(id, SEL, id, id, BOOL))sTxnNavWillShow)(self, _cmd, nav, vc, animated);
    objc_setAssociatedObject(self, kDidShowPendingKey, vc, OBJC_ASSOCIATION_ASSIGN);
    __weak UINavigationController *weakSelf = self;
    __weak UIViewController *weakVC = vc;
    void (^finish)(void) = ^{
        UINavigationController *strong = weakSelf;
        UIViewController *shown = weakVC;
        if (!strong || !shown || objc_getAssociatedObject(strong, kDidShowPendingKey) != shown) return;
        SEL didShow = @selector(navigationController:didShowViewController:animated:);
        ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(strong, didShow, nav, shown, animated);
    };
    id<UIViewControllerTransitionCoordinator> coordinator = self.transitionCoordinator;
    if (coordinator) {
        [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
            dispatch_async(dispatch_get_main_queue(), finish); // after UIKit's own didShow, if any
        }];
    } else {
        dispatch_async(dispatch_get_main_queue(), finish);
    }
}

static void YBTransactionNav_updateFloatingAmountView(UINavigationController *self, SEL _cmd) {
    ((void (*)(id, SEL))sUpdateFloatingAmountView)(self, _cmd);
    if (self.isBeingPresented || self.isBeingDismissed) {
        ((void (*)(id, SEL))objc_msgSend)(self, sel_registerName("hideFloatingAmountView"));
        return;
    }
    UIImageView *floating = nil;
    @try { floating = [self valueForKey:@"floatingAmountView"]; } @catch (NSException *e) { return; }
    UIView *host = floating.superview;
    if (![floating isKindOfClass:UIImageView.class] || !host) return;

    id theme = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("YBTheme"), sel_registerName("currentTheme"));
    SEL areaSel = sel_registerName("transactionAmountAreaHeight");
    if (![theme respondsToSelector:areaSel]) return;
    CGFloat area = ((double (*)(id, SEL))objc_msgSend)(theme, areaSel);
    CGFloat needed = [self.navigationBar convertRect:self.navigationBar.bounds toView:host].origin.y
                     + CGRectGetHeight(self.navigationBar.bounds) + area;
    CGRect f = floating.frame;
    if (needed <= CGRectGetHeight(f) + 0.5 || needed > CGRectGetHeight(host.bounds)) return;

    floating.hidden = YES;
    CGSize size = CGSizeMake(CGRectGetWidth(f), needed);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [host drawViewHierarchyInRect:CGRectMake(-CGRectGetMinX(f), -CGRectGetMinY(f),
                                                 CGRectGetWidth(host.bounds), CGRectGetHeight(host.bounds))
                   afterScreenUpdates:NO];
    }];
    floating.hidden = NO;
    floating.image = image;
    f.size.height = needed;
    floating.frame = f;
}

#pragma mark - Views sized for a 320pt-wide screen

// A few controls are created with the iPhone 5's 320pt width hard-coded.

// Date (and other) pickers: stretch to the full width of the screen.
static void YBWidenPickers(UIViewController *vc) {
    UIView *root = vc.view;
    CGFloat width = CGRectGetWidth(root.bounds);
    for (UIView *sub in root.subviews) {
        if (![sub isKindOfClass:UIDatePicker.class] && ![sub isKindOfClass:UIPickerView.class]) continue;
        CGRect f = sub.frame;
        if (CGRectGetMinX(f) == 0 && CGRectGetWidth(f) < width - 0.5) {
            f.size.width = width;
            sub.frame = f;
        }
    }
}

// The transaction memo: its clear (x) button sits at x=290 (right edge of a 320pt row) while the text
// spans the whole row. Pin the button to the row's right edge and keep the text clear of it.
static UITextView *YBFindMemoTextView(UIView *view) {
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:UITextView.class]) {
            UIView *button = [sub.superview viewWithTag:101];
            if ([button isKindOfClass:UIButton.class] && button.superview == sub.superview) return (UITextView *)sub;
        }
        UITextView *found = YBFindMemoTextView(sub);
        if (found) return found;
    }
    return nil;
}

static void YBFixMemoClearButton(UIViewController *vc) {
    static Class detailClass;
    if (!detailClass) detailClass = objc_getClass("YBTransactionDetailViewController") ?: [NSNull class];
    if (![vc isKindOfClass:detailClass]) return;
    // The memo is the text view whose row also holds the clear button (tag 101). Tags alone aren't
    // unique on this screen.
    UITextView *memo = YBFindMemoTextView(vc.view);
    UIButton *clear = (UIButton *)[memo.superview viewWithTag:101];
    UIView *row = memo.superview;
    if (!memo || ![clear isKindOfClass:UIButton.class]) return;
    CGFloat rowWidth = CGRectGetWidth(row.bounds);
    if (rowWidth <= 320) return;
    CGRect f = clear.frame;
    CGFloat x = rowWidth - 320 + 290;
    if (fabs(CGRectGetMinX(f) - x) >= 0.5) {
        f.origin.x = x;
        clear.frame = f;
    }
    UITextView *text = memo;
    UIEdgeInsets inset = text.textContainerInset;
    CGFloat right = MAX(0, CGRectGetMaxX(text.frame) - x + 4);
    if (fabs(inset.right - right) >= 0.5) {
        inset.right = right;
        text.textContainerInset = inset;
    }
}

// Standalone search bars (Payee, Category pickers) are 44pt tall with the field squeezed in; the
// main budget list's bar is 56pt with 10pt of colour around the field. Match it: grow the bar to
// 56pt (UIKit centres the field and Cancel button) and move the list below it down.
static const CGFloat kSearchBarHeight = 56;

static void YBFixStandaloneSearchBars(UIViewController *vc) {
    UIView *root = vc.view;
    for (UIView *bar in root.subviews) {
        if (![bar isKindOfClass:UISearchBar.class] || bar.hidden) continue;
        CGRect f = bar.frame;
        if (CGRectGetMinY(f) != 0 || CGRectGetHeight(f) > kSearchBarHeight + 0.5 || CGRectGetHeight(f) < 30 ||
            CGRectGetWidth(f) < CGRectGetWidth(root.bounds) - 0.5) continue;
        if (CGRectGetHeight(f) < kSearchBarHeight - 0.5) {
            f.size.height = kSearchBarHeight;
            bar.frame = f;
        }
        // Lists starting where the old, shorter bar ended (re-checked on every layout pass, since the
        // screen may reposition them).
        for (UIView *sub in root.subviews) {
            if (![sub isKindOfClass:UIScrollView.class]) continue;
            CGRect sf = sub.frame;
            if (CGRectGetMinY(sf) >= 30 && CGRectGetMinY(sf) < kSearchBarHeight - 0.5) {
                CGFloat shift = kSearchBarHeight - CGRectGetMinY(sf);
                sf.origin.y += shift;
                sf.size.height -= shift;
                sub.frame = sf;
            }
        }
    }
}

#pragma mark - Split transaction list (YBTransactionSplitViewController)

// The splits screen gives its list a height hard-coded per screen size: 226pt and 186pt for the two
// iPhone sizes it knew, and 146pt for anything else (every current iPhone), capped at the "Remaining"
// bar above the keypad. On taller screens that leaves a dead strip above the bar, and the third split
// and "Add another split" get cut off there. Let the list reach down to the bar.

static IMP sUpdateSplitsTableViewHeight;

static void YBSplits_updateSplitsTableViewHeight(UIViewController *self, SEL _cmd) {
    ((void (*)(id, SEL))sUpdateSplitsTableViewHeight)(self, _cmd);
    if (![self respondsToSelector:sel_registerName("splitsTableView")] ||
        ![self respondsToSelector:sel_registerName("remainingBackgroundView")]) return;
    UITableView *table = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("splitsTableView"));
    UIView *remaining = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("remainingBackgroundView"));
    if (!table || !remaining || table.superview != remaining.superview) return;
    CGRect f = table.frame;
    CGFloat height = CGRectGetMinY(remaining.frame) - CGRectGetMinY(f);
    if (height > CGRectGetHeight(f) + 0.5) {
        f.size.height = height;
        table.frame = f;
    }
}

#pragma mark - Split detail memo and the keyboard (YBTransactionSplitDetailViewController)

// The split detail screen (category, transfer, memo) shrinks its list to end at the keyboard in
// keyboardShown:, saving the full height first, and restores that saved height in keyboardHidden:.
// iOS can post a "keyboard will hide" without a "will show" before it (with a hardware keyboard, or
// when another input closes as the memo starts editing), and the app then "restores" a height it
// never saved, 0, animating the whole section up behind the navigation bar until it's gone. Only
// restore a height that was saved, save it once per keyboard session, and never grow the list past it.

static IMP sSplitDetailKeyboardHidden;
static const void *kSplitDetailSavedHeightKey = &kSplitDetailSavedHeightKey; // controller -> @(full list height)

static UITableView *YBSplitDetailTable(UIViewController *vc) {
    if (![vc respondsToSelector:sel_registerName("tableView")]) return nil;
    id table = ((id (*)(id, SEL))objc_msgSend)(vc, sel_registerName("tableView"));
    return [table isKindOfClass:UITableView.class] ? table : nil;
}

static void YBSplitDetail_keyboardShown(UIViewController *self, SEL _cmd, NSNotification *note) {
    UITableView *table = YBSplitDetailTable(self);
    if (!table) return;
    NSNumber *saved = objc_getAssociatedObject(self, kSplitDetailSavedHeightKey);
    if (!saved) {
        saved = @(CGRectGetHeight(table.frame));
        objc_setAssociatedObject(self, kSplitDetailSavedHeightKey, saved, OBJC_ASSOCIATION_RETAIN);
        if ([self respondsToSelector:sel_registerName("setTableViewHeightWithoutKeyboardDisplayed:")]) {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(self, sel_registerName("setTableViewHeightWithoutKeyboardDisplayed:"), saved.doubleValue);
        }
    }
    CGRect keyboard = [self.view convertRect:[note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue] fromView:nil];
    CGRect f = table.frame;
    CGFloat height = saved.doubleValue;
    // A keyboard that's on screen and overlaps the list (not a hardware keyboard's empty frame).
    if (CGRectGetHeight(keyboard) > 1 && CGRectGetMinY(keyboard) < CGRectGetMaxY(f)) {
        height = MIN(height, MAX(0, CGRectGetMinY(keyboard) - CGRectGetMinY(f)));
    }
    if (fabs(CGRectGetHeight(f) - height) >= 0.5) {
        f.size.height = height;
        table.frame = f;
    }
}

static void YBSplitDetail_keyboardHidden(UIViewController *self, SEL _cmd, NSNotification *note) {
    if (!objc_getAssociatedObject(self, kSplitDetailSavedHeightKey)) return; // nothing was shrunk
    ((void (*)(id, SEL, id))sSplitDetailKeyboardHidden)(self, _cmd, note);
    objc_setAssociatedObject(self, kSplitDetailSavedHeightKey, nil, OBJC_ASSOCIATION_RETAIN);
}

#pragma mark - Payee / Category / Account picker rows (YBTransactionSelectionListCell)

// The rows carry a 1x1 transparent accessory image, and current iOS reserves accessory space for it,
// so the row content (and the right-aligned amount) stops 26pt from the right edge while the label
// starts 15pt from the left. Widen the content area so the right inset mirrors the left one and move
// the right-hand views (amount, checkmark) along with it. Rows next to the A-Z section index keep
// the space the index needs.

static IMP sSelectionCellLayoutSubviews;

static void YBSelectionCell_layoutSubviews(UITableViewCell *self, SEL _cmd) {
    ((void (*)(id, SEL))sSelectionCellLayoutSubviews)(self, _cmd);
    SEL indexSel = sel_registerName("tableIsDisplayingSectionIndex");
    if ([self respondsToSelector:indexSel] && ((BOOL (*)(id, SEL))objc_msgSend)(self, indexSel)) return;
    UIView *content = self.contentView;
    UIView *left = nil;
    @try { left = [self valueForKey:@"leftLabel"]; } @catch (NSException *e) { return; }
    if (!left || left.superview != content) return;
    CGFloat oldWidth = CGRectGetWidth(content.bounds);
    CGFloat target = CGRectGetWidth(self.bounds) - CGRectGetMinX(left.frame) - CGRectGetMinX(content.frame);
    CGFloat delta = target - oldWidth;
    if (delta < 0.5 || delta > 40) return;
    CGRect cf = content.frame;
    cf.size.width = target;
    content.frame = cf;
    for (UIView *v in content.subviews) {
        if (v == left || CGRectGetMaxX(v.frame) < oldWidth - 30) continue;
        CGRect f = v.frame;
        f.origin.x += delta;
        v.frame = f;
    }
}

#pragma mark - Startup splash (YBAppDelegate showSplashScreen)

// After the system launch screen (a plain gradient drawn by patch.py), the app shows its own splash
// image while it loads, then fades it out. It uses the old 320x480 launch image at the top-left
// corner. Show the app's largest launch image (the iPhone 6 Plus one) instead, scaled to fill the
// screen; its background is the same gradient as the launch screen.

static IMP sShowSplashScreen;

static void YBAppDelegate_showSplashScreen(id self, SEL _cmd) {
    ((void (*)(id, SEL))sShowSplashScreen)(self, _cmd);
    UIImageView *splash = nil;
    @try { splash = [self valueForKey:@"splashView"]; } @catch (NSException *e) { return; }
    UIImage *image = [UIImage imageNamed:@"LaunchImage-800-Portrait-736h"];
    UIView *host = splash.superview;
    if (![splash isKindOfClass:UIImageView.class] || !image || !host) return;
    splash.image = image;
    splash.contentMode = UIViewContentModeScaleAspectFill;
    splash.clipsToBounds = YES;
    splash.frame = host.bounds;
}

#pragma mark - Hooks

static void YBAfterLayout(UIViewController *vc) {
    if (![NSStringFromClass(vc.class) hasPrefix:@"YB"] || !vc.isViewLoaded) return;

    static Class menu, addButton, saveButton, doneButton;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        menu = objc_getClass("YBMenuViewController");
        addButton = objc_getClass("YBAddTransactionButton");
        saveButton = objc_getClass("YBSaveTransactionButton");
        doneButton = objc_getClass("YBBottomDoneButton");
    });

    if (YBFixLegacyStatusBarScreen(vc, menu && [vc isKindOfClass:menu])) return;
    // Screens compute the add button's frame from the screen size before their view is shrunk to fit
    // below the navigation bar, so it only ends near the bottom after layout. Re-apply it now;
    // YBAddButton_setFrame does the adjusting.
    for (UIView *sub in vc.view.subviews) {
        if ([sub isKindOfClass:addButton] || [sub isKindOfClass:saveButton] || [sub isKindOfClass:doneButton]) sub.frame = sub.frame;
    }
    YBFixBottomPinnedViews(vc);
    YBFixSearchBarHeaders(vc);
    YBInstallSearchHost(vc);
    YBWidenPickers(vc);
    YBFixMemoClearButton(vc);
    YBFixStandaloneSearchBars(vc);
}

// Wraps -viewDidLayoutSubviews on `cls` (which must implement it itself). Everything done after
// layout is idempotent, so it's fine for this to run more than once per pass via super calls.
static void YBHookViewDidLayoutSubviews(Class cls) {
    Method m = class_getInstanceMethod(cls, @selector(viewDidLayoutSubviews));
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(UIViewController *vc) {
        ((void (*)(id, SEL))orig)(vc, @selector(viewDidLayoutSubviews));
        YBAfterLayout(vc);
    }));
}

// Modally presented screens can finish their last layout pass before their view is in a window,
// when the home-indicator overlap can't be measured yet, so also run the fixes once on screen.
static void YBHookViewDidAppear(Class cls) {
    Method m = class_getInstanceMethod(cls, @selector(viewDidAppear:));
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(UIViewController *vc, BOOL animated) {
        ((void (*)(id, SEL, BOOL))orig)(vc, @selector(viewDidAppear:), animated);
        YBAfterLayout(vc);
    }));
}

// Replaces `sel` on `cls` only: adds an override when `cls` merely inherits it, so superclasses
// (e.g. UIView for UIToolbar) are left alone.
static void YBSwizzleInstanceMethod(Class cls, SEL sel, IMP newImp, IMP *origImp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (class_addMethod(cls, sel, newImp, method_getTypeEncoding(m))) {
        *origImp = method_getImplementation(m);
    } else {
        *origImp = method_setImplementation(m, newImp);
    }
}

__attribute__((constructor))
static void YNABModernInit(void) {
    Class addButton = objc_getClass("YBAddTransactionButton");
    if (addButton) YBSwizzleInstanceMethod(addButton, @selector(setFrame:), (IMP)YBAddButton_setFrame, &sAddButtonSetFrame);
    Class saveButton = objc_getClass("YBSaveTransactionButton");
    if (saveButton) YBSwizzleInstanceMethod(saveButton, @selector(setFrame:), (IMP)YBSaveButton_setFrame, &sSaveButtonSetFrame);
    Class doneButton = objc_getClass("YBBottomDoneButton");
    if (doneButton) YBSwizzleInstanceMethod(doneButton, @selector(setFrame:), (IMP)YBDoneButton_setFrame, &sDoneButtonSetFrame);
    YBSwizzleInstanceMethod(UIToolbar.class, @selector(setFrame:), (IMP)YBToolbar_setFrame, &sToolbarSetFrame);
    YBSwizzleInstanceMethod(UIToolbar.class, @selector(setCenter:), (IMP)YBToolbar_setCenter, &sToolbarSetCenter);
    YBSwizzleInstanceMethod(UISearchBar.class, @selector(layoutSubviews), (IMP)YBSearchBar_layoutSubviews, &sSearchBarLayoutSubviews);
    // iPhone only: on iPad transaction entry is a popover without these problems.
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        Class keypadClass = objc_getClass("YBKeypad");
        if (keypadClass && class_getInstanceMethod(keypadClass, sel_registerName("availableHeight"))) {
            YBSwizzleInstanceMethod(keypadClass, sel_registerName("availableHeight"), (IMP)YBKeypad_availableHeight, &sKeypadAvailableHeight);
        }
        YBHookAmountAreaHeight();
        Class amountEntry = objc_getClass("YBTransactionAmountEntryViewController");
        if (amountEntry && class_getInstanceMethod(amountEntry, sel_registerName("initInflowAndOutflowButtons"))) {
            YBSwizzleInstanceMethod(amountEntry, sel_registerName("initInflowAndOutflowButtons"), (IMP)YBAmountEntry_initInflowAndOutflowButtons, &sInitInflowOutflowButtons);
        }
    }
    Class appDelegate = objc_getClass("YBAppDelegate");
    if (appDelegate && class_getInstanceMethod(appDelegate, sel_registerName("showSplashScreen"))) {
        YBSwizzleInstanceMethod(appDelegate, sel_registerName("showSplashScreen"), (IMP)YBAppDelegate_showSplashScreen, &sShowSplashScreen);
    }
    Class splits = objc_getClass("YBTransactionSplitViewController");
    SEL updateSplitsHeight = sel_registerName("updateSplitsTableViewHeight");
    if (splits && class_getInstanceMethod(splits, updateSplitsHeight)) {
        YBSwizzleInstanceMethod(splits, updateSplitsHeight, (IMP)YBSplits_updateSplitsTableViewHeight, &sUpdateSplitsTableViewHeight);
    }
    Class splitDetail = objc_getClass("YBTransactionSplitDetailViewController");
    SEL kbShown = sel_registerName("keyboardShown:"), kbHidden = sel_registerName("keyboardHidden:");
    if (splitDetail && class_getInstanceMethod(splitDetail, kbShown) && class_getInstanceMethod(splitDetail, kbHidden)) {
        IMP unusedShown;
        YBSwizzleInstanceMethod(splitDetail, kbShown, (IMP)YBSplitDetail_keyboardShown, &unusedShown);
        YBSwizzleInstanceMethod(splitDetail, kbHidden, (IMP)YBSplitDetail_keyboardHidden, &sSplitDetailKeyboardHidden);
    }
    Class selectionCell = objc_getClass("YBTransactionSelectionListCell");
    if (selectionCell && class_getInstanceMethod(selectionCell, @selector(layoutSubviews))) {
        YBSwizzleInstanceMethod(selectionCell, @selector(layoutSubviews), (IMP)YBSelectionCell_layoutSubviews, &sSelectionCellLayoutSubviews);
    }
    Class transactionNav = objc_getClass("YBTransactionNavigationController");
    SEL updateFloating = sel_registerName("updateFloatingAmountView");
    if (transactionNav && class_getInstanceMethod(transactionNav, updateFloating)) {
        YBSwizzleInstanceMethod(transactionNav, updateFloating, (IMP)YBTransactionNav_updateFloatingAmountView, &sUpdateFloatingAmountView);
        SEL willShow = @selector(navigationController:willShowViewController:animated:);
        SEL didShow = @selector(navigationController:didShowViewController:animated:);
        if (class_getInstanceMethod(transactionNav, willShow) && class_getInstanceMethod(transactionNav, didShow)) {
            YBSwizzleInstanceMethod(transactionNav, willShow, (IMP)YBTransactionNav_willShow, &sTxnNavWillShow);
            YBSwizzleInstanceMethod(transactionNav, didShow, (IMP)YBTransactionNav_didShow, &sTxnNavDidShow);
        }
    }
    Class searchDisplay = objc_getClass("UISearchDisplayController");
    if (searchDisplay) YBSwizzleInstanceMethod(searchDisplay, @selector(setActive:animated:), (IMP)YBSearchDisplay_setActive, &sSearchDisplaySetActive);
    YBSwizzleInstanceMethod(UITableView.class, @selector(reloadData), (IMP)YBTable_reloadData, &sTableReloadData);
    YBSwizzleInstanceMethod(UISearchBar.class, @selector(didMoveToSuperview), (IMP)YBSearchBar_didMoveToSuperview, &sSearchBarDidMoveToSuperview);
    Class dimmingView = objc_getClass("_UISearchDisplayControllerDimmingView");
    if (dimmingView) YBSwizzleInstanceMethod(dimmingView, @selector(didMoveToSuperview), (IMP)YBDimmingView_didMoveToSuperview, &sDimmingViewDidMoveToSuperview);
    Class searchResults = objc_getClass("UISearchResultsTableView");
    if (searchResults) YBSwizzleInstanceMethod(searchResults, @selector(layoutSubviews), (IMP)YBSearchResults_layoutSubviews, &sSearchResultsLayoutSubviews);

    // UIViewController's implementation covers every screen that doesn't override it; the few app
    // classes that do override it are wrapped too, in case they don't call super.
    YBHookViewDidLayoutSubviews(UIViewController.class);
    YBHookViewDidAppear(UIViewController.class);
    for (NSString *name in @[@"YBMoveMoneyCategorySelectionViewController",
                             @"YBTransactionDetailViewController",
                             @"YBTransactionSelectionListViewController"]) {
        Class cls = NSClassFromString(name);
        if (cls) YBHookViewDidLayoutSubviews(cls);
    }
}
