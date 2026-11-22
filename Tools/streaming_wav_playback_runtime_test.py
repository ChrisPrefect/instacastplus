#!/usr/bin/env python3
"""Exercise the complete production stream loader with native AVFoundation WAV playback.

The actual App E2E failure and isolation matrix are retained in
Tools/transcription-server/2026-10-03-server-source-evidence/player-failure-test-plan.md.
Only Core Data/cache path and import boundaries are substituted; AVFoundation,
HTTP, URLSession, range delivery and file validation are real production behavior.
"""
from pathlib import Path
import subprocess,tempfile,threading,http.server
root=Path(__file__).resolve().parents[1];p=root/'Classes/PlaybackManager.m';s=p.read_text()
loader=s[s.index('typedef struct {',s.index('IdleState')):s.index('\n#endif\n\n@class ICStreamingCacheLoader;')]
pre=r'''
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <math.h>
#import <limits.h>
#define ErrLog(...) NSLog(__VA_ARGS__)
@interface NSString (Probe)
@property(readonly) NSString *ls;
- (BOOL)caseInsensitiveEquals:(NSString*)other;
@end
@implementation NSString (Probe)
- (NSString*)ls{return self;}
- (BOOL)caseInsensitiveEquals:(NSString*)other{return [self caseInsensitiveCompare:other]==NSOrderedSame;}
@end
// Declared in Swift (ICSilenceTrimPlayer.swift); the loader adopts it for pause shortening.
@protocol ICSilenceTrimStreamSource <AVAssetResourceLoaderDelegate>
@property (nonatomic, readonly, strong) dispatch_queue_t resourceLoaderQueue;
- (void)abandonLoadingRequests:(NSArray<AVAssetResourceLoadingRequest*>*)requests;
@end
@interface CDEpisode:NSObject
@property NSString *objectHash;
@end
@implementation CDEpisode @end
static NSURL *probeRoot;
static NSURL *cached;
@interface CacheManager:NSObject
+ (instancetype)sharedCacheManager;
+ (NSString*)fileExtensionForMIMEType:(NSString*)mime;
- (BOOL)episodeIsCached:(CDEpisode*)e;
- (NSURL*)URLForCachedEpisode:(CDEpisode*)e;
- (void)finishStreamingCacheForEpisode:(CDEpisode*)e leaseToken:(NSString*)t;
- (void)failStreamingCacheForEpisode:(CDEpisode*)e error:(NSError*)err leaseToken:(NSString*)t;
- (void)importStreamingFileAtURL:(NSURL*)url forEpisode:(CDEpisode*)e leaseToken:(NSString*)t completion:(void(^)(BOOL,NSError*))c;
- (NSURL*)streamingTempURLForCachedEpisode:(CDEpisode*)e leaseToken:(NSString*)t;
@end
@implementation CacheManager
+ (instancetype)sharedCacheManager{return [self new];}
+ (NSString*)fileExtensionForMIMEType:(NSString*)mime{return @"wav";}
- (BOOL)episodeIsCached:(CDEpisode*)e{return cached!=nil;}
- (NSURL*)URLForCachedEpisode:(CDEpisode*)e{return cached;}
- (void)finishStreamingCacheForEpisode:(CDEpisode*)e leaseToken:(NSString*)t{}
- (void)failStreamingCacheForEpisode:(CDEpisode*)e error:(NSError*)err leaseToken:(NSString*)t{NSLog(@"CACHE ERROR %@",err);}
- (void)importStreamingFileAtURL:(NSURL*)url forEpisode:(CDEpisode*)e leaseToken:(NSString*)t completion:(void(^)(BOOL,NSError*))c{cached=url;c(YES,nil);}
- (NSURL*)streamingTempURLForCachedEpisode:(CDEpisode*)e leaseToken:(NSString*)t{return [probeRoot URLByAppendingPathComponent:@"download.wav"];}
@end
'''
post=r'''
int main(int argc,char **argv){@autoreleasepool {
 NSString *mode=@(argv[1]);probeRoot=[NSURL fileURLWithPath:@(argv[4])];CDEpisode *e=[CDEpisode new];e.objectHash=@"probe";
 ICStreamingCacheLoader *loader=nil;AVURLAsset *asset=nil;
 if([mode isEqual:@"local"])asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(argv[3])] options:nil];
 else {
 NSError *error=nil;
 loader=[[ICStreamingCacheLoader alloc]initWithEpisode:e remoteURL:[NSURL URLWithString:@(argv[2])] expectedSize:3674826 mimeType:mode username:nil password:nil leaseToken:@"probe" error:&error];
 if(!loader){NSLog(@"INIT ERROR %@",error);return 2;}
 asset=[AVURLAsset URLAssetWithURL:loader.assetURL options:nil];[asset.resourceLoader setDelegate:loader queue:loader.resourceLoaderQueue];
 }
 AVPlayerItem *item=[AVPlayerItem playerItemWithAsset:asset];AVPlayer *player=[AVPlayer playerWithPlayerItem:item];
 NSDate *until=[NSDate dateWithTimeIntervalSinceNow:8];
 while(item.status==AVPlayerItemStatusUnknown && until.timeIntervalSinceNow>0)[[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
 printf("mode=%s status=%ld duration=%.6f error=%s\n",mode.UTF8String,(long)item.status,CMTimeGetSeconds(item.duration),item.error.description.UTF8String);
 [player pause];[loader stop];return item.status==AVPlayerItemStatusReadyToPlay && fabs(CMTimeGetSeconds(item.duration)-114.835875)<.001?0:1;
}}
'''
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  d=(root/'Tools/fixtures/server-sponsor-e2e/fixture.wav').read_bytes();self.send_response(200);self.send_header('Content-Type','audio/x-wav' if self.path=='/x-wav' else 'audio/wav');self.send_header('Content-Length',len(d));self.end_headers();self.wfile.write(d)
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
try:
 with tempfile.TemporaryDirectory(prefix='instacast-production-stream-') as directory:
  target=Path(directory);(target/'main.m').write_text(pre+loader+post)
  subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-deprecated-declarations','-framework','Foundation','-framework','AVFoundation','-framework','CoreMedia',str(target/'main.m'),'-o',str(target/'probe')],check=True)
  failures=[]
  for mode in ['local','audio/wav','audio/x-wav']:
   media_directory=target/mode;media_directory.mkdir(parents=True,exist_ok=True)
   suffix='x-wav' if mode=='audio/x-wav' else 'fixture.wav'
   result=subprocess.run([str(target/'probe'),mode,f'http://127.0.0.1:{server.server_port}/{suffix}',str(root/'Tools/fixtures/server-sponsor-e2e/fixture.wav'),str(media_directory)],text=True,capture_output=True,timeout=15)
   print(result.stdout,end='',flush=True)
   if result.stderr:print(result.stderr,end='',flush=True)
   if result.returncode:failures.append(mode)
  if failures:raise AssertionError(f'Native AVPlayer did not become ready with the exact fixture duration: {failures}')
  print('Production WAV streaming and local AVFoundation controls passed')
finally:
 server.shutdown()
