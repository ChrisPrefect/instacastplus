//
//  ICProgressSlider_iOS7.m
//  Instacast
//
//  Created by Martin Hering on 31.07.13.
//
//

#import "ICProgressSlider.h"
#import "ImageFunctions.h"

@interface ICProgressSliderChapterMarkersView : UIView
@property (nonatomic, strong) NSArray<NSNumber*>* chapterMarkers;
@property (nonatomic, strong) UIColor* markerColor;
@property (nonatomic, assign) double currentValue;
@end

@implementation ICProgressSliderChapterMarkersView

- (void) drawRect:(CGRect)rect {
    if (!self.chapterMarkers || self.chapterMarkers.count == 0) return;

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect bounds = self.bounds;
    CGFloat trackWidth = CGRectGetWidth(bounds) - 4;  // Same as slider track
    CGFloat trackHeight = CGRectGetHeight(bounds);

    // Determine current chapter segment boundaries
    double segmentStart = 0.0;
    double segmentEnd = 1.0;

    // Build sorted list including 0.0 and 1.0 boundaries
    NSMutableArray* allPositions = [NSMutableArray arrayWithObject:@(0.0)];
    for (NSNumber* marker in self.chapterMarkers) {
        double pos = [marker doubleValue];
        if (pos > 0.0 && pos < 1.0) {
            [allPositions addObject:marker];
        }
    }
    [allPositions addObject:@(1.0)];

    // Find the segment containing the current value
    for (NSUInteger i = 0; i < allPositions.count - 1; i++) {
        double start = [allPositions[i] doubleValue];
        double end = [allPositions[i + 1] doubleValue];
        if (self.currentValue >= start && self.currentValue < end) {
            segmentStart = start;
            segmentEnd = end;
            break;
        }
    }
    // Handle edge case: value exactly at 1.0
    if (self.currentValue >= 1.0) {
        segmentStart = [[allPositions objectAtIndex:allPositions.count - 2] doubleValue];
        segmentEnd = 1.0;
    }

    // Draw highlight for current chapter segment
    CGFloat highlightX = 2 + floorf(trackWidth * segmentStart);
    CGFloat highlightW = floorf(trackWidth * segmentEnd) - floorf(trackWidth * segmentStart);
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.5 alpha:0.55].CGColor);
    CGContextFillRect(ctx, CGRectMake(highlightX, 0, highlightW, trackHeight));

    // Draw chapter marker lines
    UIColor* color = self.markerColor ?: [UIColor colorWithWhite:0.5 alpha:0.6];
    CGContextSetStrokeColorWithColor(ctx, color.CGColor);
    CGContextSetLineWidth(ctx, 1.5);

    for (NSNumber* marker in self.chapterMarkers) {
        double position = [marker doubleValue];
        if (position <= 0.0 || position >= 1.0) continue;  // Skip first and last

        CGFloat x = 2 + floorf(trackWidth * position);
        CGContextMoveToPoint(ctx, x, 0);
        CGContextAddLineToPoint(ctx, x, trackHeight);
    }
    CGContextStrokePath(ctx);
}

@end


@interface ICProgressSlider ()
@property (nonatomic, assign) CGPoint trackingStartPoint;
@property (nonatomic, assign) CGRect trackingKnobStartRect;
@property (nonatomic, assign) CGRect trackingKnobRect;
@property (nonatomic, strong) UIButton* knobButton;
@property (nonatomic, strong) UIImageView* trackView;
@property (nonatomic, strong) UIImageView* backgroundView;
@property (nonatomic, strong) UIImageView* progressView;
@property (nonatomic, strong) ICProgressSliderChapterMarkersView* chapterMarkersView;
@property (nonatomic, readwrite) ICProgressSliderScrubbingMode scrubbingMode;
@property (nonatomic, assign) double valueBeforeTracking;
@property (nonatomic, strong) NSTimer* valueChangedTimer;
@end


