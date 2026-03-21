// GlassButtonTestViewController.m
// Minimal test for iOS 26 Liquid Glass buttons.
// Push this VC to verify: glass appearance, button taps, position, transitions.
// Usage: Push from any navigation controller for testing, then remove.

#import <UIKit/UIKit.h>

@interface GlassButtonTestViewController : UIViewController
@end

@implementation GlassButtonTestViewController {
    UIButton* _leftButton;
    UIButton* _rightButton;
    UIButton* _editBtn1;
    UIButton* _editBtn2;
    UIButton* _editBtn3;
    UIButton* _doneBtn;
    BOOL _editingMode;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Glass Button Test";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    if (@available(iOS 26.0, *)) {
        self.navigationController.toolbarHidden = YES;
        [self _setupButtons];
    }
}

- (void)_setupButtons API_AVAILABLE(ios(26.0)) {
    UIView* container = self.navigationController.view;
    if (!container) {
        NSLog(@"GLASS TEST: navigationController.view is NIL!");
        return;
    }
    NSLog(@"GLASS TEST: container = %@, size = %@", container, NSStringFromCGSize(container.bounds.size));

    // --- Normal mode: 2 buttons ---
    UIButtonConfiguration* leftConfig = [UIButtonConfiguration glassButtonConfiguration];
    leftConfig.image = [UIImage systemImageNamed:@"checkmark.circle"];
    leftConfig.buttonSize = UIButtonConfigurationSizeLarge;
    _leftButton = [UIButton buttonWithConfiguration:leftConfig primaryAction:
        [UIAction actionWithHandler:^(__unused UIAction* a) {
            NSLog(@"GLASS TEST: LEFT button tapped");
        }]];

    UIButtonConfiguration* rightConfig = [UIButtonConfiguration glassButtonConfiguration];
    rightConfig.image = [UIImage systemImageNamed:@"pencil"];
    rightConfig.buttonSize = UIButtonConfigurationSizeLarge;
    _rightButton = [UIButton buttonWithConfiguration:rightConfig primaryAction:
        [UIAction actionWithHandler:^(__unused UIAction* a) {
            NSLog(@"GLASS TEST: RIGHT button tapped — entering editing");
            [self _toggleEditing];
        }]];

    // --- Editing mode: 4 buttons ---
    UIButtonConfiguration* e1Config = [UIButtonConfiguration glassButtonConfiguration];
    e1Config.image = [UIImage systemImageNamed:@"ellipsis.circle"];
    e1Config.buttonSize = UIButtonConfigurationSizeLarge;
    _editBtn1 = [UIButton buttonWithConfiguration:e1Config primaryAction:
        [UIAction actionWithHandler:^(__unused UIAction* a) {
            NSLog(@"GLASS TEST: EDIT1 button tapped");
        }]];

    UIButtonConfiguration* e2Config = [UIButtonConfiguration glassButtonConfiguration];
    e2Config.image = [UIImage systemImageNamed:@"play.fill"];
    e2Config.buttonSize = UIButtonConfigurationSizeLarge;
    _editBtn2 = [UIButton buttonWithConfiguration:e2Config primaryAction:
        [UIAction actionWithHandler:^(__unused UIAction* a) {
            NSLog(@"GLASS TEST: EDIT2 button tapped");
        }]];

    UIButtonConfiguration* e3Config = [UIButtonConfiguration glassButtonConfiguration];
    e3Config.title = @"All";
    e3Config.buttonSize = UIButtonConfigurationSizeLarge;
    _editBtn3 = [UIButton buttonWithConfiguration:e3Config primaryAction:
        [UIAction actionWithHandler:^(__unused UIAction* a) {
            NSLog(@"GLASS TEST: EDIT3 (All) button tapped");
        }]];

    UIButtonConfiguration* doneConfig = [UIButtonConfiguration prominentGlassButtonConfiguration];
    doneConfig.title = @"Done";
    doneConfig.buttonSize = UIButtonConfigurationSizeLarge;
    _doneBtn = [UIButton buttonWithConfiguration:doneConfig primaryAction:
        [UIAction actionWithHandler:^(__unused UIAction* a) {
            NSLog(@"GLASS TEST: DONE button tapped — exiting editing");
            [self _toggleEditing];
        }]];

    NSArray* allButtons = @[_leftButton, _rightButton, _editBtn1, _editBtn2, _editBtn3, _doneBtn];
    for (UIButton* btn in allButtons) {
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:btn];
    }

    // Editing buttons start hidden
    _editBtn1.hidden = YES;
    _editBtn2.hidden = YES;
    _editBtn3.hidden = YES;
    _doneBtn.hidden = YES;

    UILayoutGuide* safeArea = container.safeAreaLayoutGuide;

    [NSLayoutConstraint activateConstraints:@[
        // Normal: left + right
        [_leftButton.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:20],
        [_leftButton.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-14],
        [_rightButton.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-20],
        [_rightButton.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-14],

        // Editing: chained left to right
        [_editBtn1.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:12],
        [_editBtn1.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-14],
        [_editBtn2.leadingAnchor constraintEqualToAnchor:_editBtn1.trailingAnchor constant:8],
        [_editBtn2.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-14],
        [_editBtn3.leadingAnchor constraintEqualToAnchor:_editBtn2.trailingAnchor constant:8],
        [_editBtn3.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-14],
        [_doneBtn.leadingAnchor constraintEqualToAnchor:_editBtn3.trailingAnchor constant:8],
        [_doneBtn.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-14],
        [_doneBtn.trailingAnchor constraintLessThanOrEqualToAnchor:safeArea.trailingAnchor constant:-12],
    ]];

    NSLog(@"GLASS TEST: All buttons created and laid out.");
}

