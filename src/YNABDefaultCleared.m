// "Default cleared status" setting for YNAB Classic 3.4.3.
// Adds a switch to the Workflow section of Settings; when it's on, new transactions start with
// their Cleared checkbox ticked. Edits are unaffected: they take the transaction's own state.
// Built into YNABModern.dylib alongside YNABModern.m.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kDefaultClearedKey = @"YBModernDefaultCleared";
static NSString *const kDefaultClearedTitle = @"Default cleared status";

#pragma mark - New transactions (YBPendingTransaction)

// Every "Add Transaction" path calls -setupDefaultValues on a freshly reset pending transaction
// (cleared = NO). Editing an existing one sets basedOnTransaction, whose cleared state wins.

@interface NSObject (YBPendingTransaction)
- (id)basedOnTransaction;
- (void)setCleared:(BOOL)cleared;
@end

static void YBHookSetupDefaultValues(void) {
    Class cls = objc_getClass("YBPendingTransaction");
    Method m = class_getInstanceMethod(cls, @selector(setupDefaultValues));
    if (!m) return;
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(NSObject *pending) {
        ((void (*)(id, SEL))orig)(pending, @selector(setupDefaultValues));
        if ([NSUserDefaults.standardUserDefaults boolForKey:kDefaultClearedKey] && !pending.basedOnTransaction) {
            [pending setCleared:YES];
        }
    }));
}

#pragma mark - Settings row (YBSettingsViewController)

// The setting is appended as the last row of the Workflow section, styled after that section's
// first row so it matches the app's own switches.

@interface YBDefaultClearedSwitchTarget : NSObject
@end

@implementation YBDefaultClearedSwitchTarget
+ (void)switchToggled:(UISwitch *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:kDefaultClearedKey];
}
@end

static IMP sOrigNumberOfRows, sOrigCellForRow, sOrigDidSelectRow;

static NSInteger YBWorkflowSection(id<UITableViewDataSource> vc, UITableView *tableView) {
    NSInteger sections = [vc numberOfSectionsInTableView:tableView];
    for (NSInteger s = 0; s < sections; s++) {
        NSString *title = [vc tableView:tableView titleForHeaderInSection:s];
        if ([title caseInsensitiveCompare:@"Workflow"] == NSOrderedSame) return s;
    }
    return NSNotFound;
}

static NSInteger YBOrigRows(id vc, UITableView *tableView, NSInteger section) {
    return ((NSInteger (*)(id, SEL, UITableView *, NSInteger))sOrigNumberOfRows)(
        vc, @selector(tableView:numberOfRowsInSection:), tableView, section);
}

static BOOL YBIsDefaultClearedRow(id vc, UITableView *tableView, NSIndexPath *indexPath) {
    return indexPath.section == YBWorkflowSection(vc, tableView)
        && indexPath.row == YBOrigRows(vc, tableView, indexPath.section);
}

static __kindof UIView *YBFirstSubview(UIView *view, Class cls) {
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:cls]) return sub;
        UIView *found = YBFirstSubview(sub, cls);
        if (found) return found;
    }
    return nil;
}

static UITableViewCell *YBDefaultClearedCell(id vc, UITableView *tableView, NSIndexPath *indexPath) {
    static NSString *const reuseID = @"YBModernDefaultCleared";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseID];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *toggle = [[UISwitch alloc] init];
        [toggle addTarget:YBDefaultClearedSwitchTarget.class action:@selector(switchToggled:)
         forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;

        // Match the section's existing rows (font, colours, switch tint).
        NSIndexPath *sibling = [NSIndexPath indexPathForRow:0 inSection:indexPath.section];
        UITableViewCell *model = ((UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))sOrigCellForRow)(
            vc, @selector(tableView:cellForRowAtIndexPath:), tableView, sibling);
        UILabel *modelLabel = model.textLabel.text.length ? model.textLabel : YBFirstSubview(model, UILabel.class);
        UISwitch *modelSwitch = [model.accessoryView isKindOfClass:UISwitch.class]
            ? (UISwitch *)model.accessoryView : YBFirstSubview(model, UISwitch.class);
        if (modelLabel) {
            cell.textLabel.font = modelLabel.font;
            cell.textLabel.textColor = modelLabel.textColor;
        }
        if (modelSwitch.onTintColor) toggle.onTintColor = modelSwitch.onTintColor;
        if (model.backgroundColor) cell.backgroundColor = model.backgroundColor;
    }
    cell.textLabel.text = kDefaultClearedTitle;
    ((UISwitch *)cell.accessoryView).on = [NSUserDefaults.standardUserDefaults boolForKey:kDefaultClearedKey];
    return cell;
}

static void YBHookSettings(void) {
    Class cls = objc_getClass("YBSettingsViewController");
    Method rows = class_getInstanceMethod(cls, @selector(tableView:numberOfRowsInSection:));
    Method cell = class_getInstanceMethod(cls, @selector(tableView:cellForRowAtIndexPath:));
    Method select = class_getInstanceMethod(cls, @selector(tableView:didSelectRowAtIndexPath:));
    if (!rows || !cell || !select || !class_getInstanceMethod(cls, @selector(tableView:titleForHeaderInSection:))) return;

    sOrigNumberOfRows = method_getImplementation(rows);
    method_setImplementation(rows, imp_implementationWithBlock(^NSInteger(id vc, UITableView *tableView, NSInteger section) {
        return YBOrigRows(vc, tableView, section) + (section == YBWorkflowSection(vc, tableView) ? 1 : 0);
    }));

    sOrigCellForRow = method_getImplementation(cell);
    method_setImplementation(cell, imp_implementationWithBlock(^UITableViewCell *(id vc, UITableView *tableView, NSIndexPath *indexPath) {
        if (YBIsDefaultClearedRow(vc, tableView, indexPath)) return YBDefaultClearedCell(vc, tableView, indexPath);
        return ((UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))sOrigCellForRow)(
            vc, @selector(tableView:cellForRowAtIndexPath:), tableView, indexPath);
    }));

    sOrigDidSelectRow = method_getImplementation(select);
    method_setImplementation(select, imp_implementationWithBlock(^(id vc, UITableView *tableView, NSIndexPath *indexPath) {
        if (YBIsDefaultClearedRow(vc, tableView, indexPath)) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            return;
        }
        ((void (*)(id, SEL, UITableView *, NSIndexPath *))sOrigDidSelectRow)(
            vc, @selector(tableView:didSelectRowAtIndexPath:), tableView, indexPath);
    }));
}

__attribute__((constructor))
static void YNABDefaultClearedInit(void) {
    YBHookSetupDefaultValues();
    YBHookSettings();
}
