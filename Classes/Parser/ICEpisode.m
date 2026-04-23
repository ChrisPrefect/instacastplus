//
//  ICEpisode.m
//  ICFeedParser
//
//  Created by Martin Hering on 16.07.12.
//  Copyright (c) 2012 Vemedio. All rights reserved.
//

#import "ICEpisode.h"
#import "ICMedia.h"

static NSString* ICMediaBaseMimeType(NSString* mimeType)
{
    NSString* baseType = [[mimeType componentsSeparatedByString:@";"] firstObject];
    return [[baseType stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
}

static NSString* ICMediaCodecText(ICMedia* media)
{
    NSMutableArray* parts = [NSMutableArray array];
    if (media.codec.length > 0) {
        [parts addObject:media.codec];
    }
    if (media.mimeType.length > 0) {
        [parts addObject:media.mimeType];
    }
    if (media.fileURL.absoluteString.length > 0) {
        [parts addObject:media.fileURL.absoluteString];
    }
    return [[parts componentsJoinedByString:@" "] lowercaseString];
}

static NSString* ICMediaCompactedCodecText(NSString* text)
{
    NSCharacterSet* allowed = [NSCharacterSet alphanumericCharacterSet];
    return [[text componentsSeparatedByCharactersInSet:[allowed invertedSet]] componentsJoinedByString:@""];
}

static BOOL ICMediaCodecTextContainsHEVC(NSString* text)
{
    NSString* compacted = ICMediaCompactedCodecText(text);
    return [text containsString:@"hevc"] ||
           [text containsString:@"hvc1"] ||
           [text containsString:@"hev1"] ||
           [text containsString:@"x265"] ||
           [compacted containsString:@"h265"];
}

static BOOL ICMediaCodecTextContainsAVC(NSString* text)
{
    NSString* compacted = ICMediaCompactedCodecText(text);
    return [text containsString:@"avc1"] ||
           [text containsString:@"avc3"] ||
           [text containsString:@"x264"] ||
           [compacted containsString:@"h264"];
}

static BOOL ICMediaLooksLikeVideo(ICMedia* media)
{
    NSString* text = ICMediaCodecText(media);
    NSString* baseMimeType = ICMediaBaseMimeType(media.mimeType);
    NSString* extension = [[media.fileURL pathExtension] lowercaseString];
    if ([baseMimeType containsString:@"audio"]) {
        return NO;
    }
    return [baseMimeType containsString:@"video"] ||
           [extension isEqualToString:@"mp4"] ||
           [extension isEqualToString:@"m4v"] ||
           [extension isEqualToString:@"mov"] ||
           ICMediaCodecTextContainsHEVC(text) ||
           ICMediaCodecTextContainsAVC(text);
}

static BOOL ICMediaIsHEVCVideo(ICMedia* media)
{
    return ICMediaLooksLikeVideo(media) && ICMediaCodecTextContainsHEVC(ICMediaCodecText(media));
}

static BOOL ICMediaIsLegacyAVCVideo(ICMedia* media)
{
    return ICMediaLooksLikeVideo(media) && ICMediaCodecTextContainsAVC(ICMediaCodecText(media));
}

static BOOL ICMediaIsNonHEVCVideo(ICMedia* media)
{
    return ICMediaLooksLikeVideo(media) && !ICMediaIsHEVCVideo(media);
}

@implementation ICEpisode

+ (id) episode
{
    return [[self alloc] init];
}

- (BOOL) isEqual:(ICEpisode*)episode
{
	return ([self.guid isEqualToString:episode.guid]);
}

- (BOOL) isEqualToEpisode:(ICEpisode*)episode
{
	return ([self.objectHash isEqualToString:episode.objectHash]);
}

- (NSComparisonResult)compare:(ICEpisode *)episode
{
	NSComparisonResult result = [self.pubDate compare:episode.pubDate];
	if (result == NSOrderedAscending) {
		return NSOrderedDescending;
	}
	else if (result == NSOrderedDescending) {
		return NSOrderedAscending;
	}
	return NSOrderedSame;
}

#pragma mark -

- (NSString*) cleanTitleUsingFeedTitle:(NSString*)feedTitle
{
	NSString* title = self.title;
	
	if (!feedTitle) {
		return title;
	}
	
    NSMutableCharacterSet* set = [NSMutableCharacterSet characterSetWithCharactersInString:@"-:,;—#–"];
    [set formUnionWithCharacterSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    NSArray* trimStrings = [NSArray arrayWithObjects:feedTitle, @"episode", @"ep.", nil];
    
	if ([title length] > [feedTitle length]+3)
    {
        for(NSString* trimString in trimStrings)
        {
            NSRange trimRange = [title rangeOfString:trimString options:NSAnchoredSearch | NSCaseInsensitiveSearch];
            if (trimRange.location != NSNotFound) {
                title = [title stringByReplacingCharactersInRange:trimRange withString:@""];
                title = [title stringByTrimmingCharactersInSet:set];
            }
        }
	}
    
    title = [title stringByTrimmingCharactersInSet:set];
	return title;
}

- (NSString*) cleanedShowNotes
{
    NSMutableString* showNotes = [((self.textDescription) ? self.textDescription : self.summary) mutableCopy];
    [showNotes replaceOccurrencesOfRegex:@"<object.*?>.*?<\\/object>" withString:@""];
    [showNotes replaceOccurrencesOfRegex:@"<audio.*?>.*?<\\/audio>" withString:@""];
    [showNotes replaceOccurrencesOfRegex:@"<video.*?>.*?<\\/video>" withString:@""];
    [showNotes replaceOccurrencesOfRegex:@"style=\".*?\"" withString:@""];
    [showNotes replaceOccurrencesOfRegex:@"class=\".*?\"" withString:@""];
    [showNotes replaceOccurrencesOfString:@"<p></p>" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [showNotes length])];
    
    return showNotes;
}

- (ICMedia*) preferedMedium
{
    NSArray* mediaItems = self.media;
	if ([mediaItems count] == 0) {
		return nil;
	}

    NSMutableArray* allowedMediaItems = [NSMutableArray array];
    for(ICMedia* media in mediaItems) {
        if (ICMediaIsLegacyAVCVideo(media) || ICMediaIsNonHEVCVideo(media)) {
            continue;
        }
        [allowedMediaItems addObject:media];
    }
    mediaItems = allowedMediaItems;
    if ([mediaItems count] == 0) {
        return nil;
    }

    for(ICMedia* media in mediaItems) {
        if (ICMediaIsHEVCVideo(media)) {
            return media;
        }
    }
    
    NSArray* preferredMediaTypes = [NSArray arrayWithObjects:@"audio/x-m4a", @"video/mp4", @"video/x-m4v", @"audio/mpeg", nil];
    
	for(ICMedia* media in mediaItems) {
        if ([preferredMediaTypes containsObject:ICMediaBaseMimeType(media.mimeType)]) {
			return media;
		}
	}
	
	for(ICMedia* media in mediaItems) {
		if ([media.mimeType rangeOfString:@"audio" options:NSCaseInsensitiveSearch].location != NSNotFound ||
			[media.mimeType rangeOfString:@"video" options:NSCaseInsensitiveSearch].location != NSNotFound) {
			return media;
		}
	}
    
    ICMedia* media = [mediaItems objectAtIndex:0];
    
    if ([media.mimeType hasPrefix:@"image"]) {
        return nil;
    }
	
	return media;
}

@end