- (void)_toggleEditing API_AVAILABLE(ios(26.0)) {
    _editingMode = !_editingMode;
    NSLog(@"GLASS TEST: editingMode = %@", _editingMode ? @"YES" : @"NO");

    _leftButton.hidden = _editingMode;
    _rightButton.hidden = _editingMode;
    _editBtn1.hidden = !_editingMode;
    _editBtn2.hidden = !_editingMode;
    _editBtn3.hidden = !_editingMode;
    _doneBtn.hidden = !_editingMode;

    UIView* container = self.navigationController.view;
    if (_editingMode) {
        [container bringSubviewToFront:_editBtn1];
        [container bringSubviewToFront:_editBtn2];
        [container bringSubviewToFront:_editBtn3];
        [container bringSubviewToFront:_doneBtn];
    } else {
        [container bringSubviewToFront:_leftButton];
        [container bringSubviewToFront:_rightButton];
    }

    // Log button frames
    [container layoutIfNeeded];
    NSLog(@"GLASS TEST: editBtn1 frame=%@ hidden=%d", NSStringFromCGRect(_editBtn1.frame), _editBtn1.hidden);
    NSLog(@"GLASS TEST: editBtn2 frame=%@ hidden=%d", NSStringFromCGRect(_editBtn2.frame), _editBtn2.hidden);
    NSLog(@"GLASS TEST: editBtn3 frame=%@ hidden=%d", NSStringFromCGRect(_editBtn3.frame), _editBtn3.hidden);
    NSLog(@"GLASS TEST: doneBtn  frame=%@ hidden=%d userInteraction=%d", NSStringFromCGRect(_doneBtn.frame), _doneBtn.hidden, _doneBtn.userInteractionEnabled);
    NSLog(@"GLASS TEST: container size=%@", NSStringFromCGSize(container.bounds.size));
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (@available(iOS 26.0, *)) {
        self.navigationController.toolbarHidden = YES;
        UIView* container = self.navigationController.view;
        _leftButton.hidden = NO;
        _rightButton.hidden = NO;
        [container bringSubviewToFront:_leftButton];
        [container bringSubviewToFront:_rightButton];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    if (@available(iOS 26.0, *)) {
        self.navigationController.toolbarHidden = NO;
        _leftButton.hidden = YES;
        _rightButton.hidden = YES;
        _editBtn1.hidden = YES;
        _editBtn2.hidden = YES;
        _editBtn3.hidden = YES;
        _doneBtn.hidden = YES;
    }
    [super viewWillDisappear:animated];
}

@end
