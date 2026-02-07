//
//  MainSidebarTableCell.m
//  Instacast
//
//  Created by Martin Hering on 19/07/13.
//
//

#import "MainSidebarTableCell.h"
#import "MainSidebarController.h"
#import "ViewFunctions.h"
#import "ImageFunctions.h"

@interface MainSidebarTableCellNipple : UIView

@end

@implementation MainSidebarTableCellNipple
- (void) drawRect:(CGRect)rect
{
    [super drawRect:rect];
    
    [self.tintColor set];
    
    UIBezierPath* bezierPath = BezierPathForRoundedRect(CGRectMake(0, 0, 9, 9), 4);
    [bezierPath fill];
}
@end


@interface MainSidebarTableCell ()
@property (nonatomic, strong) MainSidebarTableCellNipple* nippleView;
@property (nonatomic, strong, readwrite) UIButton* badgeButton;
@property (nonatomic, strong, readwrite) UILabel* subtitleLabel;
@end



@implementation MainSidebarTableCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        
        self.backgroundView = [[UIView alloc] initWithFrame:CGRectZero];
        self.selectedBackgroundView = [[UIView alloc] initWithFrame:CGRectZero];
        
        self.textLabel.textColor = [UIColor colorWithWhite:0.57f alpha:1.f];
        self.textLabel.highlightedTextColor = [UIColor whiteColor];
        self.textLabel.font = [UIFont systemFontOfSize:18.0f];
        
        self.imageView.contentMode = UIViewContentModeCenter;
        
        _nippleView = [[MainSidebarTableCellNipple alloc] initWithFrame:CGRectMake(0, 0, 9, 9)];
        [self.contentView addSubview:_nippleView];
        
        
        _badgeButton = [[UIButton alloc] initWithFrame:CGRectZero];
        _badgeButton.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        [_badgeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _badgeButton.titleEdgeInsets = UIEdgeInsetsMake(1, 0.5, 0, -0.5);
        _badgeButton.userInteractionEnabled = NO;
        
        UIImage* badgeBackgroundImage = [ICImageFromByDrawingInContextWithScale(CGSizeMake(21, 21), NO, App.ic_keyWindow.screen.scale, ^(void) {

                [[UIColor redColor] set];

                UIBezierPath* path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 21, 21) cornerRadius:10];
                [path fill];

            }) resizableImageWithCapInsets:UIEdgeInsetsMake(10, 10, 10, 10)];
        
        [_badgeButton setBackgroundImage:badgeBackgroundImage forState:UIControlStateNormal];

        [self.contentView addSubview:_badgeButton];

        _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _subtitleLabel.font = [UIFont systemFontOfSize:14];
        _subtitleLabel.textColor = [UIColor colorWithWhite:0.45f alpha:1.f];
        _subtitleLabel.textAlignment = NSTextAlignmentRight;
        _subtitleLabel.hidden = YES;
        [self.contentView addSubview:_subtitleLabel];

    }

    return self;
}

- (void) dealloc {
    self.objectValue = nil;
}

- (void) setObjectValue:(MainSidebarItem*)objectValue
{
    if (_objectValue != objectValue)
    {
        if (_objectValue) {
            [_objectValue removeTaskObserver:self forKeyPath:@"title"];
        }

        _objectValue = objectValue;


        self.textLabel.text = objectValue.title;
        self.imageView.image = [objectValue.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];

        self.imageView.highlightedImage = [objectValue.selectedImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];

        if (objectValue) {
            WEAK_SELF
            [objectValue addTaskObserver:self forKeyPath:@"title" task:^(id obj, NSDictionary *change) {
                weakSelf.textLabel.text = weakSelf.objectValue.title;
            }];
        }
    }
}

- (void) layoutSubviews
{
    [super layoutSubviews];

    self.backgroundColor = ICDarkBackgroundColor;

    CGRect b = self.bounds;
    CGFloat topOffset = self.objectValue.topSpacing;

    self.tintColor = (self.highlighted || self.selected) ? self.textLabel.highlightedTextColor : self.textLabel.textColor;

    self.imageView.frame = CGRectMake(30, topOffset, 38, CGRectGetHeight(b) - topOffset);

    CGRect textFrame = self.textLabel.frame;
    textFrame.origin.x = 75;
    textFrame.origin.y = topOffset + (CGRectGetHeight(b) - topOffset - textFrame.size.height) / 2;
    self.textLabel.frame = textFrame;

    self.nippleView.hidden = YES;


    [self.badgeButton sizeToFit];
    CGRect badgeButtonTitleRect = self.badgeButton.titleLabel.frame;
    CGRect badgeButtonRect = self.badgeButton.frame;
    badgeButtonRect.size.width = MAX(21, badgeButtonTitleRect.size.width+8);
    badgeButtonRect.origin.x = 280-badgeButtonRect.size.width-15;
    badgeButtonRect.origin.y = topOffset + 10;

    self.badgeButton.frame = badgeButtonRect;

    // Subtitle label (z.B. Download Speed) rechts positionieren
    CGFloat rightEdge = self.badgeButton.hidden ? 255 : badgeButtonRect.origin.x - 5;
    [self.subtitleLabel sizeToFit];
    CGFloat subtitleW = self.subtitleLabel.frame.size.width;
    CGFloat subtitleX = rightEdge - subtitleW;
    self.subtitleLabel.frame = CGRectMake(subtitleX,
                                          topOffset + (CGRectGetHeight(b) - topOffset - 16) / 2 + 1,
                                          subtitleW, 16);

    CGRect titleRect = self.textLabel.frame;
    CGFloat maxTextRight = self.subtitleLabel.hidden ? rightEdge : subtitleX - 5;
    titleRect.size.width = MIN(titleRect.size.width, (maxTextRight - titleRect.origin.x));
    self.textLabel.frame = titleRect;
}


@end