@implementation ICProgressSlider

- (void) _initStuff
{
    _progressColor = [UIColor colorWithWhite:0.0f alpha:0.1f];
    
    _backgroundView = [[UIImageView alloc] initWithImage:nil];
    _backgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self addSubview:_backgroundView];
    
    _progressView = [[UIImageView alloc] initWithImage:nil];
    _progressView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self addSubview:_progressView];
    
    
    UIImage* trackImage = ICImageFromByDrawingInContext(CGSizeMake(7, 7), ^(void) {
        [self.tintColor set];
        UIRectFill(CGRectMake(0, 0, 10, 10));
    });
    
    _trackView = [[UIImageView alloc] initWithImage:trackImage];
    _trackView.hidden = YES;
    _trackView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self addSubview:_trackView];

    _chapterMarkersView = [[ICProgressSliderChapterMarkersView alloc] initWithFrame:CGRectZero];
    _chapterMarkersView.backgroundColor = [UIColor clearColor];
    _chapterMarkersView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _chapterMarkersView.userInteractionEnabled = NO;
    [self addSubview:_chapterMarkersView];


	_knobButton = [UIButton buttonWithType:UIButtonTypeCustom];
	_knobButton.frame = CGRectMake(0, 0, 44, 25);
	// Draw a 4px wide indicator bar programmatically
	UIImage* knobImage = ICImageFromByDrawingInContext(CGSizeMake(4, 19), ^(void) {
		[self.tintColor set];
		UIRectFill(CGRectMake(0, 0, 4, 19));
	});
	[_knobButton setImage:[knobImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
	_knobButton.opaque = NO;
	_knobButton.userInteractionEnabled = NO;
    _knobButton.accessibilityLabel = @"Slider Knob".ls;
    _knobButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    _knobButton.imageView.contentMode = UIViewContentModeCenter;
	
	[self addSubview:_knobButton];
    
    self.scrubbingModesEnabled = YES;
    self.contentMode = UIViewContentModeRedraw;
}

- (id) initWithCoder:(NSCoder *)aDecoder
{
	self = [super initWithCoder:aDecoder];
    if (self) {
        // Initialization code.
		[self _initStuff];
        [self _updateAppearance];
    }
    return self;
}

- (id)initWithFrame:(CGRect)frame {
    
    self = [super initWithFrame:frame];
    if (self) {
        // Initialization code.
		[self _initStuff];
        [self _updateAppearance];
    }
    return self;
}

- (void) _updateAppearance
{
    UIImage* backgroundImage = ICImageFromByDrawingInContext(CGSizeMake(7, 7), ^(void) {
        [self.progressColor set];
        UIRectFillUsingBlendMode(CGRectMake(0, 0, 10, 10), kCGBlendModeNormal);
    });

    _backgroundView.image = backgroundImage;

    UIImage* progressImage = ICImageFromByDrawingInContext(CGSizeMake(7, 7), ^(void) {
        [self.progressColor set];
        UIRectFillUsingBlendMode(CGRectMake(0, 0, 10, 10), kCGBlendModeNormal);
    });
    
    _progressView.image = progressImage;
}

- (void) setProgressColor:(UIColor *)progressColor
{
    if (_progressColor != progressColor) {
        _progressColor = progressColor;
        [self _updateAppearance];
    }
}

- (void) setAccessibilityLabel:(NSString *)accessibilityLabel
{
    [super setAccessibilityLabel:accessibilityLabel];
    self.knobButton.accessibilityHint = [NSString stringWithFormat:@"Swipe left or right to adjust %@.".ls, self.accessibilityLabel];
}

- (void) setProgress:(double)progress
{
	if (_progress != progress) {
		_progress = MIN(MAX(progress,0),1);
		[self setNeedsLayout];
	}
}

- (void) setChapterMarkers:(NSArray<NSNumber*>*)chapterMarkers
{
    _chapterMarkers = chapterMarkers;
    self.chapterMarkersView.chapterMarkers = chapterMarkers;
    [self.chapterMarkersView setNeedsDisplay];
}

- (void) setValue:(double)value
{
	if (_value != value) {
		_value = MIN(MAX(value,0),1);
		self.knobButton.frame = [self _knobRect];
        self.trackView.frame = [self _trackRect];
        if (self.chapterMarkersView.currentValue != _value) {
            self.chapterMarkersView.currentValue = _value;
            [self.chapterMarkersView setNeedsDisplay];
        }
        [self setNeedsLayout];
	}
}

- (CGRect) _knobRect
{
	CGRect bounds = self.bounds;
    CGFloat yOffset = floorf((CGRectGetHeight(bounds)-25)*0.5f);

	// Touch area is 44px wide, but position based on visual center (4px indicator)
	CGFloat maxKnobTrack = CGRectGetWidth(bounds)-4;
	CGFloat knobX = floorf(maxKnobTrack*self.value) - 20; // Center the 44px touch area on the 4px indicator
	return CGRectMake(knobX, yOffset, 44, 25);
}

- (CGRect) _trackRect
{
    CGRect bounds = self.bounds;
    CGFloat yOffset = floorf((CGRectGetHeight(bounds)-25)*0.5f);
    CGFloat trackMaxWidth = CGRectGetWidth(bounds)-4;
    CGFloat trackWidth = floorf(trackMaxWidth*self.value);

    return CGRectMake(2, yOffset+7, floorf(trackWidth), 10);
}

// Only override drawRect: if you perform custom drawing.
// An empty implementation adversely affects performance during animation.
- (CGRect) _progressRect
{
    CGRect bounds = self.bounds;
    CGFloat yOffset = floorf((CGRectGetHeight(bounds)-25)*0.5f);
    CGFloat trackMaxWidth = CGRectGetWidth(bounds)-4;
    CGFloat trackWidth = floorf(trackMaxWidth*self.progress);

    return CGRectMake(2, yOffset+7, floorf(trackWidth), 10);
}

- (void) setEnabled:(BOOL)enabled
{
    [super setEnabled:enabled];
    [self setNeedsLayout];
}

- (void) layoutSubviews
{
	[super layoutSubviews];

    CGRect bounds = self.bounds;
    CGFloat yOffset = floorf((CGRectGetHeight(bounds)-25)*0.5f);
    self.backgroundView.frame = CGRectMake(2, yOffset+7, CGRectGetWidth(bounds)-4, 10);

    self.progressView.frame = [self _progressRect];

    // Chapter markers overlay on the track area
    self.chapterMarkersView.frame = CGRectMake(0, yOffset+7, CGRectGetWidth(bounds), 10);

	self.knobButton.frame = [self _knobRect];
	self.knobButton.enabled = self.enabled;

    self.trackView.frame = [self _trackRect];
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event
{
	if (!self.enabled) {
		return NO;
	}

	NSSet* mytouches = [event touchesForView:self];

	if ([mytouches count] == 1) {
		CGPoint location = [touch locationInView:self];
		// Allow touch anywhere on the slider - drag from current position without jumping
		if (CGRectContainsPoint(self.bounds, location)) {
			self.knobButton.highlighted = YES;
			// Make indicator more visible while dragging: lighter in dark mode, darker in light mode
			if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
				self.knobButton.tintColor = [UIColor colorWithWhite:1.0 alpha:1.0];
			} else {
				self.knobButton.tintColor = [UIColor colorWithWhite:0.0 alpha:1.0];
			}
			self.trackingStartPoint = location;
			self.trackingKnobStartRect = [self _knobRect];
			self.valueBeforeTracking = self.value;
			return YES;
		}
	}

	return NO;
}

- (CGFloat) deltaFromStartPoint:(CGPoint)startPoint currentPoint:(CGPoint)currentPoint reset:(BOOL*)reset
{
	if (!self.scrubbingModesEnabled || fabs(currentPoint.y - startPoint.y) < 30) {
		*reset = YES;
		self.scrubbingMode = kICProgressSliderScrubbingModeHiSpeed;
		return currentPoint.x - startPoint.x;
	}
	
	CGPoint delta = CGPointMake(currentPoint.x - startPoint.x, (currentPoint.y - startPoint.y) / 30.0f);
	if (delta.y == 0) {
		delta.y = (currentPoint.y > startPoint.y) ? 0.1 : -0.1;
	}
	delta.y = (delta.y > 0) ? delta.y : -delta.y;
	CGFloat r = delta.x / delta.y;
	
	if (delta.y < 4) {
		self.scrubbingMode = kICProgressSliderScrubbingModeHalf;
	}
	else if (delta.y < 8) {
		self.scrubbingMode = kICProgressSliderScrubbingModeQuarter;
	}
	else if (delta.y < 12) {
		self.scrubbingMode = kICProgressSliderScrubbingModeFine;
	}
	
	if (r < 0) {
		r = MAX(delta.x, r);
	} else {
		r = MIN(delta.x, r);
	}
	
	*reset = NO;
    
	return r;
}

- (void) _valueChangedTimer
{
    self.valueChangedTimer = nil;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event
{
	if (!self.enabled) {
		return NO;
	}

	NSSet* mytouches = [event touchesForView:self];

	if ([mytouches count] == 1) {
		CGPoint location = [touch locationInView:self];
		BOOL reset = NO;
		CGFloat delta = [self deltaFromStartPoint:self.trackingStartPoint currentPoint:location reset:&reset];
		CGRect knobRect = CGRectMake(CGRectGetMinX(self.trackingKnobStartRect)+delta,
                                     CGRectGetMinY(self.trackingKnobStartRect),
                                     CGRectGetWidth(self.trackingKnobStartRect),
                                     CGRectGetHeight(self.trackingKnobStartRect)
                                     );
		knobRect.origin.x = MAX(-20,knobRect.origin.x);
		knobRect.origin.x = MIN(knobRect.origin.x, CGRectGetWidth(self.bounds)-24);
		self.trackingKnobRect = knobRect;

        double newValue = self.valueBeforeTracking + (delta / ((double)CGRectGetWidth(self.bounds)-4));
        self.value = newValue;

        if (!self.valueChangedTimer) {
            self.valueChangedTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(_valueChangedTimer) userInfo:nil repeats:NO];
        }

		if (reset) {
			self.trackingStartPoint = CGPointMake(self.trackingStartPoint.x+ (CGRectGetMinX(self.trackingKnobRect)-CGRectGetMinX(self.trackingKnobStartRect)), self.trackingStartPoint.y);
			self.trackingKnobStartRect = knobRect;
			self.valueBeforeTracking = self.value;
		}

		[self setNeedsLayout];

		return YES;
	}

	return NO;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event
{
	[self.valueChangedTimer invalidate];
	self.valueChangedTimer = nil;
	self.trackingStartPoint = CGPointZero;
	self.trackingKnobRect = CGRectZero;
	self.knobButton.highlighted = NO;
	self.knobButton.tintColor = nil; // Reset to default tint color
	self.scrubbingMode = kICProgressSliderScrubbingModeNoScrubbing;
}

- (void)cancelTrackingWithEvent:(UIEvent *)event
{
    [self.valueChangedTimer invalidate];
    self.valueChangedTimer = nil;
    self.trackingStartPoint = CGPointZero;
	self.trackingKnobRect = CGRectZero;
	self.knobButton.highlighted = NO;
	self.knobButton.tintColor = nil; // Reset to default tint color
	self.scrubbingMode = kICProgressSliderScrubbingModeNoScrubbing;
    [self sendActionsForControlEvents:UIControlEventTouchCancel];
}

@end
