 static func run(in dir:URL) async throws {
  UserDefaults.standard.set(true,forKey:kServerTranscriptionEnabled)
  var failures:[String]=[]
  func expect(_ passed:Bool,_ message:String) { if !passed { failures.append(message) } }
  func observe(_ condition:()->Bool) async -> Bool {
   for _ in 0..<2000 {if condition(){return true};try? await Task.sleep(nanoseconds:1_000_000)}
   return condition()
  }
  func artifacts(_ manager:Harness,_ peer:FakeServer) throws {
   let hash=String(repeating:"0",count:64),revision="sha256:"+String(repeating:"0",count:64)
   peer.artifacts=["transcript_srt","chapters_json","ads_json","summary_json"].enumerated().map { i,kind in
    ["id":i,"kind":kind,"url":"https://example.com/\(i)","content_type":"application/json","byte_size":1,"sha256":hash,"transcript_revision":revision,"etag":"tag"]
   }
   manager.artifactBytesByKind=[
    "transcript_srt":Data("1\n00:00:00,000 --> 00:00:01,000\nText\n".utf8),
    "chapters_json":try JSONSerialization.data(withJSONObject:["schema_version":1,"transcript_revision":revision,"audio_duration_seconds":60,"chapters":[]]),
    "ads_json":try JSONSerialization.data(withJSONObject:["schema_version":1,"transcript_revision":revision,"audio_duration_seconds":60,"segments":[]]),
    "summary_json":try JSONSerialization.data(withJSONObject:["schema_version":1,"transcript_revision":revision,"audio_duration_seconds":60,"summary":"Summary","topic_titles":[]])]
  }

  // A healthy pending intent is not an admission refusal after restart.
  let pendingPeer=FakeServer();pendingPeer.holdAck=true
  let pending=Harness(server:pendingPeer,file:dir.appendingPathComponent("pending.json"))
  let first=pending.add(hash:"first");first.serverAudioSource = .server
  pending.start();await pending.until {pendingPeer.postGate != nil}
  let second=pending.add(hash:"second");second.serverAudioSource = .server
  let secondID=pending.clientRequestIDByItem[ObjectIdentifier(second)]!
  pending.persistQueue();await pending.until {pending.pendingPersistenceCount==0}
  precondition(pending.queuePersistenceError==nil)
  let restoredFile=dir.appendingPathComponent("restored.json")
  try Data(contentsOf:pending.queueFileURL).write(to:restoredFile)
  let restored=Harness(server:pendingPeer,file:restoredFile);restored.loadPersistedQueue()
  let restoredSecond=restored.items.first {$0.episodeHash=="second"}!
  expect(restoredSecond.status == .queued && restored.admissionByItem[ObjectIdentifier(restoredSecond)] == .pending,"Healthy durable pending request was rejected during restore")
  expect(restored.clientRequestIDByItem[ObjectIdentifier(restoredSecond)]==secondID && restoredSecond.serverAudioSource == .server,"Restore changed immutable request identity")
  // Finish the original held fixture, then let the independent restored manager run.
  UserDefaults.standard.set(false,forKey:kServerTranscriptionEnabled)
  pending.currentTask?.cancel();pendingPeer.holdAck=false;pendingPeer.postGate?.resume();pendingPeer.postGate=nil
  await pending.durable();pending.retryWakeTask?.cancel()
  UserDefaults.standard.set(true,forKey:kServerTranscriptionEnabled)
  restored.resumeIfNeeded();await restored.durable();restored.retryWakeTask?.cancel()
  expect(pendingPeer.postBodies.contains {$0["client_request_id"] as? String==secondID},"Restored healthy saved intent did not submit automatically")

  // Text import follows the immutable accepted source, not today's cache contents.
  let cached=Harness(server:FakeServer(),file:dir.appendingPathComponent("source.json"))
  let cachedItem=cached.add(accepted:true);let expectedHash=String(repeating:"a",count:64)
  CacheManager.instance.cached=false
  do {_ = try await cached.verifiedImportAudio(for:cachedItem,sourceAudioSHA256:expectedHash)}
  catch {failures.append("Matching accepted source required device cache: \((error as NSError).code)")}
  do {_ = try await cached.verifiedImportAudio(for:cachedItem,sourceAudioSHA256:String(repeating:"b",count:64));failures.append("Different result source passed immutable identity check")}
  catch {expect((error as NSError).code==56,"Source mismatch must be distinguished from missing cache")}
  cached.sourceAudioSHA256ByItem.removeValue(forKey:ObjectIdentifier(cachedItem))
  do {_ = try await cached.verifiedImportAudio(for:cachedItem,sourceAudioSHA256:expectedHash);failures.append("Legacy missing source proof was silently accepted")}
  catch {expect((error as NSError).code==54,"Missing immutable identity must fail explicitly")}
  CacheManager.instance.cached=true

  // A held import does not own the request-control path.
  let peer=FakeServer();peer.status="ready"
  let manager=Harness(server:peer,file:dir.appendingPathComponent("independent.json"))
  try artifacts(manager,peer)
  let importing=manager.add(hash:"importing",accepted:true)
  let canceled=manager.add(hash:"cancel-other",accepted:true);canceled.nextRetryAt=Date().addingTimeInterval(300)
  let canceledID=manager.clientRequestIDByItem[ObjectIdentifier(canceled)]!
  manager.start();await manager.until {manager.downloadGates.count==4}
  let fresh=manager.add(hash:"new-while-importing");fresh.serverAudioSource = .server
  let freshID=manager.clientRequestIDByItem[ObjectIdentifier(fresh)]!
  manager.persistQueue();manager.dequeueEpisodeHash(canceled.episodeHash)
  expect(await observe {peer.events.contains("DELETE:"+canceledID)},"An unrelated import blocked DELETE")
  expect(await observe {peer.postBodies.contains {$0["client_request_id"] as? String==freshID}},"An unrelated import blocked new POST")
  expect(manager.downloadGates.count==4,"More than one result buffered concurrently")
  if peer.postBodies.contains(where: {$0["client_request_id"] as? String==freshID}) {
   expect(fresh.serverPhase=="awaiting_import","A ready waiting result needs an honest awaiting_import state")
  }
  // A previously failed import becomes due while another occupies the slot.
  // It must wait for slot completion, not schedule an immediate retry spin.
  fresh.nextRetryAt=Date().addingTimeInterval(-1)
  manager.retryWakeTask?.cancel();manager.retryWakeTask=nil
  manager.scheduleRetryWake()
  expect(manager.retryWakeTask==nil,"A due import without a free slot scheduled an immediate retry loop")
  manager.retryWakeTask?.cancel();fresh.nextRetryAt=nil
  let writesBefore=TranscriptionEngine.shared.writes
  manager.dequeueEpisodeHash(importing.episodeHash);manager.releaseDownloads()
  expect(await observe {manager.downloadGates.count==4},"Remaining ready request did not get the released import slot")
  expect(TranscriptionEngine.shared.writes==writesBefore,"Canceled import committed a late artifact")
  manager.releaseDownloads();await manager.durable();manager.retryWakeTask?.cancel()
  expect(fresh.status == .completed && manager.items.contains {$0 === fresh},"Canceling import lost another pending result")
  expect(TranscriptionEngine.shared.writes==writesBefore+1,"Only the surviving import must commit")

  // Even another in-flight POST must not delay cancellation.
  let heldPeer=FakeServer();heldPeer.holdAck=true
  let held=Harness(server:heldPeer,file:dir.appendingPathComponent("held-post.json"))
  let heldItem=held.add(hash:"held-post");heldItem.serverAudioSource = .server
  held.start();await held.until {heldPeer.postGate != nil}
  let remove=held.add(hash:"cancel-during-post",accepted:true)
  let removeID=held.clientRequestIDByItem[ObjectIdentifier(remove)]!
  held.dequeueEpisodeHash(remove.episodeHash)
  expect(await observe {heldPeer.events.contains("DELETE:"+removeID)},"An unrelated held POST blocked DELETE")
  held.dequeueEpisodeHash(heldItem.episodeHash);heldPeer.holdAck=false;heldPeer.postGate?.resume();heldPeer.postGate=nil
  await held.durable();held.retryWakeTask?.cancel()
  // The DELETE acknowledgement blocks replacement of its own episode only.
  let deletePeer=FakeServer();deletePeer.holdDeleteAck=true
  let deleting=Harness(server:deletePeer,file:dir.appendingPathComponent("held-delete.json"))
  let old=deleting.add(hash:"same-episode",accepted:true)
  deleting.dequeueEpisodeHash(old.episodeHash);await deleting.until {deletePeer.deleteGate != nil}
  let independent=deleting.add(hash:"independent");independent.serverAudioSource = .server
  let same=deleting.add(hash:"same-episode");same.serverAudioSource = .server
  let independentID=deleting.clientRequestIDByItem[ObjectIdentifier(independent)]!
  let sameID=deleting.clientRequestIDByItem[ObjectIdentifier(same)]!
  deleting.persistQueue()
  expect(await observe {deletePeer.postBodies.contains {$0["client_request_id"] as? String==independentID}},"A held DELETE blocked an unrelated new POST")
  expect(!deletePeer.postBodies.contains {$0["client_request_id"] as? String==sameID},"Same-episode replacement posted before cancellation confirmation")
  deletePeer.holdDeleteAck=false;deletePeer.deleteGate?.resume();deletePeer.deleteGate=nil
  await deleting.durable();deleting.retryWakeTask?.cancel()
  expect(deletePeer.postBodies.contains {$0["client_request_id"] as? String==sameID},"Confirmed cancellation did not release its episode for the new request")

  // A deliberate new transcription must not remain bound to a completed result.
  for completed in [true,false] {
   let restart=Harness(server:FakeServer(),file:dir.appendingPathComponent("explicit-new-\(completed).json"))
   let item=restart.add(hash:"explicit-new",accepted:true)
   item.restoreStatus(completed ? .completed : .failed)
   item.serverPhase = completed ? "importing" : "failed"
   if completed {restart.retryImportOnlyByItem[ObjectIdentifier(item)]=true}
   else {restart.serverIDByItem.removeValue(forKey:ObjectIdentifier(item))}
   let previousID=restart.clientRequestIDByItem[ObjectIdentifier(item)]!
   restart.networkUnavailable=true;restart.retryEpisodeHash(item.episodeHash);await restart.durable();restart.retryWakeTask?.cancel()
   expect(restart.explicitRestartByItem[ObjectIdentifier(item)]==true,"Explicit new transcription did not request a fresh source (completed=\(completed))")
   expect(restart.clientRequestIDByItem[ObjectIdentifier(item)] != previousID,"Explicit new transcription reused a terminal UUID")
   expect(restart.retryImportOnlyByItem[ObjectIdentifier(item)] != true,"New transcription inherited the old result's import-only flag")
  }
  if !failures.isEmpty {print(failures.joined(separator:"\n"));exit(1)}
  print("PASS: durable pending restart, cache-independent immutable source import, bounded independent import/control, late-cancel fencing and held-POST cancellation")
 }
