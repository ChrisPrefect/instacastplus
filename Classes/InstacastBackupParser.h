//
//  InstacastBackupParser.h
//  Instacast
//

#import <Foundation/Foundation.h>

@class InstacastBackupData;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const ICXMLImportErrorDomain;

typedef NS_ENUM(NSInteger, ICXMLImportErrorCode) {
    ICXMLImportErrorFileTooLarge = 1,
    ICXMLImportErrorDocumentTooComplex = 2,
};

/// Shared resource bounds for externally supplied backup and OPML XML.
@interface ICXMLImportLimits : NSObject

+ (nullable NSData *)readDataFromURL:(NSURL *)url error:(NSError **)error;
+ (BOOL)validateData:(NSData *)data error:(NSError **)error;

@end

/// A single parser budget keeps backup and OPML limits identical.
@interface ICXMLImportParserBudget : NSObject

@property (nonatomic, readonly, nullable) NSError *error;

- (BOOL)consumeElement:(NSString *)elementName
            attributes:(NSDictionary<NSString *, NSString *> *)attributes
                parser:(NSXMLParser *)parser;
- (BOOL)consumeCharacters:(NSString *)characters parser:(NSXMLParser *)parser;
- (BOOL)consumeObjectWithParser:(NSXMLParser *)parser;
- (void)finishElement;
- (void)rejectEntityWithParser:(NSXMLParser *)parser;

@end

@interface InstacastBackupParser : NSObject

/// Quick-check if the data starts with an <instacast> root element
+ (BOOL)isInstacastBackupData:(NSData *)data;

/// Parse backup XML data on a background queue, deliver result on main queue
+ (void)parseData:(NSData *)data completion:(void(^)(InstacastBackupData * _Nullable data, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
