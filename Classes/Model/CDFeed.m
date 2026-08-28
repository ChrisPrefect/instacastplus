//
//  CDFeed.m
//  Instacast
//
//  Created by Martin Hering on 07.08.12.
//
//

#import "SFHFKeychainUtils.h"

#import "CDFeed.h"
#import "CDCategory.h"
#import "CDEpisode.h"
#import "CDFeedProperty.h"
#import "DatabaseManager.h"
#import "EpisodeLoadingManager.h"

static const NSUInteger ICFeedCountBatchSize = 400;
static NSMutableOrderedSet<CDFeed*>* gFeedsPendingCountLoad;
static BOOL gFeedCountBatchScheduled = NO;
static BOOL gFeedCountBatchInProgress = NO;

static NSObject* ICFeedCredentialLock(void)
{
    static NSObject* lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [[NSObject alloc] init];
    });
    return lock;
}

static NSArray<NSDictionary*>* ICGroupedFeedCountRows(NSManagedObjectContext* context,
                                                       NSArray<NSString*>* feedUIDs,
                                                       BOOL unplayedOnly,
                                                       NSError** error)
{
    NSExpressionDescription* feedUIDExpression = [[NSExpressionDescription alloc] init];
    feedUIDExpression.name = @"feedUID";
    feedUIDExpression.expression = [NSExpression expressionForKeyPath:@"feed.uid"];
    feedUIDExpression.expressionResultType = NSStringAttributeType;

    NSExpressionDescription* countExpression = [[NSExpressionDescription alloc] init];
    countExpression.name = @"episodeCount";
    countExpression.expression = [NSExpression expressionForFunction:@"count:"
                                                             arguments:@[[NSExpression expressionForEvaluatedObject]]];
    countExpression.expressionResultType = NSInteger64AttributeType;

    NSFetchRequest* request = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
    request.predicate = unplayedOnly
        ? [NSPredicate predicateWithFormat:@"archived == %@ AND consumed == %@ AND feed.uid IN %@", @NO, @NO, feedUIDs]
        : [NSPredicate predicateWithFormat:@"archived == %@ AND feed.uid IN %@", @NO, feedUIDs];
    request.resultType = NSDictionaryResultType;
    request.propertiesToFetch = @[feedUIDExpression, countExpression];
    request.propertiesToGroupBy = @[@"feed.uid"];
    return [context executeFetchRequest:request error:error];
}

@interface CDFeed ()
@property (nonatomic, strong) NSString * sourceURL_;
@property (nonatomic, strong) NSString * imageURL_;
@property (nonatomic, strong) NSString * linkURL_;
@property (nonatomic, strong) NSString * paymentURL_;

@property (nonatomic, readwrite) NSInteger unplayedCount;
@property (nonatomic, readwrite) NSInteger episodesCount;
@property (nonatomic, readwrite) NSInteger starredCount;
@end


@implementation CDFeed {
    BOOL        _observing;
    NSUInteger  _countsGeneration;
    BOOL        _countsLoadInProgress;
    BOOL        _countsRequireSave;
    NSMutableArray* _countCompletionBlocks;
}

- (NSString*) designatedUID
{
    return [self.sourceURL_ MD5Hash];
}

- (NSSet*) keyPathesForValuesNotToBeLogged
{
    return [NSSet setWithObjects:@"lastUpdate",nil];
}

@synthesize unplayedCount;
@synthesize episodesCount;
@synthesize starredCount;
@dynamic displayTitle;

@dynamic title;
@dynamic subtitle;
@dynamic summary;
@dynamic fulltext;
@dynamic sourceURL_;
@dynamic imageURL_;
@dynamic pubDate;
@dynamic lastUpdate;
@dynamic etag;
@dynamic contentHash;
@dynamic linkURL_;
@dynamic language;
@dynamic country;
@dynamic author;
@dynamic copyright;
@dynamic owner;
@dynamic ownerEmail;
@dynamic paymentURL_;
@dynamic username;
@dynamic rank;
@dynamic subscribed;
@dynamic parked;
@dynamic video;
@dynamic completed;
@dynamic explicitContent;
@dynamic categories;
@dynamic episodeLists;
@dynamic episodes;
@dynamic properties;

