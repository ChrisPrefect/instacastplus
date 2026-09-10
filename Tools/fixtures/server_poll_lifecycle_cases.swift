 var visibleChanges = 0
 var processingChanges: [Bool] = []
 static func run(in dir:URL) async throws {
  UserDefaults.standard.set(true,forKey:kServerTranscriptionEnabled)
  let server=FakeServer();let manager=Harness(server:server,file:dir.appendingPathComponent("lifecycle.json"));let item=manager.add(accepted:true)
  manager.start();await manager.durable()
  let visibleObserver=NotificationCenter.default.addObserver(forName:Notification.Name("ICTranscriptionQueueDidChangeNotification"),object:nil,queue:nil) { _ in
   MainActor.assumeIsolated { manager.visibleChanges += 1 }
  }
  let processingObserver=NotificationCenter.default.addObserver(forName:Notification.Name("ICServerTranscriptionProcessingDidChangeNotification"),object:nil,queue:nil) { _ in
   MainActor.assumeIsolated { manager.processingChanges.append(manager.isProcessing) }
  }
  manager.setDue(item);await manager.durable()
  var failures:[String]=[]
  if manager.visibleChanges != 0 { failures.append("Identical accepted queued poll published \(manager.visibleChanges) visible changes, expected0") }
  if manager.processingChanges != [true,false] { failures.append("Background lifecycle must see busy then idle after durable completion") }
  manager.visibleChanges=0;manager.processingChanges=[];server.status="running"
  manager.setDue(item);await manager.durable()
  if manager.visibleChanges != 1 { failures.append("Changed processing status must publish exactly one visible change") }
  if manager.processingChanges != [true,false] { failures.append("Real status change must retain lifecycle completion") }
  manager.visibleChanges=0;manager.processingChanges=[]
  let second=manager.add(hash:"second",accepted:true);manager.start();await manager.durable()
  manager.visibleChanges=0;manager.processingChanges=[];item.nextRetryAt=nil;second.nextRetryAt=nil;manager.processNext();await manager.durable()
  if manager.visibleChanges != 0 { failures.append("Identical multi-job polling must not reload visible queue") }
  if manager.processingChanges != [true,false] { failures.append("Sequential durable jobs must not publish false idle between them: \(manager.processingChanges)") }
  manager.visibleChanges=0;manager.processingChanges=[]
  manager.dequeueEpisodeHash(item.episodeHash);await manager.durable()
  if manager.visibleChanges == 0 { failures.append("Cancellation/removal must remain visible") }
  if manager.processingChanges.last != false { failures.append("Durable cancellation completion must publish idle") }
  manager.retryWakeTask?.cancel();NotificationCenter.default.removeObserver(visibleObserver);NotificationCenter.default.removeObserver(processingObserver)
  if !failures.isEmpty { FileHandle.standardError.write(Data((failures.joined(separator:"\n")+"\n").utf8));fatalError("Poll lifecycle regression") }
  print("PASS: unchanged polls0 visible events; real status/cancel changes visible; busy/idle lifecycle preserved without false idle between queued jobs")
 }
