 static func run(in dir:URL) async throws {
  UserDefaults.standard.set(true,forKey:kServerTranscriptionEnabled)
  var results:[[String:Any]]=[]

  // Probe 1: one real request is held at the HTTP acknowledgement boundary.
  // A second URL-only request has a healthy production atomic snapshot.
  let peer=FakeServer();peer.holdAck=true
  let original=Harness(server:peer,file:dir.appendingPathComponent("pending-original.json"))
  let blocker=original.add(hash:"held-first");blocker.serverAudioSource = .server
  original.start();await original.until {peer.postGate != nil}
  let waiting=original.add(hash:"waiting-second");waiting.serverAudioSource = .server
  let waitingID=original.clientRequestIDByItem[ObjectIdentifier(waiting)]!
  original.persistQueue();await original.until {original.pendingPersistenceCount==0}
  precondition(original.queuePersistenceError == nil && original.currentTask != nil)
  let savedData=try Data(contentsOf:original.queueFileURL)
  try savedData.write(to:dir.appendingPathComponent("pending-before-restart.json"),options:.atomic)
  let saved=try JSONDecoder().decode(ICPersistedServerTranscriptionQueue.self,from:savedData)
  let savedWaiting=saved.items.first {$0.episodeHash==waiting.episodeHash}!
  precondition(savedWaiting.admissionState == .pending && savedWaiting.audioSource == .server)
  precondition(savedWaiting.clientRequestID==waitingID && savedWaiting.statusRawValue==ICTranscriptionStatus.queued.rawValue)
  let restoredFile=dir.appendingPathComponent("pending-restored.json")
  try savedData.write(to:restoredFile,options:.atomic)
  let restored=Harness(server:peer,file:restoredFile)
  restored.loadPersistedQueue()
  let restoredWaiting=restored.items.first {$0.episodeHash==waiting.episodeHash}!
  restored.resumeIfNeeded();await restored.durable();restored.retryWakeTask?.cancel()
  let resumedAutomatically=restoredWaiting.status != .failed && restored.admissionByItem[ObjectIdentifier(restoredWaiting)] != .rejected
  results.append([
   "case":"healthy_pending_url_only_restart",
   "expected":"Same durable UUID and server source resume automatically; no rejection of healthy saved intent",
   "expected_behavior_passed":resumedAutomatically,
   "observed":["before_state":"queued/pending","snapshot_write_error":NSNull(),"first_post_still_held":peer.postGate != nil,
               "saved_uuid":waitingID,"restored_uuid":restored.clientRequestIDByItem[ObjectIdentifier(restoredWaiting)] ?? "nil",
               "saved_source":savedWaiting.audioSource?.rawValue ?? "nil","restored_source":restoredWaiting.serverAudioSource.rawValue,
               "after_status":String(describing:restoredWaiting.status),"after_status_is_failed":restoredWaiting.status == .failed,"after_admission":restored.admissionByItem[ObjectIdentifier(restoredWaiting)]?.rawValue ?? "nil",
               "after_error":restoredWaiting.error ?? "nil","waiting_post_count":peer.postBodies.filter {$0["client_request_id"] as? String == waitingID}.count,
               "http_events":peer.events,"get_events":peer.getEvents]
  ])
  // Release the retained fixture continuation only after retaining the observation.
  UserDefaults.standard.set(false,forKey:kServerTranscriptionEnabled)
  original.currentTask?.cancel();peer.holdAck=false;peer.postGate?.resume();peer.postGate=nil
  await original.durable();original.retryWakeTask?.cancel()
  UserDefaults.standard.set(true,forKey:kServerTranscriptionEnabled)

  // Probe 2: actual successful client admission persists the immutable start SHA.
  CacheManager.instance.cached=true
  let resultPeer=FakeServer()
  let importer=Harness(server:resultPeer,file:dir.appendingPathComponent("client-import.json"))
  let item=importer.add(hash:"cached-at-start")
  importer.start();await importer.durable();importer.retryWakeTask?.cancel()
  let requestID=importer.clientRequestIDByItem[ObjectIdentifier(item)]!
  let acceptedData=try Data(contentsOf:importer.queueFileURL)
  try acceptedData.write(to:dir.appendingPathComponent("client-before-cache-removal.json"),options:.atomic)
  let accepted=try JSONDecoder().decode(ICPersistedServerTranscriptionQueue.self,from:acceptedData).items[0]
  let serverHash=String(repeating:"a",count:64)
  precondition(accepted.admissionState == .accepted && accepted.sourceAudioSHA256==serverHash && accepted.audioSource == .client)
  CacheManager.instance.cached=false
  var sourceGateError:NSError?
  do {_ = try await importer.verifiedImportAudio(for:item,sourceAudioSHA256:serverHash)}
  catch {sourceGateError=error as NSError}
  // Exercise the real ready/apply/import failure transition too. These descriptors
  // satisfy all checks before the source gate; no artifact download is reached.
  let artifactHash=String(repeating:"0",count:64)
  resultPeer.artifacts=["transcript_srt","chapters_json","ads_json","summary_json"].enumerated().map { index,kind in
   ["id":index+1,"kind":kind,"url":"https://example.com/artifacts/\(index+1)","content_type":"application/json","byte_size":1,
    "sha256":artifactHash,"transcript_revision":"sha256:"+artifactHash,"etag":"fixture"] as [String:Any]
  }
  resultPeer.status="ready";importer.setDue(item);await importer.durable();importer.retryWakeTask?.cancel()
  results.append([
   "case":"accepted_client_source_cache_removed_before_ready",
   "expected":"A result matching the durable start SHA passes the source gate without a current cache file; request UUID remains unchanged",
   "expected_behavior_passed":sourceGateError == nil,
   "observed":["accepted":accepted.admissionState?.rawValue ?? "nil","source":accepted.audioSource?.rawValue ?? "nil",
               "stored_start_sha256":accepted.sourceAudioSHA256 ?? "nil","server_result_sha256":serverHash,
               "device_cache_present":CacheManager.instance.cached,"error_domain":sourceGateError?.domain ?? "nil",
               "error_code":sourceGateError?.code ?? 0,"error_message":sourceGateError?.localizedDescription ?? "nil",
               "queue_status_after_ready":String(describing:item.status),"queue_status_is_failed":item.status == .failed,"queue_phase_after_ready":item.serverPhase ?? "nil",
               "queue_error_after_ready":item.error ?? "nil","artifact_downloads_reached":importer.downloadGates.count,
               "post_count":resultPeer.postBodies.count,"get_count":resultPeer.getEvents.count,
               "original_uuid":requestID,"final_uuid":importer.clientRequestIDByItem[ObjectIdentifier(item)] ?? "nil"]
  ])
  let report:[String:Any]=["kind":"production-method boundary probe","results":results,
                         "all_expected_behavior_passed":results.allSatisfy {$0["expected_behavior_passed"] as? Bool == true}]
  let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
  try data.write(to:dir.appendingPathComponent("result.json"),options:.atomic)
  print(String(data:data,encoding:.utf8)!)
  if results.contains(where: {$0["expected_behavior_passed"] as? Bool == false}) {exit(1)}
 }