- (NSURL*) sourceURL
{
    if (self.sourceURL_) {
        return [NSURL URLWithString:self.sourceURL_];
    }
    return nil;
}

- (void) setSourceURL:(NSURL *)sourceURL
{
    // make sure we update the password, because it's sourceURL dependent
    NSString* oldPassword = self.password;
    
    self.sourceURL_ = [sourceURL absoluteString];
    
    if (oldPassword) {
        self.password = oldPassword;
    }
}

- (NSURL*) linkURL
{
    if (self.linkURL_) {
        return [NSURL URLWithString:self.linkURL_];
    }
    return nil;
}

- (void) setLinkURL:(NSURL *)linkURL
{
    self.linkURL_ = [linkURL absoluteString];
}

- (NSURL*) paymentURL
{
    if (self.paymentURL_) {
        return [NSURL URLWithString:self.paymentURL_];
    }
    return nil;
}

- (void) setPaymentURL:(NSURL *)paymentURL
{
    self.paymentURL_ = [paymentURL absoluteString];
}

- (NSURL*) imageURL
{
    if (self.imageURL_) {
        return [NSURL URLWithString:self.imageURL_];
    }
    return nil;
}

- (void) setImageURL:(NSURL *)imageURL
{
    self.imageURL_ = [imageURL absoluteString];
}

- (NSString*) password
{
    @synchronized(ICFeedCredentialLock()) {
        if (!self.username) {
            return nil;
        }

        NSError* error = nil;
        NSString* password = [SFHFKeychainUtils getPasswordForUsername:self.username
                                                        andServiceName:[self.sourceURL absoluteString]
                                                                 error:&error];

        if (error) {
            ErrLog(@"error getting password from keychain for feed: %@ (error: %@)", self.sourceURL.absoluteString, [error description]);
        }

        return password;
    }
}

- (void) setPassword:(NSString *)password
{
    @synchronized(ICFeedCredentialLock()) {
        NSError* error = nil;
        if (password) {
            if (![SFHFKeychainUtils storeUsername:self.username
                                      andPassword:password
                                   forServiceName:[self.sourceURL absoluteString]
                                   updateExisting:YES
                                            error:&error]) {
                ErrLog(@"error storing password in keychain for feed: %@ (error: %@)", self.sourceURL.absoluteString, [error description]);
            }
        }
        else if (self.username) {
            if (![SFHFKeychainUtils deleteItemForUsername:self.username
                                           andServiceName:[self.sourceURL absoluteString]
                                                    error:&error]) {
                ErrLog(@"error deleting password from keychain for feed: %@ (error: %@)", self.sourceURL.absoluteString, [error description]);
            }
        }
    }
}

