#!/usr/bin/env python3
"""Execute the real Swift bridge with imported ObjC factories and real toggle logic."""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
bridge=(ROOT/'Classes/AppIntents/ICIntentBridge.swift').read_text()
pm_header=(ROOT/'Classes/PlaybackManager.h').read_text()
pm_source=(ROOT/'Classes/PlaybackManager.m').read_text()
as_header=(ROOT/'Classes/AudioSession.h').read_text()
as_source=(ROOT/'Classes/AudioSession.m').read_text()

def block(text,signature):
    start=text.index(signature);brace=text.index('{',start);depth=0
    for end in range(brace,len(text)):
        depth+=(text[end]=='{')-(text[end]=='}')
        if not depth:return text[start:end+1]
    raise AssertionError(signature)

def declaration(text,pattern):
    return re.search(pattern,text,re.MULTILINE).group(0)

pm_factory_decl=declaration(pm_header,r'^\+ \(PlaybackManager\*\) playbackManager[^;]*;')
as_factory_decl=declaration(as_header,r'^\+ \(AudioSession\*\) sharedAudioSession[^;]*;')
play_episode_decl=declaration(as_header,r'^- \(void\) playEpisode:[^\n]*preservingPlaybackSource:[^;]*;')
pm_factory=block(pm_source,'+ (PlaybackManager*) playbackManager;')
as_factory=block(as_source,'+ (AudioSession*) sharedAudioSession')
toggle=block(as_source,'- (void) togglePlay')
properties='\n'.join(declaration(pm_header,rf'^@property[^\n]*\b{name};') for name in ['playingEpisode','ready','failed','paused'])
methods='\n'.join(block(bridge,sig) for sig in ['private static var pm:', 'static func play()', 'static func pause()', 'static func playPause()', 'static func nowPlayingTitle()'])
header='''#import <Foundation/Foundation.h>
@interface CDEpisode : NSObject
@property NSString *title;
@end
@interface PlaybackManager : NSObject
FACTORY
PROPERTIES
- (void)play;
- (void)pause;
- (void)playPause;
@end
@interface AudioSession : NSObject
SESSION_FACTORY
@property CDEpisode *episode;
PLAY_EPISODE
- (void)togglePlay;
- (void)updateNowPlayingInfo;
@end
void ICConfigure(BOOL selected,BOOL failed,BOOL ready,BOOL paused);
NSInteger ICInitializations(void);
NSInteger ICPlays(void);
NSInteger ICPauses(void);
NSInteger ICToggles(void);
NSInteger ICReopens(void);
NSInteger ICPreservedReopens(void);
'''.replace('SESSION_FACTORY',as_factory_decl).replace('FACTORY',pm_factory_decl).replace('PROPERTIES',properties).replace('PLAY_EPISODE',play_episode_decl)
objc=r'''#import "Bridge.h"
#import <dispatch/dispatch.h>
static CDEpisode *selectedEpisode;
static BOOL configuredFailed,configuredReady,configuredPaused;
static NSInteger initializations,plays,pauses,toggles,reopens,preservedReopens;
@implementation CDEpisode @end
@implementation PlaybackManager
PM_FACTORY
- (id)init {if((self=[super init]))initializations++;return self;}
// Fixture state belongs to the media boundary. The production factory and Swift
// getter are untouched, so accidental init remains observable independently.
- (CDEpisode*)playingEpisode{return selectedEpisode;}
- (BOOL)failed{return configuredFailed;}
- (BOOL)isReady{return configuredReady;}
- (BOOL)isPaused{return configuredPaused;}
- (void)play{plays++;}
- (void)pause{pauses++;}
- (void)playPause{toggles++;}
@end
@implementation AudioSession
AS_FACTORY
TOGGLE
- (void)playEpisode:(CDEpisode*)episode queueUpCurrent:(BOOL)queue at:(NSTimeInterval)time autostart:(BOOL)autostart preservingPlaybackSource:(BOOL)preserving {
    NSCAssert(episode==selectedEpisode && !queue && time==0 && autostart,@"Wrong episode retry");
    reopens++;if(preserving)preservedReopens++;
}
- (void)updateNowPlayingInfo{}
@end
void ICConfigure(BOOL selected,BOOL failed,BOOL ready,BOOL paused){
    selectedEpisode=selected?[CDEpisode new]:nil;selectedEpisode.title=@"Selected episode";
    configuredFailed=failed;configuredReady=ready;configuredPaused=paused;
    plays=pauses=toggles=reopens=preservedReopens=0;
    [AudioSession sharedAudioSession].episode=selectedEpisode;
}
NSInteger ICInitializations(void){return initializations;}
NSInteger ICPlays(void){return plays;}
NSInteger ICPauses(void){return pauses;}
NSInteger ICToggles(void){return toggles;}
NSInteger ICReopens(void){return reopens;}
NSInteger ICPreservedReopens(void){return preservedReopens;}
'''.replace('PM_FACTORY',pm_factory).replace('AS_FACTORY',as_factory).replace('TOGGLE',toggle)
swift='''import Foundation
@MainActor enum ICIntentBridge {
METHODS
private static func mostRecentlyPlayedEpisode() -> CDEpisode? { nil }
}
@main struct Test {
 @MainActor static func main() {
  var failures:[String]=[]
  var observations:[[String:Any]]=[]
  func check(_ name:String,_ value:Bool,_ observed:[String:Any]) {
   observations.append(["case":name,"passed":value,"observed":observed])
   if !value { failures.append(name) }
  }
  ICConfigure(true,false,true,true)
  _ = PlaybackManager.shared()
  let before=ICInitializations()
  let title=ICIntentBridge.nowPlayingTitle()
  check("shared_factory_identity",ICInitializations()==before && title=="Selected episode",
        ["initializations_before":before,"initializations_after":ICInitializations(),"title":title ?? "nil"])
  for action in ["play","playPause"] {
   ICConfigure(true,true,false,true)
   if action=="play" { ICIntentBridge.play() } else { ICIntentBridge.playPause() }
   check("failed_episode_"+action,ICReopens()==1 && ICPreservedReopens()==1 && ICPlays()==0 && ICToggles()==0,
         ["reopens":ICReopens(),"preserved":ICPreservedReopens(),"direct_play":ICPlays(),"direct_toggle":ICToggles()])
  }
  ICConfigure(true,false,true,true);ICIntentBridge.play()
  check("healthy_paused_play",ICPlays()==1 && ICReopens()==0,["direct_play":ICPlays(),"reopens":ICReopens()])
  ICConfigure(true,false,true,false);ICIntentBridge.play()
  check("healthy_playing_play",ICPlays()==0 && ICReopens()==0,["direct_play":ICPlays(),"reopens":ICReopens()])
  ICConfigure(true,false,true,false);ICIntentBridge.playPause()
  check("healthy_toggle",ICToggles()==1 && ICReopens()==0,["direct_toggle":ICToggles(),"reopens":ICReopens()])
  ICConfigure(true,false,false,false);ICIntentBridge.play()
  check("loading_does_not_restart",ICPlays()==0 && ICReopens()==0,["direct_play":ICPlays(),"reopens":ICReopens()])
  ICConfigure(false,false,false,true);ICIntentBridge.play();ICIntentBridge.playPause()
  check("empty_without_recent_episode",ICPlays()==0 && ICToggles()==0 && ICReopens()==0,["direct_play":ICPlays(),"direct_toggle":ICToggles(),"reopens":ICReopens()])
  let data=try! JSONSerialization.data(withJSONObject:observations,options:[.prettyPrinted,.sortedKeys])
  print(String(data:data,encoding:.utf8)!)
  if !failures.isEmpty { print("FAIL: "+failures.joined(separator:", "));exit(1) }
  print("PASS: 8 actual Swift/ObjC factory and transport cases")
 }
}
'''.replace('METHODS',methods)
with tempfile.TemporaryDirectory(prefix='instacast-intent-playback-') as temp:
    path=Path(temp);(path/'Bridge.h').write_text(header);(path/'Bridge.m').write_text(objc);(path/'main.swift').write_text(swift)
    subprocess.run(['xcrun','clang','-fobjc-arc','-fmodules','-Wno-nullability-completeness','-Wno-objc-method-access','-c',str(path/'Bridge.m'),'-o',str(path/'Bridge.o')],check=True)
    subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library','-import-objc-header',str(path/'Bridge.h'),str(path/'main.swift'),str(path/'Bridge.o'),'-framework','Foundation','-o',str(path/'test')],check=True)
    subprocess.run([str(path/'test')],check=True)
