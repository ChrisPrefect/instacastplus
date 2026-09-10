// PRODUCTION_TYPES
let kServerTranscriptionEnabled = "harness.server.enabled"
@MainActor func ICAITranscriptionFeaturesAvailable() -> Bool { true }
enum ICTranscriptionStatus: Int { case none, queued, downloadingModel, analyzingMusic, transcribing, generatingChapters, completed, failed, canceled }
class ICTranscriptionQueueItem: NSObject {
 let episodeHash: String; let episodeTitle: String; let feedTitle: String
 var status = ICTranscriptionStatus.queued; var progress: Float = 0
 var requiresExplicitRetryAfterCrash = false
 var error: String?; var statusDetail: String?; var statusStartedAt: Date?; var completedAt: Date?; var nextRetryAt: Date?
 var usesServerTranscription = true; var automaticallyScheduled = false; var shouldGenerateAnalysis = true
 init(episodeHash: String, episodeTitle: String, feedTitle: String, audioURL: URL?, language: String?) {
  self.episodeHash=episodeHash; self.episodeTitle=episodeTitle; self.feedTitle=feedTitle
 }
}
@MainActor class TranscriptionQueue {
 static let shared = TranscriptionQueue()
 func scheduleAutomaticBackgroundProcessingIfNeeded() { }
 func admitQueueItem(episodeHash: String, automatic: Bool) -> Bool { true }
}
@MainActor class TranscriptionLogger {
 static let shared = TranscriptionLogger()
 func append(episodeHash: String, phase: String, message: String, detailText: String? = nil) { }
}
struct ICTranscriptCue: Sendable { let start:Double;let end:Double;let text:String }
struct ICGeneratedChapter: Sendable { let start: Double; let end: Double; let title: String; let isSponsor: Bool }
struct ICSponsorSegment: Sendable { let start: Double; let end: Double; let title: String; let evidenceCueIDs: [String] }
typealias EpisodeAnalysisResult = String
@MainActor class CDEpisode { let isDeleted = false }
@MainActor class CacheManager {
 static let instance=CacheManager()
 var cached=true
 static func shared()->CacheManager? {instance}
 func episodeIsCached(_ episode:CDEpisode)->Bool {cached}
 func url(forCachedEpisode episode:CDEpisode)->URL? {URL(fileURLWithPath:"/harness-audio")}
}
@MainActor enum ICAudioIdentity {
 static var afterHash: (() -> Void)?
 static func sha256(of url:URL) async throws -> String {
  afterHash?(); afterHash=nil
  return String(repeating:"a",count:64)
 }
}
@MainActor class TranscriptionEngine {
 nonisolated static func artifactSnapshotIdentifier(at url:URL?)->String? {"harness-audio-snapshot"}
 static let shared = TranscriptionEngine(); var writes = 0
 nonisolated func validateServerSRTData(_ data: Data, for hash: String) throws -> [ICTranscriptCue] { [] }
 func saveValidatedServerSRTData(_ data: Data, cues: [ICTranscriptCue], for hash: String, sourceAudioSHA256: String? = nil) throws { writes += 1 }
}
@MainActor class ChapterGenerator {
 static let shared = ChapterGenerator(); var writes = 0
 nonisolated func makeServerAnalysis(_ base: [ICGeneratedChapter], sponsorSegments: [ICSponsorSegment], summary: String, transcriptCues: [ICTranscriptCue]) throws -> String { "analysis" }
 func saveAnalysisResult(_ result: String, for hash: String) throws { writes += 1 }
}
@MainActor final class FakeServer {
 var online = true; var loseAck = false; var holdAck = false
 var rejectionCode: String?; var pollErrorCode: String?; var malformedAck = false; var getEvents: [String] = []
 var postGate: CheckedContinuation<Void, Never>?
 var registrations: [String:Int] = [:]; var byURL: [String:Int] = [:]; var tombstones = Set<String>(); var nextID = 100
 var events: [String] = []; var status = "queued"; var terminalCode: String?
 var warnings: [[String:Any]] = []
 var artifacts: [[String:Any]] = []
 func error(_ code: String, http: Int, retryable: Bool) -> NSError {
  NSError(domain:"ICServerTranscription", code:http, userInfo:["serverErrorCode":code,"serverRetryable":retryable,"retryAfter":1])
 }
 func perform(path: String, method: String, body: [String:Any]?, disk: URL) async throws -> Data {
  if !online { throw NSError(domain:NSURLErrorDomain,code:NSURLErrorNotConnectedToInternet,userInfo:["retryAfter":1]) }
  if method == "GET", let pollErrorCode { throw NSError(domain:"ICServerTranscription",code:503,userInfo:["serverErrorCode":pollErrorCode,"serverRetryable":true,"retryAfter":300]) }
  if method == "DELETE" {
   let id = path.hasPrefix("client-requests/") ? String(path.dropFirst("client-requests/".count)) : nil
   let episodeID = id.flatMap { registrations[$0] } ?? Int(path.split(separator:"/")[1])
   events.append("DELETE:" + (id ?? "legacy")); if let id { tombstones.insert(id) }
   return try JSONSerialization.data(withJSONObject:["api_version":"v1","client_request":["id":id as Any? ?? NSNull(),"state":"canceled","episode_id":episodeID as Any? ?? NSNull()]])
  }
  var requestID: String?; var episodeID: Int?
  if method == "POST" {
   requestID=body!["client_request_id"] as? String
   let id=requestID!; events.append("POST:"+id)
   if let rejectionCode { throw NSError(domain:"ICServerTranscription",code:503,userInfo:["serverErrorCode":rejectionCode,"serverRetryable":true,"serverAdmitted":false,"retryAfter":300]) }
   let saved=try Data(contentsOf:disk)
   precondition(String(data:saved,encoding:.utf8)!.contains(id), "POST before UUID persistence")
   let audio=String(repeating:"a",count:64)
   precondition(body?["client_audio_sha256"] as? String == audio, "POST without actual device audio hash")
   precondition(String(data:saved,encoding:.utf8)!.contains(audio), "POST before audio hash persistence")
   if tombstones.contains(id) { throw error("request_canceled",http:410,retryable:false) }
   let url=body!["episode_url"] as! String
   if let known=registrations[id] { episodeID=known }
   else if let known=byURL[url], body!["force"] as? Bool != true { episodeID=known; registrations[id]=known }
   else { episodeID=nextID; nextID += 1; registrations[id]=episodeID!; byURL[url]=episodeID! }
   if holdAck { await withCheckedContinuation { postGate=$0 } }
   if malformedAck { malformedAck=false; return Data("{broken".utf8) }
   if loseAck { loseAck=false; throw NSError(domain:NSURLErrorDomain,code:NSURLErrorNetworkConnectionLost,userInfo:["retryAfter":1]) }
  } else if path.hasPrefix("client-requests/") {
   requestID=String(path.dropFirst("client-requests/".count));getEvents.append(requestID!)
   if let terminalCode { throw error(terminalCode,http:410,retryable:false) }
   if tombstones.contains(requestID!) { throw error("request_canceled",http:410,retryable:false) }
   guard let known=registrations[requestID!] else { throw error("request_not_found",http:404,retryable:false) }
   episodeID=known
  } else { episodeID=Int(path.split(separator:"/")[1]) }
  let episode: [String:Any] = ["id":episodeID!,"status":status,"phase":status == "running" ? "transcribing" : status,"progress":0,"warnings":warnings,"artifacts":artifacts,"media":["audio_sha256":String(repeating:"a",count:64)]]
  var envelope:[String:Any] = ["api_version":"v1","retry_after_seconds":300,"episode":episode]
  if let requestID { envelope["client_request"]=["id":requestID,"state":"active","episode_id":episodeID!] }
  return try JSONSerialization.data(withJSONObject:envelope)
 }
}
final class SnapshotWriter: @unchecked Sendable {
 static let shared = SnapshotWriter()
 private let lock = NSLock()
 private var failureURL: URL?; private var writeCount = 0; private var persistentFailure = false
 func failMarkerWrite(at url: URL, persistently: Bool = false) { lock.lock();defer {lock.unlock()};failureURL=url;writeCount=0;persistentFailure=persistently }
 func allowWrites() { lock.lock();defer {lock.unlock()};failureURL=nil }
 func write(_ data: Data, to url: URL) throws {
  lock.lock();defer {lock.unlock()}
  if url == failureURL { writeCount += 1;if writeCount == 2 || (persistentFailure && writeCount > 2) { throw NSError(domain:NSCocoaErrorDomain,code:NSFileWriteOutOfSpaceError) } }
  try data.write(to:url,options:.atomic)
 }
}
@MainActor final class Harness: NSObject {
 static let retryDelay: TimeInterval = 30
 static let maximumRetryInterval = 86400
 static let clientIdentifierKey = "HarnessClientIdentifier"
 static let completedItemRetentionInterval: TimeInterval = 1800
 let server: FakeServer; let queueFileURL: URL
 var items:[ICTranscriptionQueueItem]=[]
 var endpointByItem:[ObjectIdentifier:URL]=[:]
 var metadataByItem:[ObjectIdentifier:(podcastURL:URL?,duration:Double)]=[:]
 var serverIDByItem:[ObjectIdentifier:Int]=[:]
 var clientRequestIDByItem:[ObjectIdentifier:String]=[:]
 var explicitRestartByItem:[ObjectIdentifier:Bool]=[:]
 var sourceAudioSHA256ByItem:[ObjectIdentifier:String]=[:]
 var retryImportOnlyByItem:[ObjectIdentifier:Bool]=[:]
 private var cancellations:[ICServerCancellation]=[]
 var currentTask:Task<Void,Never>?; var currentItem:ICTranscriptionQueueItem?; var cancellationTask:Task<Void,Never>?; var retryWakeTask:Task<Void,Never>?
 private var admissionByItem:[ObjectIdentifier:ICServerAdmissionState]=[:]
 var admissionCompletions:[ObjectIdentifier:(Bool,String)->Void]=[:]
 var queueLoadError:NSError?
 var ownerClientID:String?=UUID().uuidString
 var queueStorageError:NSError? { queueLoadError ?? queuePersistenceError }
 var networkUnavailable=false
 var needsIdentityPersistence=false
 let persistenceQueue=DispatchQueue(label:"harness.persistence",qos:.utility)
 var pendingPersistenceCount=0; var persistenceCompletions:[(NSError?)->Void]=[]; var queuePersistenceError:NSError?; var publishedQueueState:NSDictionary?; var publishedProcessingState:Bool?
 var isProcessing:Bool { currentItem != nil || cancellationTask != nil || pendingPersistenceCount > 0 }
 var downloadGates:[CheckedContinuation<Data,Error>]=[]
 init(server:FakeServer, file:URL) { self.server=server;queueFileURL=file;super.init() }
 private func request<T:Decodable>(path:String,method:String,body:[String:Any]?) async throws -> T {
  let data=try await server.perform(path:path,method:method,body:body,disk:queueFileURL)
  return try JSONDecoder().decode(T.self,from:data)
 }
 private func download(_ artifact:ICServerArtifact) async throws -> Data { try await withCheckedThrowingContinuation { downloadGates.append($0) } }
 private func findEpisode(hash:String)->CDEpisode? { CDEpisode() }
 private func publisherChapters(for episode:CDEpisode,fallback:[ICServerChaptersArtifact.Chapter])->[ICGeneratedChapter] { [] }
 nonisolated private func validateServerArtifacts(_ chapters:ICServerChaptersArtifact,ads:ICServerAdsArtifact,summary:ICServerSummaryArtifact,transcriptRevision:String,serverDuration:Double?) throws { }

// PRODUCTION_METHODS
 func add(hash:String="episode", accepted:Bool=false)->ICTranscriptionQueueItem {
  let item=makeItem(episodeHash:hash,episodeTitle:hash,feedTitle:"feed",episodeURL:URL(string:"https://example.com/\(hash).mp3")!,podcastURL:nil,duration:60,automaticallyScheduled:false)
  items.append(item)
  if accepted { admissionByItem[ObjectIdentifier(item)] = .accepted;let id=clientRequestIDByItem[ObjectIdentifier(item)]!; serverIDByItem[ObjectIdentifier(item)]=42;server.registrations[id]=42;server.byURL[endpointByItem[ObjectIdentifier(item)]!.absoluteString]=42 }
  return item
 }
 func until(_ predicate:()->Bool) async {
  for _ in 0..<5000 { if predicate(){return}; try? await Task.sleep(nanoseconds:1_000_000) }
  preconditionFailure("Timed out")
 }
 func durable() async { await until { !isProcessing } }
 func start() { persistQueue() }
 func setDue(_ item:ICTranscriptionQueueItem) { retryWakeTask?.cancel(); item.nextRetryAt=nil; processNext() }
 func releaseDownloads() { let gates=downloadGates;downloadGates=[];for gate in gates {gate.resume(returning:Data())} }
 static func run(in dir:URL) async throws {
  UserDefaults.standard.set(true,forKey:kServerTranscriptionEnabled)
  // No POST with missing audio, a changed durable source, or replacement during hashing.
  CacheManager.instance.cached=false
  let absentServer=FakeServer();let absent=Harness(server:absentServer,file:dir.appendingPathComponent("absent.json"));let absentItem=absent.add()
  absent.start();await absent.until {absentItem.status == .failed && !absent.isProcessing}
  precondition(absentServer.events.isEmpty)
  CacheManager.instance.cached=true
  let changedServer=FakeServer();let changed=Harness(server:changedServer,file:dir.appendingPathComponent("changed.json"));let changedItem=changed.add()
  changed.sourceAudioSHA256ByItem[ObjectIdentifier(changedItem)]=String(repeating:"b",count:64)
  changed.start();await changed.until {changedItem.status == .failed && !changed.isProcessing}
  precondition(changedServer.events.isEmpty)
  let replacingServer=FakeServer();let replacing=Harness(server:replacingServer,file:dir.appendingPathComponent("replacing.json"));let replacingItem=replacing.add()
  ICAudioIdentity.afterHash={CacheManager.instance.cached=false}
  replacing.start();await replacing.until {replacingItem.status == .failed && !replacing.isProcessing}
  precondition(replacingServer.events.isEmpty)
  CacheManager.instance.cached=true
  // Lost POST acknowledgement: same durable UUID, one server job, successful replay.
  let lostServer=FakeServer();lostServer.loseAck=true
  let lost=Harness(server:lostServer,file:dir.appendingPathComponent("lost.json"));let first=lost.add();let original=lost.clientRequestIDByItem[ObjectIdentifier(first)]!
  lost.start();await lost.until { lostServer.events.count==1 && !lost.isProcessing }
  precondition(lost.serverIDByItem[ObjectIdentifier(first)]==nil)
  lost.setDue(first);await lost.until { lostServer.getEvents.count==1 && !lost.isProcessing }
  precondition(lostServer.nextID==101 && lostServer.events==["POST:"+original] && lostServer.getEvents==[original])
  lost.retryWakeTask?.cancel()
  // A missing request registration replays the same UUID and keeps its accepted episode.
  let missingServer=FakeServer();let missing=Harness(server:missingServer,file:dir.appendingPathComponent("missing.json"));let missingItem=missing.add(accepted:true)
  let missingID=missing.clientRequestIDByItem[ObjectIdentifier(missingItem)]!;missingServer.registrations.removeValue(forKey:missingID)
  missing.start();await missing.until { missingServer.events.count==1 && !missing.isProcessing }
  precondition(missingServer.events==["POST:"+missingID] && missing.serverIDByItem[ObjectIdentifier(missingItem)]==42 && missingServer.nextID==100)
  missing.retryWakeTask?.cancel()
  // A pre-UUID accepted job stays on legacy GET/DELETE; migration must never resubmit it.
  let legacyServer=FakeServer();let legacy=Harness(server:legacyServer,file:dir.appendingPathComponent("legacy.json"));let legacyItem=legacy.add(accepted:true)
  legacy.clientRequestIDByItem.removeValue(forKey:ObjectIdentifier(legacyItem));legacy.start();await legacy.durable()
  precondition(legacyServer.events.isEmpty && legacy.serverIDByItem[ObjectIdentifier(legacyItem)]==42)
  legacy.dequeueEpisodeHash(legacyItem.episodeHash);await legacy.until { legacyServer.events==["DELETE:legacy"] && !legacy.isProcessing }
  precondition(legacy.cancellations.isEmpty && legacy.items.isEmpty)
  legacy.retryWakeTask?.cancel()
  // Cancel with POST in flight: tombstone even though the client has no numeric ID.
  let raceServer=FakeServer();raceServer.holdAck=true
  let race=Harness(server:raceServer,file:dir.appendingPathComponent("race.json"));let racing=race.add();let raceID=race.clientRequestIDByItem[ObjectIdentifier(racing)]!
  race.start();await race.until { raceServer.postGate != nil }
  race.dequeueEpisodeHash(racing.episodeHash)
  raceServer.postGate!.resume();raceServer.postGate=nil
  await race.until { raceServer.tombstones.contains(raceID) && !race.isProcessing }
  precondition(race.items.isEmpty && race.serverIDByItem[ObjectIdentifier(racing)]==nil && race.cancellations.isEmpty)
  // Offline cancellation survives the queue disappearing and a new manager loading disk.
  let offlineServer=FakeServer();offlineServer.online=false
  let offline=Harness(server:offlineServer,file:dir.appendingPathComponent("offline.json"));let offlineItem=offline.add(accepted:true);let offlineID=offline.clientRequestIDByItem[ObjectIdentifier(offlineItem)]!
  offline.dequeueEpisodeHash(offlineItem.episodeHash);await offline.durable();offline.retryWakeTask?.cancel()
  precondition(offline.cancellations.count==1 && offline.items.isEmpty)
  try await Task.sleep(nanoseconds:1_050_000_000);offlineServer.online=true
  let relaunched=Harness(server:offlineServer,file:offline.queueFileURL);relaunched.loadPersistedQueue();precondition(relaunched.cancellations.count==1)
  relaunched.resumeIfNeeded();await relaunched.until { offlineServer.tombstones.contains(offlineID) && !relaunched.isProcessing }
  precondition(relaunched.cancellations.isEmpty)
  // Remote cancellation wins over regressed progress; deleted requests are terminal too.
  for status in ["canceled","deleted"] {
   let backend=FakeServer();if status=="canceled" { backend.status="canceled" } else { backend.terminalCode="request_deleted" }
   let manager=Harness(server:backend,file:dir.appendingPathComponent(status+".json"));let item=manager.add(accepted:true);item.progress=0.8;manager.start()
   await manager.until { item.status == .canceled && !manager.isProcessing }
   precondition(item.error==nil && item.nextRetryAt==nil)
  }
  // Explicit retry fences the old attempt and confirms its cancellation before new POST.
  let restartServer=FakeServer();let restart=Harness(server:restartServer,file:dir.appendingPathComponent("restart.json"));let restarting=restart.add(accepted:true)
  let oldID=restart.clientRequestIDByItem[ObjectIdentifier(restarting)]!;restart.retryEpisodeHash(restarting.episodeHash)
  await restart.until { restartServer.events.count>=2 && !restart.isProcessing }
  precondition(restartServer.events[0]=="DELETE:"+oldID && restartServer.events[1].hasPrefix("POST:") && restartServer.events[1] != "POST:"+oldID)
  restart.retryWakeTask?.cancel()
  // Last async artifact response arrives after removal: actual import function must not write.
  let importServer=FakeServer();importServer.status="ready"
  let kinds=["transcript_srt","chapters_json","ads_json","summary_json"]
  let hash=String(repeating:"0",count:64)
  importServer.artifacts=kinds.enumerated().map { i,kind in ["id":i,"kind":kind,"url":"https://example.com/\(i)","content_type":"application/json","byte_size":0,"sha256":hash,"transcript_revision":"sha256:"+hash,"etag":"tag"] }
  // A missing local download must never start paid server processing again on retry/relaunch.
  CacheManager.instance.cached=false
  let waiting=Harness(server:importServer,file:dir.appendingPathComponent("waiting-import.json"));let waitingItem=waiting.add(accepted:true)
  let waitingID=waiting.clientRequestIDByItem[ObjectIdentifier(waitingItem)]!
  waiting.start();await waiting.until {waitingItem.status == .failed && !waiting.isProcessing}
  let waitingReloaded=Harness(server:importServer,file:waiting.queueFileURL);waitingReloaded.loadPersistedQueue()
  let restoredItem=waitingReloaded.items[0];waitingReloaded.retryEpisodeHash(restoredItem.episodeHash)
  await waitingReloaded.until {restoredItem.status == .failed && !waitingReloaded.isProcessing}
  precondition(waitingReloaded.clientRequestIDByItem[ObjectIdentifier(restoredItem)]==waitingID && importServer.events.isEmpty,
               "Retrying an import after relaunch canceled and regenerated an already completed server result")
  CacheManager.instance.cached=true
  importServer.warnings=[["code":"audio_duration_mismatch","message":"Another client supplied a different feed duration","timing_may_be_shifted":true]]
  let importing=Harness(server:importServer,file:dir.appendingPathComponent("import.json"));let importItem=importing.add(accepted:true);importing.start()
  await importing.until { importing.downloadGates.count==4 || importItem.status == .failed }
  precondition(importing.downloadGates.count==4, "A shared duration hint overrode verified exact audio identity")
  importing.dequeueEpisodeHash(importItem.episodeHash);importing.releaseDownloads();await importing.durable()
  precondition(TranscriptionEngine.shared.writes==0 && ChapterGenerator.shared.writes==0 && importing.items.isEmpty)
  print("PASS: lost POST ack, same-UUID GET404 replay, legacy GET/DELETE, cancel/POST race, offline cancellation relaunch, remote cancel/delete, explicit retry fencing, late artifact import")
 }
}
@main struct Entry {
 @MainActor static func main() async throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:dir)}
  try await Harness.run(in:dir)
 }
}