- (BOOL)compareAndSetPassword:(NSString *)password
             expectedPassword:(NSString *)expectedPassword
      expectedPasswordPresent:(BOOL)expectedPasswordPresent
                      didMatch:(BOOL *)didMatch
                         error:(NSError **)error
{
    @synchronized(ICFeedCredentialLock()) {
        if (didMatch) *didMatch = NO;
        NSString* serviceName = [self.sourceURL absoluteString];
        if (self.username.length == 0 || serviceName.length == 0) {
            if (error) {
                *error = [NSError errorWithDomain:@"CDFeedCredentials"
                                             code:1
                                         userInfo:@{NSLocalizedDescriptionKey: @"The podcast credential identity is incomplete."}];
            }
            return NO;
        }

        NSError* readError = nil;
        NSString* currentPassword = [SFHFKeychainUtils getPasswordForUsername:self.username
                                                               andServiceName:serviceName
                                                                        error:&readError];
        if (readError) {
            if (error) *error = readError;
            return NO;
        }
        if ([currentPassword isEqualToString:password]) {
            if (didMatch) *didMatch = YES;
            return YES;
        }
        BOOL currentPasswordPresent = currentPassword != nil;
        BOOL expectedMatches = currentPasswordPresent == expectedPasswordPresent
            && (!expectedPasswordPresent || [currentPassword isEqualToString:expectedPassword]);
        if (!expectedMatches) {
            return YES;
        }

        NSError* writeError = nil;
        BOOL stored = [SFHFKeychainUtils storeUsername:self.username
                                           andPassword:password
                                        forServiceName:serviceName
                                        updateExisting:YES
                                                 error:&writeError];
        if (!stored || writeError) {
            if (error) {
                *error = writeError ?: [NSError errorWithDomain:@"CDFeedCredentials"
                                                            code:2
                                                        userInfo:@{NSLocalizedDescriptionKey: @"The podcast credentials could not be saved."}];
            }
            return NO;
        }

        NSError* verifyError = nil;
        NSString* storedPassword = [SFHFKeychainUtils getPasswordForUsername:self.username
                                                               andServiceName:serviceName
                                                                        error:&verifyError];
        if (verifyError || ![storedPassword isEqualToString:password]) {
            if (error) {
                *error = verifyError ?: [NSError errorWithDomain:@"CDFeedCredentials"
                                                             code:3
                                                         userInfo:@{NSLocalizedDescriptionKey: @"The podcast credentials could not be verified after saving."}];
            }
            return NO;
        }
        if (didMatch) *didMatch = YES;
        return YES;
    }
}

+ (NSSet*) keyPathsForValuesAffectingEpisodesCount
{
    return [[NSSet alloc] initWithObjects:@"episodes", nil];
}

- (NSInteger) episodesCount
{
    return MAX(episodesCount, 0);
}

+ (NSSet*) keyPathsForValuesAffectingUnplayedCount
{
    return [[NSSet alloc] initWithObjects:@"episodes", nil];
}

- (NSInteger) unplayedCount
{
    return MAX(unplayedCount, 0);
}

- (BOOL)countsLoaded
{
    return (unplayedCount >= 0 && episodesCount >= 0);
}

- (void)calculateCountsWithCompletion:(void (^)(NSInteger unplayedCount, NSInteger episodesCount))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self calculateCountsWithCompletion:completion];
        });
        return;
    }
    if (self.countsLoaded) {
        if (completion) {
            completion(unplayedCount, episodesCount);
        }
        return;
    }

    if (completion) {
        if (!_countCompletionBlocks) {
            _countCompletionBlocks = [[NSMutableArray alloc] init];
        }
        [_countCompletionBlocks addObject:[completion copy]];
    }

    if (_countsRequireSave) {
        return;
    }
    if (_countsLoadInProgress) {
        return;
    }

    if (!gFeedsPendingCountLoad) {
        gFeedsPendingCountLoad = [[NSMutableOrderedSet alloc] init];
    }
    [gFeedsPendingCountLoad addObject:self];
    [CDFeed _schedulePendingCountBatch];
}

+ (void)_schedulePendingCountBatch
{
    if (gFeedCountBatchScheduled || gFeedCountBatchInProgress || gFeedsPendingCountLoad.count == 0) {
        return;
    }
    gFeedCountBatchScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _loadPendingCountBatch];
    });
}

