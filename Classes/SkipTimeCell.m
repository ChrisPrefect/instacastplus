//
//  SkipTimeCell.m
//  Instacast
//
//  Created by DevD on 04/07/25.
//  Copyright © 2025 Vemedio. All rights reserved.
//

#import "SkipTimeCell.h"

@implementation SkipTimeCell

- (void)awakeFromNib {
    [super awakeFromNib];
    // Initialization code
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = [UIColor clearColor];
    // Configure the view for the selected state
}

@end
