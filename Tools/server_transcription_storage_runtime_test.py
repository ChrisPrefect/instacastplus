from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
runner=root/'Tools/server_transcription_admission_runtime_test.py'
ns={'__file__':str(runner)}
exec(runner.read_text().split('fixture = ',1)[0],ns)
source=ns['source'];declaration=ns['declaration'];signatures=ns['signatures']+['@objc func pruneExpiredCompletedItems(']
fixture=(root/'Tools/fixtures/server_transcription_cancellation_harness.swift').read_text()
start=fixture.index(' static func run(in dir:URL)');end=fixture.index('\n}\n@main',start)
cases=r'''
 static func run(in dir:URL) async throws {
  UserDefaults.standard.set(true,forKey:kServerTranscriptionEnabled)
  UserDefaults.standard.removeObject(forKey:Self.clientIdentifierKey)
  let server=FakeServer();server.online=false
  let file=dir.appendingPathComponent("corrupt.json")
  let original=Harness(server:server,file:file)
  _=original.add(hash:"retained",accepted:true)
  let removed=original.add(hash:"cancelled",accepted:true)
  original.dequeueEpisodeHash(removed.episodeHash);await original.durable();original.retryWakeTask?.cancel()
  let valid=try Data(contentsOf:file)
  let originalOwner=try original.clientIdentifier()
  var snapshot=try JSONSerialization.jsonObject(with:valid) as! [String:Any]
  var entries=snapshot["items"] as! [[String:Any]]
  entries[0]["admissionState"]="corrupt-admission-value";snapshot["items"]=entries
  let corrupted=try JSONSerialization.data(withJSONObject:snapshot)
  try corrupted.write(to:file,options:.atomic)
  let restored=Harness(server:server,file:file);restored.loadPersistedQueue()
  precondition(restored.queueLoadError != nil && restored.items.isEmpty)
  restored.start();await restored.durable()
  precondition(try! Data(contentsOf:file)==corrupted,"Unreadable snapshot was overwritten")
  restored.cancelAll();restored.retryPendingCancellations();await restored.durable()
  precondition(try! Data(contentsOf:file)==corrupted,"Unknown cancellation outbox was replaced")
  // Repair and retry recover the original complete set, not an empty replacement.
  try valid.write(to:file,options:.atomic)
  restored.retryQueueStorage();await restored.durable();restored.retryWakeTask?.cancel()
  precondition(restored.queueLoadError == nil && restored.items.count==1 && restored.cancellations.count==1)
  precondition(try! restored.clientIdentifier()==originalOwner)
  // A changed/lost defaults value cannot change an already-persisted owner.
  UserDefaults.standard.set(UUID().uuidString,forKey:Self.clientIdentifierKey)
  let resetDefaults=Harness(server:server,file:file);resetDefaults.loadPersistedQueue()
  precondition(try! resetDefaults.clientIdentifier()==originalOwner)
  // Existing install migrates only when its previous owner can be established.
  var legacy=try JSONSerialization.jsonObject(with:valid) as! [String:Any];legacy.removeValue(forKey:"ownerClientID")
  let legacyData=try JSONSerialization.data(withJSONObject:legacy);let legacyFile=dir.appendingPathComponent("legacy-owner.json")
  try legacyData.write(to:legacyFile)
  UserDefaults.standard.removeObject(forKey:Self.clientIdentifierKey)
  let ownerMissing=Harness(server:server,file:legacyFile);ownerMissing.loadPersistedQueue();ownerMissing.start()
  precondition(ownerMissing.queueLoadError != nil && (try! Data(contentsOf:legacyFile))==legacyData)
  UserDefaults.standard.set(originalOwner,forKey:Self.clientIdentifierKey)
  ownerMissing.retryQueueStorage();await ownerMissing.durable();ownerMissing.retryWakeTask?.cancel()
  let migrated=try JSONDecoder().decode(ICPersistedServerTranscriptionQueue.self,from:Data(contentsOf:legacyFile))
  precondition(migrated.ownerClientID==originalOwner && migrated.cancellations?.count==1)
  // A path that exists but cannot be read as a file is not a first-install empty queue.
  let unreadable=dir.appendingPathComponent("unreadable");try FileManager.default.createDirectory(at:unreadable,withIntermediateDirectories:false)
  let inaccessible=Harness(server:server,file:unreadable);inaccessible.loadPersistedQueue();inaccessible.start()
  precondition(inaccessible.queueLoadError != nil)
  // First install persists owner before network work.
  let fresh=Harness(server:server,file:dir.appendingPathComponent("first-install.json"));fresh.loadPersistedQueue();fresh.resumeIfNeeded();await fresh.durable()
  let first=try JSONDecoder().decode(ICPersistedServerTranscriptionQueue.self,from:Data(contentsOf:fresh.queueFileURL))
  precondition(first.ownerClientID != nil && fresh.queueLoadError == nil)
  // Identity cleanup is deterministic, independent of allocator reuse.
  let prune=Harness(server:server,file:dir.appendingPathComponent("prune.json"));let item=prune.add(accepted:true)
  let stale=ObjectIdentifier(item);item.status = .completed;item.completedAt=Date().addingTimeInterval(-3600)
  prune.pruneExpiredCompletedItems()
  precondition(prune.items.isEmpty && prune.serverIDByItem[stale] == nil && prune.endpointByItem[stale] == nil && prune.clientRequestIDByItem[stale] == nil && prune.admissionByItem[stale] == nil,"Retired object leaves request identity behind")
  print("PASS: corrupt/unreadable snapshot no-clobber, complete recovery, owner migration/defaults loss/unknown-owner block, first-install owner durability, metadata retirement")
 }
'''
fixture=fixture[:start]+cases+fixture[end:]
fixture=fixture.replace('// PRODUCTION_TYPES',source.split('@MainActor\n@objc class ServerTranscriptionManager',1)[0])
fixture=fixture.replace('// PRODUCTION_METHODS','\n'.join(('@discardableResult\n' if sig == 'private func schedulePoll(' else '') + declaration(sig) for sig in signatures))
with tempfile.TemporaryDirectory(prefix='instacast-s2-') as d:
 p=Path(d);(p/'main.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True,timeout=30)