+ (void)_loadPendingCountBatch
{
    gFeedCountBatchScheduled = NO;
    if (gFeedCountBatchInProgress || gFeedsPendingCountLoad.count == 0) {
        return;
    }

    NSArray<CDFeed*>* candidates = gFeedsPendingCountLoad.array;
    [gFeedsPendingCountLoad removeAllObjects];
    NSMutableDictionary<NSString*, CDFeed*>* feedsByUID = [NSMutableDictionary dictionaryWithCapacity:candidates.count];
    NSMutableDictionary<NSString*, NSNumber*>* generationsByUID = [NSMutableDictionary dictionaryWithCapacity:candidates.count];
    NSMutableDictionary<NSString*, NSNumber*>* expectedCountsByUID = [NSMutableDictionary dictionary];
    for (CDFeed* feed in candidates) {
        if (feed.isDeleted || feed.countsLoaded || feed->_countsRequireSave || feed->_countsLoadInProgress) {
            continue;
        }
        if (feed.uid.length == 0) {
            NSArray* completionBlocks = [feed->_countCompletionBlocks copy];
            [feed->_countCompletionBlocks removeAllObjects];
            for (void (^completionBlock)(NSInteger, NSInteger) in completionBlocks) {
                completionBlock(-1, -1);
            }
            continue;
        }

        feed->_countsLoadInProgress = YES;
        feedsByUID[feed.uid] = feed;
        generationsByUID[feed.uid] = @(feed->_countsGeneration);
        BOOL episodeLoadingComplete = [feed boolForKey:kFeedPropertyEpisodeLoadingComplete];
        NSInteger totalExpected = [feed integerForKey:kFeedPropertyTotalExpectedEpisodes];
        if (!episodeLoadingComplete && totalExpected > 0) {
            expectedCountsByUID[feed.uid] = @(totalExpected);
        }
    }
    if (feedsByUID.count == 0) {
        [self _schedulePendingCountBatch];
        return;
    }

    gFeedCountBatchInProgress = YES;
    NSArray<NSString*>* feedUIDs = feedsByUID.allKeys;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __block NSError* countError = nil;
        __block NSMutableDictionary<NSString*, NSNumber*>* episodeCountsByUID = [NSMutableDictionary dictionaryWithCapacity:feedUIDs.count];
        __block NSMutableDictionary<NSString*, NSNumber*>* unplayedCountsByUID = [NSMutableDictionary dictionaryWithCapacity:feedUIDs.count];
        NSManagedObjectContext* context = [DMANAGER newBackgroundContext];
        if (!context) {
            countError = [NSError errorWithDomain:@"CDFeedCounts" code:1 userInfo:nil];
        }
        else {
            [context performBlockAndWait:^{
                for (NSUInteger offset = 0; offset < feedUIDs.count && !countError; offset += ICFeedCountBatchSize) {
                    NSArray<NSString*>* UIDBatch = [feedUIDs subarrayWithRange:NSMakeRange(offset, MIN(ICFeedCountBatchSize, feedUIDs.count - offset))];
                    NSArray<NSDictionary*>* episodeRows = ICGroupedFeedCountRows(context, UIDBatch, NO, &countError);
                    if (!episodeRows || countError) break;
                    NSArray<NSDictionary*>* unplayedRows = ICGroupedFeedCountRows(context, UIDBatch, YES, &countError);
                    if (!unplayedRows || countError) break;
                    for (NSDictionary* row in episodeRows) {
                        NSString* feedUID = row[@"feedUID"];
                        NSNumber* count = row[@"episodeCount"];
                        if (feedUID.length > 0 && count) episodeCountsByUID[feedUID] = count;
                    }
                    for (NSDictionary* row in unplayedRows) {
                        NSString* feedUID = row[@"feedUID"];
                        NSNumber* count = row[@"episodeCount"];
                        if (feedUID.length > 0 && count) unplayedCountsByUID[feedUID] = count;
                    }
                }
            }];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            gFeedCountBatchInProgress = NO;
            for (NSString* feedUID in feedUIDs) {
                CDFeed* feed = feedsByUID[feedUID];
                feed->_countsLoadInProgress = NO;
                NSArray* completionBlocks = [feed->_countCompletionBlocks copy];
                [feed->_countCompletionBlocks removeAllObjects];

                if (feed.isDeleted || countError) {
                    for (void (^completionBlock)(NSInteger, NSInteger) in completionBlocks) {
                        completionBlock(-1, -1);
                    }
                    continue;
                }
                if (feed->_countsGeneration != [generationsByUID[feedUID] unsignedIntegerValue]) {
                    for (void (^completionBlock)(NSInteger, NSInteger) in completionBlocks) {
                        [feed calculateCountsWithCompletion:completionBlock];
                    }
                    continue;
                }

                NSInteger episodesCount = [episodeCountsByUID[feedUID] integerValue];
                episodesCount = MAX(episodesCount, [expectedCountsByUID[feedUID] integerValue]);
                NSInteger unplayedCount = [unplayedCountsByUID[feedUID] integerValue];
                feed.unplayedCount = unplayedCount;
                feed.episodesCount = episodesCount;
                for (void (^completionBlock)(NSInteger, NSInteger) in completionBlocks) {
                    completionBlock(unplayedCount, episodesCount);
                }
            }
            [self _schedulePendingCountBatch];
        });
    });
}

