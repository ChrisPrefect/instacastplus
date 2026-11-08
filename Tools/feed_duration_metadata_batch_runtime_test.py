#!/usr/bin/env python3
"""Compatibility contract for the production duration-metadata read boundary.

The failing 1,000-feed app E2E is the performance gate. This isolated real Core
Data/model/store check covers pending inserts, edits, deletion and temporary feed
IDs, which a UI E2E cannot hold reliably at an unsaved context checkpoint. A batch
read must preserve the existing per-feed predicate, including unsaved user edits.
This test is written before the batch-read production change.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'Classes/Model/SubscriptionManager.m').read_text()


def method(signature):
    start=source.index(signature);brace=source.index('{',start);depth=0
    for end in range(brace,len(source)):
        depth+=(source[end]=='{')-(source[end]=='}')
        if depth==0:return source[start:end+1]
    raise AssertionError(signature)


single=method('- (BOOL)_feedNeedsDurationMetadataRefresh:')
batch=(method('- (NSSet<NSManagedObjectID*>*)_feedObjectIDsNeedingDurationMetadataRefresh:')
       if '- (NSSet<NSManagedObjectID*>*)_feedObjectIDsNeedingDurationMetadataRefresh:' in source else '''
- (NSSet*)_feedObjectIDsNeedingDurationMetadataRefresh:(NSArray*)feeds {
 NSMutableSet *result=[NSMutableSet set];
 for (id feed in feeds) if ([self _feedNeedsDurationMetadataRefresh:feed]) [result addObject:[feed objectID]];
 return result;
}
''')
program=r'''
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <objc/runtime.h>
#define CDFeed NSManagedObject
#define CDEpisode NSManagedObject
static NSString *const kFeedPropertyDurationRefreshAttempted=@"durationMetadataRefreshAttempted";
@interface NSManagedObject(Flags)
- (BOOL)boolForKey:(NSString*)key;
@end
@implementation NSManagedObject(Flags)
- (BOOL)boolForKey:(NSString*)key {return [objc_getAssociatedObject(self,@selector(boolForKey:)) boolValue];}
@end
@interface ICDiagnosticLogger:NSObject
+ (id)shared;
- (void)logEvent:(NSString*)category message:(NSString*)message metadata:(NSDictionary*)metadata;
@end
@implementation ICDiagnosticLogger
+ (id)shared{return [self new];}
- (void)logEvent:(NSString*)category message:(NSString*)message metadata:(NSDictionary*)metadata {}
@end
@interface Owner:NSObject @end
@implementation Owner
SINGLE
BATCH
@end
static NSManagedObject *insert(NSManagedObjectContext *context,NSString *entity){return [NSEntityDescription insertNewObjectForEntityForName:entity inManagedObjectContext:context];}
static NSManagedObject *episode(NSManagedObjectContext *context,NSManagedObject *feed,NSInteger duration){
 id e=insert(context,@"Episode");[e setValue:feed forKey:@"feed"];[e setValue:@(duration) forKey:@"duration"];
 [e setValue:@NO forKey:@"archived"];[e setValue:@NO forKey:@"consumed"];[e setValue:@0 forKey:@"position"];return e;
}
static void check(Owner *owner,NSArray *feeds,NSArray *expected,NSString *name){
 NSSet *actual=[owner _feedObjectIDsNeedingDurationMetadataRefresh:feeds];
 NSSet *ids=[NSSet setWithArray:[expected valueForKey:@"objectID"]];
 if (![actual isEqual:ids]) {NSLog(@"FAIL %@: %@ expected %@",name,actual,ids);exit(1);}
 NSLog(@"PASS %@",name);
}
int main(int argc,const char **argv){@autoreleasepool {
 NSManagedObjectModel *loaded=[[NSManagedObjectModel alloc]initWithContentsOfURL:[NSURL fileURLWithPath:@(argv[1])]];
 NSManagedObjectModel *model=[loaded copy];for(NSEntityDescription *entity in model.entities)entity.managedObjectClassName=@"NSManagedObject";
 NSPersistentStoreCoordinator *coordinator=[[NSPersistentStoreCoordinator alloc]initWithManagedObjectModel:model];NSError *error;
 [coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[NSURL fileURLWithPath:@(argv[2])] options:nil error:&error];if(error)abort();
 NSManagedObjectContext *context=[[NSManagedObjectContext alloc]initWithConcurrencyType:NSMainQueueConcurrencyType];context.persistentStoreCoordinator=coordinator;
 id a=insert(context,@"Feed"),b=insert(context,@"Feed");id e=episode(context,a,900);episode(context,b,900);[context save:&error];if(error)abort();
 Owner *owner=[Owner new];NSArray *feeds=@[a,b];check(owner,feeds,@[],@"complete durable metadata");
 [e setValue:@0 forKey:@"duration"];check(owner,feeds,@[a],@"unsaved missing duration");
 [e setValue:@YES forKey:@"consumed"];check(owner,feeds,@[],@"unsaved consumed flag");
 [e setValue:@NO forKey:@"consumed"];[context save:&error];check(owner,feeds,@[a],@"durable missing duration");
 [e setValue:@900 forKey:@"duration"];check(owner,feeds,@[],@"unsaved metadata repair overrides stored row");
 [e setValue:@0 forKey:@"duration"];[context deleteObject:e];check(owner,feeds,@[],@"pending deletion excluded");
 id pending=episode(context,b,0);check(owner,feeds,@[b],@"unsaved insertion included");
 [pending setValue:@YES forKey:@"archived"];check(owner,feeds,@[],@"unsaved archived episode excluded");
 [pending setValue:@NO forKey:@"archived"];[pending setValue:@30 forKey:@"position"];check(owner,feeds,@[],@"started episode excluded");
 [pending setValue:@0 forKey:@"position"];objc_setAssociatedObject(b,@selector(boolForKey:),@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);check(owner,feeds,@[],@"attempted full parse excluded");
 id temporary=insert(context,@"Feed");episode(context,temporary,0);check(owner,@[a,b,temporary],@[temporary],@"temporary feed identity and pending episode");
 puts("PASS: real model/store duration metadata read contract");return 0;
}}
'''.replace('SINGLE',single).replace('BATCH',batch)
with tempfile.TemporaryDirectory(prefix='instacast-duration-read-') as temporary:
    directory=Path(temporary);model=directory/'Model.mom'
    subprocess.run(['xcrun','momc',str(ROOT/'Resources/Models/Model5.xcdatamodeld/Model9.xcdatamodel'),str(model)],check=True,capture_output=True)
    (directory/'main.m').write_text(program)
    subprocess.run(['xcrun','clang','-fobjc-arc','-framework','Foundation','-framework','CoreData',str(directory/'main.m'),'-o',str(directory/'test')],check=True)
    subprocess.run([str(directory/'test'),str(model),str(directory/'store.sqlite')],check=True)
