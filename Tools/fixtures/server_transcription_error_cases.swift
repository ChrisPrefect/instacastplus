 static func run(in dir:URL) async throws {
  UserDefaults.standard.set(true,forKey:kServerTranscriptionEnabled)
  var failures:[String]=[]
  func expect(_ condition:Bool,_ message:String) { if !condition { failures.append(message) } }
  for code in ["audio_too_large","audio_duration_exceeded","audio_duration_invalid","source_audio_unavailable","no_speech","unsupported_language","processing_timeout"] {
   let manager=Harness(server:FakeServer(),file:dir.appendingPathComponent(code+".json"))
   let item=manager.add(accepted:true)
   let id=manager.clientRequestIDByItem[ObjectIdentifier(item)]!
   let wire:[String:Any] = ["api_version":"v1","episode":["id":42,"status":"failed","phase":"failed","progress":0.5,"warnings":[],"artifacts":[],"error":["code":code,"message":"RAW_SERVER_DIAGNOSTIC_DO_NOT_DISPLAY","retryable":false,"max_audio_bytes":750*1024*1024,"max_duration_seconds":86400,"source_status":410]],"client_request":["id":id,"state":"active","episode_id":42]]
   let envelope=try JSONDecoder().decode(ICServerEpisodeEnvelope.self,from:JSONSerialization.data(withJSONObject:wire))
   await manager.apply(envelope,to:item,requestID:id)
   expect(item.status == .failed && item.nextRetryAt == nil,"Terminal \(code) must fail without automatic resubmission")
   expect(item.error?.contains("RAW_SERVER") == false,"\(code) must display localized useful error, not raw server diagnostic")
   expect(manager.admissionByItem[ObjectIdentifier(item)] == .accepted,"Terminal processing failure must preserve truthful accepted admission")
   expect(manager.serverIDByItem[ObjectIdentifier(item)] == 42,"Source410/processing failure must retain accepted remote identity")
   if code == "audio_duration_exceeded" { expect(item.error?.contains("24") == true,"Duration rejection must show actual server limit") }
  }
  for seconds in [9000,172800] {
   let wire:[String:Any] = ["code":"audio_duration_exceeded","message":"raw","retryable":false,"max_duration_seconds":seconds]
   let error=try JSONDecoder().decode(ICServerError.self,from:JSONSerialization.data(withJSONObject:wire))
   let expectedHours=NumberFormatter.localizedString(from:NSNumber(value:Double(seconds)/3600),number:.decimal)
   expect(error.localizedMessage.contains(expectedHours),"Duration limit must use server value, not a fixed 24h assumption")
  }
  let paused=Harness(server:FakeServer(),file:dir.appendingPathComponent("resource-pause.json"));let item=paused.add(accepted:true)
  let id=paused.clientRequestIDByItem[ObjectIdentifier(item)]!
  let data=Data(#"{"api_version":"v1","episode":{"id":42,"status":"running","phase":"transcribing","progress":0.2,"warnings":[],"artifacts":[],"error":{"code":"resources_unavailable","message":"RAW_DISK_PATH","retryable":true}},"retry_after_seconds":60,"service_status":{"available":false,"code":"resources_unavailable"}}"#.utf8)
  await paused.apply(try JSONDecoder().decode(ICServerEpisodeEnvelope.self,from:data),to:item,requestID:id)
  expect(item.status == .transcribing && item.nextRetryAt != nil,"Resource pause must preserve accepted work and poll")
  expect(item.statusDetail?.contains("server resources") == true,"Resource pause needs a localized actionable explanation")
  paused.retryWakeTask?.cancel()
  if !failures.isEmpty { for failure in failures { FileHandle.standardError.write(Data(("FAIL: "+failure+"\n").utf8)) }; throw NSError(domain:"ErrorContract",code:1) }
  print("Server typed error/lifecycle matrix passed")
 }