- (NSInteger) downloadedCount
{
    NSArray* cachedEpisodes = [CacheManager sharedCacheManager].cachedEpisodes;
    NSInteger i = 0;
    for(CDEpisode* episode in cachedEpisodes) {
        if ([episode.feed isEqual:self]) {
            i++;
        }
    }
    return i;
}


- (void) invalidateCounts
{
    [self invalidateCountsAwaitingSave:NO];
}

- (void)invalidateCountsAwaitingSave:(BOOL)awaitingSave
{
    _countsRequireSave |= awaitingSave;
    _countsGeneration++;
    [self willChangeValueForKey:@"unplayedCount"];
    unplayedCount = -1;
    [self didChangeValueForKey:@"unplayedCount"];

    [self willChangeValueForKey:@"episodesCount"];
    episodesCount = -1;
    [self didChangeValueForKey:@"episodesCount"];

    [self invalidateDownloadedCount];
}

- (void)feedCountChangesDidSave
{
    _countsRequireSave = NO;
    if (_countCompletionBlocks.count > 0) {
        [self calculateCountsWithCompletion:nil];
    }
}

- (void)feedCountChangesDidFailSave
{
    NSArray* completionBlocks = [_countCompletionBlocks copy];
    [_countCompletionBlocks removeAllObjects];
    for (void (^completionBlock)(NSInteger, NSInteger) in completionBlocks) {
        completionBlock(-1, -1);
    }
}

- (void) invalidateDownloadedCount
{
    [self willChangeValueForKey:@"downloadedCount"];
    [self didChangeValueForKey:@"downloadedCount"];
}

- (void) awakeFromFetch
{
    [super awakeFromFetch];
    [self invalidateCounts];
}

- (void)willTurnIntoFault
{
    _countsRequireSave = NO;
    [_countCompletionBlocks removeAllObjects];
    [super willTurnIntoFault];
}

- (NSDate*) lastPlayed
{
    NSArray* sortedEpisodes = [self.episodes sortedArrayUsingDescriptors:@[ [[NSSortDescriptor alloc] initWithKey:@"lastPlayed" ascending:NO] ]];
    NSDate* lastPlayed = ((CDEpisode*)[sortedEpisodes firstObject]).lastPlayed;
    return lastPlayed;
}

