//
//  SJLoadingView.m
//  Pods
//
//  Recreated to fix missing source file in local Pods checkout.
//

#import "SJLoadingView.h"

NS_ASSUME_NONNULL_BEGIN

@interface SJLoadingView ()
@property (nonatomic, strong, readonly) UIActivityIndicatorView *indicatorView;
@property (nonatomic, strong, readonly) UILabel *networkSpeedLabel;
@property (nonatomic, readwrite, getter=isAnimating) BOOL animating;
@end

@implementation SJLoadingView
@synthesize indicatorView = _indicatorView;
@synthesize networkSpeedLabel = _networkSpeedLabel;

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if ( self ) {
        self.backgroundColor = UIColor.clearColor;
        [self _setupViews];
    }
    return self;
}

- (void)_setupViews {
    [self addSubview:self.indicatorView];
    [self addSubview:self.networkSpeedLabel];

    self.indicatorView.translatesAutoresizingMaskIntoConstraints = NO;
    self.networkSpeedLabel.translatesAutoresizingMaskIntoConstraints = NO;

    [NSLayoutConstraint activateConstraints:@[
        [self.indicatorView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [self.indicatorView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.networkSpeedLabel.topAnchor constraintEqualToAnchor:self.indicatorView.bottomAnchor constant:8],
        [self.networkSpeedLabel.centerXAnchor constraintEqualToAnchor:self.indicatorView.centerXAnchor]
    ]];

    self.networkSpeedLabel.hidden = YES;
}

- (UIActivityIndicatorView *)indicatorView {
    if ( _indicatorView == nil ) {
        if (@available(iOS 13.0, *)) {
            _indicatorView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        } else {
            _indicatorView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
            _indicatorView.color = UIColor.whiteColor;
        }
        _indicatorView.hidesWhenStopped = YES;
    }
    return _indicatorView;
}

- (UILabel *)networkSpeedLabel {
    if ( _networkSpeedLabel == nil ) {
        _networkSpeedLabel = [UILabel new];
        _networkSpeedLabel.textColor = UIColor.whiteColor;
        _networkSpeedLabel.font = [UIFont systemFontOfSize:12];
        _networkSpeedLabel.numberOfLines = 1;
        _networkSpeedLabel.textAlignment = NSTextAlignmentCenter;
    }
    return _networkSpeedLabel;
}

- (void)setShowsNetworkSpeed:(BOOL)showsNetworkSpeed {
    _showsNetworkSpeed = showsNetworkSpeed;
    self.networkSpeedLabel.hidden = !showsNetworkSpeed;
}

- (void)setNetworkSpeedStr:(nullable NSAttributedString *)networkSpeedStr {
    _networkSpeedStr = networkSpeedStr;
    self.networkSpeedLabel.attributedText = networkSpeedStr;
}

- (void)start {
    self.animating = YES;
    [self.indicatorView startAnimating];
}

- (void)stop {
    self.animating = NO;
    [self.indicatorView stopAnimating];
}

@end

NS_ASSUME_NONNULL_END
