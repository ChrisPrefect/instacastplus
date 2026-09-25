 static func run(in dir:URL) async throws {
  UserDefaults.standard.set(true,forKey:kServerTranscriptionEnabled)
  var failures: [String] = []
  func expect(_ condition:Bool,_ message:String) { if !condition { failures.append(message) } }
  for (index, phase) in ["downloading_audio", "transcribing", "analyzing", "finalizing"].enumerated() {
   let manager = Harness(server:FakeServer(),file:dir.appendingPathComponent("phase-\(index).json"))
   let item = manager.add(accepted:true); item.progress = 0.5
   let response = Data("""
   {"api_version":"v1","episode":{"id":1,"status":"running","phase":"\(phase)","progress":null,"warnings":[],"artifacts":[]},"retry_after_seconds":30}
   """.utf8)
   let envelope = try JSONDecoder().decode(ICServerEpisodeEnvelope.self,from:response)
   await manager.apply(envelope,to:item,requestID:manager.clientRequestIDByItem[ObjectIdentifier(item)])
   expect(item.status == .transcribing,"Unknown total progress must not fail a valid active phase")
   expect(item.serverPhase == phase && item.serverLastResponseAt != nil,"UI must receive the confirmed phase and response time")
   expect(item.progress == 0,"Restored weighted progress must be cleared")
   expect(item.statusDetail?.contains("Step \(index+1) of 4") == true,"Each phase must name its actual processing step")
   manager.retryWakeTask?.cancel()
  }
  let unknown=Harness(server:FakeServer(),file:dir.appendingPathComponent("unknown-phase.json"))
  let unknownItem=unknown.add(accepted:true)
  let unknownEnvelope=try JSONDecoder().decode(ICServerEpisodeEnvelope.self,from:Data(#"{"api_version":"v1","episode":{"id":42,"status":"running","phase":"new-unknown-phase","warnings":[],"artifacts":[]},"retry_after_seconds":30}"#.utf8))
  await unknown.apply(unknownEnvelope,to:unknownItem,requestID:unknown.clientRequestIDByItem[ObjectIdentifier(unknownItem)])
  expect(unknownItem.requiresExplicitRetryAfterCrash,"An unknown server phase cannot authorize regeneration; keep a status-check action")
  unknown.retryWakeTask?.cancel()
  let continuityServer=FakeServer()
  let continuity=Harness(server:continuityServer,file:dir.appendingPathComponent("accepted-contract-error.json"))
  let continuityItem=continuity.add(accepted:true)
  let originalID=continuity.clientRequestIDByItem[ObjectIdentifier(continuityItem)]
  expect(continuity.hasPendingAutomaticItems,"Manual accepted server work must remain eligible for background status/import")
  await continuity.handle(error:NSError(domain:"ICServerTranscription.Contract",code:21,userInfo:[NSLocalizedDescriptionKey:"Invalid response identity"]),for:continuityItem)
  expect(continuityItem.requiresExplicitRetryAfterCrash,"Unreadable accepted state must request a status check, not force regeneration")
  continuity.retryEpisodeHash(continuityItem.episodeHash);await continuity.durable()
  expect(continuity.clientRequestIDByItem[ObjectIdentifier(continuityItem)] == originalID,"Checking an accepted request must preserve its identity")
  expect(continuityServer.postBodies.isEmpty,"Checking an accepted request must not submit a new transcription")
  continuity.retryWakeTask?.cancel()
  for code in ["queue_full","client_queue_full","provider_unavailable","worker_unavailable","resources_unavailable"] {
   let server=FakeServer();server.rejectionCode=code
   let manager=Harness(server:server,file:dir.appendingPathComponent(code+".json"));let item=manager.add();manager.start();await manager.durable()
   expect(item.status == .failed,"Definite \(code) refusal must not remain active")
   expect(item.nextRetryAt == nil,"Definite \(code) refusal must not auto-POST")
   expect(item.error?.isEmpty == false,"Definite \(code) refusal needs a visible reason")
   expect(server.registrations.isEmpty,"Refused request must have no server job")
   manager.retryWakeTask?.cancel()
  }
  let diskServer=FakeServer();let diskFile=dir.appendingPathComponent("disk-failure.json")
  SnapshotWriter.shared.failMarkerWrite(at:diskFile)
  let disk=Harness(server:diskServer,file:diskFile);let diskItem=disk.add();disk.start();await disk.durable()
  expect(diskServer.events.isEmpty,"Failed pre-POST snapshot must never send HTTP")
  expect(diskItem.status == .failed && diskItem.nextRetryAt == nil,"Failed pre-POST snapshot must reject and release app slot")
  expect(diskItem.error?.contains("saved") == true,"Pre-POST persistence failure needs an accurate not-added explanation")
  disk.retryWakeTask?.cancel()
  let fullDiskServer=FakeServer();let fullDiskFile=dir.appendingPathComponent("persistent-disk-failure.json")
  SnapshotWriter.shared.failMarkerWrite(at:fullDiskFile,persistently:true)
  let fullDisk=Harness(server:fullDiskServer,file:fullDiskFile);let fullDiskItem=fullDisk.add();fullDiskItem.automaticallyScheduled=true;fullDisk.start();await fullDisk.durable()
  let onDisk=try JSONDecoder().decode(ICPersistedServerTranscriptionQueue.self,from:Data(contentsOf:fullDiskFile))
  expect(onDisk.items[0].admissionState == .pending,"Disk-full proof must leave only never-submitted intent on disk")
  expect(fullDiskItem.status == .failed && fullDiskServer.events.isEmpty,"Disk-full rejection must not send HTTP")
  SnapshotWriter.shared.allowWrites()
  let diskRelaunch=Harness(server:fullDiskServer,file:fullDiskFile);diskRelaunch.loadPersistedQueue();let restoredPending=diskRelaunch.items[0]
  expect(restoredPending.status == .failed && restoredPending.nextRetryAt == nil,"Restored pending intent must require explicit retry")
  diskRelaunch.resumeIfNeeded();await diskRelaunch.durable()
  expect(fullDiskServer.events.isEmpty,"Restored never-submitted automatic intent must not silently POST")
  fullDisk.retryWakeTask?.cancel();diskRelaunch.retryWakeTask?.cancel()
  let apiError = try JSONDecoder().decode(ICServerAPIErrorEnvelope.self, from: Data(#"{"api_version":"v1","error":{"code":"queue_full","message":"full","retryable":true,"admitted":false}}"#.utf8))
  expect(apiError.error.admitted == false,"Wire error must preserve authoritative admission refusal")
  let offlineServer=FakeServer();let offline=Harness(server:offlineServer,file:dir.appendingPathComponent("known-offline.json"));offline.networkUnavailable=true
  let offlineItem=offline.add();offline.start();await offline.durable()
  expect(offlineItem.status == .queued && offlineServer.events.isEmpty,"Offline submission must remain queued without sending")
  expect(offline.hasPendingAutomaticItems && offline.earliestAutomaticWorkDate != nil,"Manual offline requests need automatic background network scheduling")
  offline.retryWakeTask?.cancel()
  let offlineRestored=Harness(server:offlineServer,file:offline.queueFileURL);offlineRestored.networkUnavailable=true;offlineRestored.loadPersistedQueue()
  expect(offlineRestored.items.first?.status == .queued,"Offline intent must survive restart as queued")
  offlineRestored.networkUnavailable=false;offlineRestored.resumeIfNeeded();await offlineRestored.durable()
  expect(offlineServer.postBodies.count == 1,"Network recovery must submit saved offline intent automatically")
  expect(offlineServer.postBodies.first?["client_request_id"] as? String == offline.clientRequestIDByItem[ObjectIdentifier(offlineItem)],"Offline restart must preserve request UUID")
  offlineRestored.retryWakeTask?.cancel()
  offline.dequeueEpisodeHash(offlineItem.episodeHash);await offline.durable()
  expect(offline.cancellations.isEmpty,"Never-sent rejection must not invent pending server cancellation")
  // Regression: a locally rejected attempt must not force regeneration on the server.
  let retryServer=FakeServer(); let retry=Harness(server:retryServer,file:dir.appendingPathComponent("local-retry.json"))
  let retryItem=retry.add(); retry.rejectAdmission(retryItem,message:"offline")
  retry.retryEpisodeHash(retryItem.episodeHash); await retry.durable()
  expect(retryServer.postBodies.last?["force"] as? Bool == false,"Retry after local rejection must not send force=true")
  retry.retryWakeTask?.cancel()
  let forbidden=Harness(server:FakeServer(),file:dir.appendingPathComponent("forbidden.json"));let forbiddenItem=forbidden.add()
  forbidden.admissionByItem[ObjectIdentifier(forbiddenItem)] = .unconfirmed
  await forbidden.handle(error:NSError(domain:"ICServerTranscription",code:403,userInfo:["serverRetryable":false,NSLocalizedDescriptionKey:"force is disabled for API clients"]),for:forbiddenItem)
  expect(forbiddenItem.status == .failed && forbiddenItem.nextRetryAt == nil,"HTTP403 must stop the confirmation loop and report a failure")
  expect(forbiddenItem.error?.contains("403") == true,"HTTP rejection must name its actual status")
  forbidden.retryWakeTask?.cancel()
  let heldServer=FakeServer();heldServer.holdAck=true
  let held=Harness(server:heldServer,file:dir.appendingPathComponent("held.json"));let heldItem=held.add();var feedback:[Bool]=[]
  held.admissionCompletions[ObjectIdentifier(heldItem)] = { accepted,_ in feedback.append(accepted) }
  held.start();await held.until { heldServer.postGate != nil }
  expect(feedback.isEmpty && heldItem.status == .queued && heldItem.statusStartedAt == nil,"In-flight POST must not report accepted or running")
  heldServer.postGate!.resume();heldServer.postGate=nil;await held.durable()
  expect(feedback == [true],"Validated receipt must confirm admission once")
  held.retryWakeTask?.cancel()
  let queuedServer=FakeServer();let queued=Harness(server:queuedServer,file:dir.appendingPathComponent("queued.json"));let queuedItem=queued.add();queued.start();await queued.durable()
  expect(queuedItem.status == .queued,"Accepted queued response must not claim running")
  queued.retryWakeTask?.cancel()
  for malformed in [false,true] {
   let server=FakeServer();server.loseAck = !malformed;server.malformedAck=malformed
   let path=dir.appendingPathComponent("ambiguous-\(malformed).json")
   let manager=Harness(server:server,file:path);let item=manager.add();let id=manager.clientRequestIDByItem[ObjectIdentifier(item)]!
   manager.start();await manager.durable()
   expect(item.status == (malformed ? .failed : .queued),"Malformed replies stop visibly; lost transport replies stay queued")
   expect(item.statusStartedAt == nil,"Unconfirmed admission must not start processing timer")
   expect(malformed ? (item.nextRetryAt == nil && item.requiresExplicitRetryAfterCrash) : item.nextRetryAt != nil,"Malformed replies require explicit status check; lost replies reconcile automatically")
   item.progress = 0.5
   item.statusDetail = "Die Serveraufnahme ist unbestätigt. Die App prüft dieselbe Anfrage erneut; bitte nicht doppelt einreichen."
   manager.persistQueue(); await manager.durable()
   manager.retryWakeTask?.cancel()
   let restarted=Harness(server:server,file:path);restarted.loadPersistedQueue();let restored=restarted.items[0]
   expect(restored.progress == 0,"Relaunch must discard legacy weighted progress")
   if !malformed { expect(restored.statusDetail?.contains("Checking whether the server received") == true,"Relaunch must name request reconciliation") }
   if malformed { restarted.retryEpisodeHash(restored.episodeHash) } else { restarted.setDue(restored) };await restarted.durable()
   expect(server.getEvents == [id],"Restart must reconcile same UUID by GET before any POST")
   expect(server.events == ["POST:"+id],"Lost acknowledgement must not repeat known accepted POST")
   expect(restarted.serverIDByItem[ObjectIdentifier(restored)] != nil,"Reconciliation must bind accepted receipt")
   restarted.retryWakeTask?.cancel()
  }
  // A known-absent registration after an unknown response may replay only the same UUID.
  let absentServer=FakeServer();absentServer.loseAck=true
  let absent=Harness(server:absentServer,file:dir.appendingPathComponent("absent.json"));let absentItem=absent.add();let absentID=absent.clientRequestIDByItem[ObjectIdentifier(absentItem)]!
  absent.start();await absent.durable();absentServer.registrations.removeValue(forKey:absentID);absent.setDue(absentItem);await absent.durable()
  expect(absentServer.getEvents == [absentID] && absentServer.events == ["POST:"+absentID,"POST:"+absentID] && absentServer.nextID==101,"Unknown request GET404 replay must reuse UUID and shared job")
  absent.retryWakeTask?.cancel()
  // Unconfirmed admission can be canceled offline, including after restart.
  let cancelServer=FakeServer();cancelServer.loseAck=true
  let cancelFile=dir.appendingPathComponent("cancel-unknown.json")
  let cancel=Harness(server:cancelServer,file:cancelFile);let cancelItem=cancel.add();let cancelID=cancel.clientRequestIDByItem[ObjectIdentifier(cancelItem)]!
  cancel.start();await cancel.durable();cancelServer.online=false;cancel.dequeueEpisodeHash(cancelItem.episodeHash);await cancel.durable();cancel.retryWakeTask?.cancel()
  let restoredCancel=Harness(server:cancelServer,file:cancelFile);restoredCancel.loadPersistedQueue();cancelServer.online=true;restoredCancel.retryPendingCancellations();await restoredCancel.durable()
  expect(cancelServer.tombstones.contains(cancelID) && restoredCancel.cancellations.isEmpty && restoredCancel.items.isEmpty,"Unconfirmed cancellation must survive offline restart")
  let pausedServer=FakeServer();pausedServer.pollErrorCode="provider_unavailable"
  let paused=Harness(server:pausedServer,file:dir.appendingPathComponent("provider-paused.json"));let pausedItem=paused.add(accepted:true);pausedItem.status = .transcribing;pausedItem.progress=0.4
  paused.start();await paused.durable()
  expect(pausedItem.status == .transcribing && pausedItem.progress==0.4 && paused.serverIDByItem[ObjectIdentifier(pausedItem)]==42,"Accepted provider outage must preserve job ownership/progress")
  expect((pausedItem.nextRetryAt?.timeIntervalSinceNow ?? 0)>290,"Accepted provider outage must respect server retry hint")
  expect(pausedItem.statusDetail?.contains("paused") == true,"Accepted provider outage needs a clear paused reason")
  paused.retryWakeTask?.cancel()
  let oldServer=FakeServer();oldServer.online=false
  let old=Harness(server:oldServer,file:dir.appendingPathComponent("long-offline.json"));let oldItem=old.add(accepted:true);oldItem.statusStartedAt=Date(timeIntervalSinceNow:-86400*7);old.start();await old.durable()
  expect(oldItem.status != .failed && oldItem.status != .canceled,"Accepted long job must survive transport outage without lifetime timeout")
  expect(oldItem.nextRetryAt != nil,"Accepted offline job must keep polling")
  old.retryWakeTask?.cancel()
  if !failures.isEmpty { FileHandle.standardError.write(Data((failures.joined(separator:"\n")+"\n").utf8));fatalError("Admission contract failures: \(failures.count)") }
  print("PASS: pre-POST disk-full rejection + pending restore without auto-POST, definite refusals, offline before POST, confirmed-only feedback, truthful queued state, lost/malformed POST + restart + GET404 same UUID, offline unconfirmed cancellation, accepted provider pause, long offline job")
 }