- (NSDate*) lastPubDate
{
    NSArray* sortedEpisodes = [self.episodes sortedArrayUsingDescriptors:@[ [[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:NO] ]];
    NSDate* pubDate = ((CDEpisode*)[sortedEpisodes firstObject]).pubDate;
    return pubDate;
}

- (NSString*) displayTitle
{
    if ([self stringForKey:kUserDefinedFeedName]) {
        return [self stringForKey:kUserDefinedFeedName];
    }
    
    return self.title;
}

- (void) setDisplayTitle:(NSString *)displayTitle
{
    if (![[self stringForKey:kUserDefinedFeedName] isEqualToString:displayTitle]) {
        [self setString:displayTitle forKey:kUserDefinedFeedName];
    }
}



@end


NSString* kUserDefinedFeedName = @"UserDefinedFeedName";

@implementation CDFeed (FeedProperties)

- (CDFeedProperty*) propertyForKey:(NSString*)key insertOnDemand:(BOOL)insertOnDemand
{
    CDFeedProperty* property = nil;
    
    for(CDFeedProperty* p in self.properties) {
        if ([p.key isEqualToString:key]) {
            property = p;
            break;
        }
    }
    
    if (!property && insertOnDemand) {
        property = [NSEntityDescription insertNewObjectForEntityForName:@"FeedProperty" inManagedObjectContext:self.managedObjectContext];
        property.key = key;
        
        [[self mutableSetValueForKey:@"properties"] addObject:property];
    }
    return property;
}


- (BOOL) boolForKey:(NSString*)defaultName
{
    CDFeedProperty* property = [self propertyForKey:defaultName insertOnDemand:NO];
    if (property) {
        return property.boolValue;
    }
    
    return [USER_DEFAULTS boolForKey:defaultName];
}

- (void) setBool:(BOOL)boolValue forKey:(NSString *)defaultName
{
    CDFeedProperty* property = [self propertyForKey:defaultName insertOnDemand:YES];
    property.boolValue = boolValue;
}

- (NSInteger) integerForKey:(NSString*)defaultName
{
    CDFeedProperty* property = [self propertyForKey:defaultName insertOnDemand:NO];
    if (property) {
        return property.int32Value;
    }
    
    return [USER_DEFAULTS integerForKey:defaultName];
}

- (void) setInteger:(NSInteger)integerValue forKey:(NSString *)defaultName
{
    CDFeedProperty* property = [self propertyForKey:defaultName insertOnDemand:YES];
    property.int32Value = (int32_t)integerValue;
}

- (NSString*) stringForKey:(NSString*)defaultName
{
    CDFeedProperty* property = [self propertyForKey:defaultName insertOnDemand:NO];
    if (property) {
        return property.stringValue;
    }
    
    return [USER_DEFAULTS stringForKey:defaultName];
}

- (void) setString:(NSString*)stringValue forKey:(NSString *)defaultName
{
    CDFeedProperty* property = [self propertyForKey:defaultName insertOnDemand:YES];
    property.stringValue = stringValue;
}

- (double) doubleForKey:(NSString*)defaultName
{
    CDFeedProperty* property = [self propertyForKey:defaultName insertOnDemand:NO];
    if (property) {
        return property.doubleValue;
    }
    
    return [USER_DEFAULTS doubleForKey:defaultName];
}

- (void) setDouble:(double)doubleValue forKey:(NSString *)defaultName
{
    CDFeedProperty* property = [self propertyForKey:defaultName insertOnDemand:YES];
    property.doubleValue = doubleValue;
}

- (void) resetValueForKey:(NSString*)defaultName
{
    CDFeedProperty* property = [self propertyForKey:defaultName insertOnDemand:NO];
    if (property) {
        [self.managedObjectContext deleteObject:property];
    }
}

- (void) resetAllProperties
{
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"FeedProperty" inManagedObjectContext:self.managedObjectContext];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"feed == %@ OR feed == nil", self];
    NSArray* properties = [self.managedObjectContext executeFetchRequest:fetchRequest error:nil];
    
    for(NSManagedObject* object in properties) {
        [self.managedObjectContext deleteObject:object];
    }
    self.properties = nil;
}

- (BOOL) hasCustomProperties
{
    static NSSet* internalKeys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        internalKeys = [NSSet setWithObjects:@"episodeLoadingComplete",
                        @"loadedEpisodeCount",
                        @"totalExpectedEpisodes",
                        @"preferredTranscriptLanguage",
                        @"preferredTranscriptURL",
                        @"cachedPlayerTintColor",
                        nil];
    });

    for (CDFeedProperty* property in self.properties) {
        if (![internalKeys containsObject:property.key]) {
            // PauseFeedSynchronization is obsolete — parked attribute is used directly
            if ([property.key isEqualToString:@"PauseFeedSynchronization"]) {
                continue;
            }
            return YES;
        }
    }
    return NO;
}

- (NSArray*) propertyKeys
{
    NSMutableArray* keys = [NSMutableArray array];
    
    for(CDFeedProperty* property in self.properties) {
        [keys addObject:property.key];
    }
    
    return keys;
}
@end
