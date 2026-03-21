//
//  ListEpisodesTableViewController.h
//  Instacast
//
//  Created by Martin Hering on 21.08.14.
//
//

#import "EpisodesTableViewController.h"

@class CDList;

@interface ListEpisodesTableViewController : EpisodesTableViewController

+ (instancetype) viewControllerWithList:(CDList*)list;

@property (nonatomic, strong) CDList* list;

@end
