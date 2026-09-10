#!/usr/bin/env python3
"""Actual Swift transport against a controlled HTTP peer: size/deadline/cancel."""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import subprocess, tempfile, threading, time, os
ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'Classes/ServerTranscriptionManager.swift').read_text()
signature='private final class ICServerHTTPClient:'
def declaration(text,start):
 p=text.index(start);brace=text.index('{',p);depth=0
 for end in range(brace,len(text)):
  depth+=(text[end]=='{')-(text[end]=='}')
  if not depth:return text[p:end+1]
if os.environ.get('INSTACAST_HTTP_HELPER_TEST'):
 helper=Path(os.environ['INSTACAST_HTTP_HELPER_TEST']).read_text()
elif signature in source:helper=declaration(source,signature)
else:
 assert 'try await URLSession.shared.data(for: request)' in source
 helper='''private final class ICServerHTTPClient: @unchecked Sendable {
 init(resourceTimeout: TimeInterval = 120) {}
 func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, URLResponse) {
 return try await URLSession.shared.data(for: request)
 }}'''
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  self.send_response(200)
  if self.path=='/declared':self.send_header('Content-Length','65536')
  elif self.path=='/ok':self.send_header('Content-Length','2')
  self.end_headers()
  try:
   if self.path=='/ok':self.wfile.write(b'ok');return
   for _ in range(64):
    self.wfile.write(b'x'*1024);self.wfile.flush()
    if self.path=='/slow':time.sleep(.1)
  except (BrokenPipeError, ConnectionResetError):pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
fixture='''import Foundation
HELPER
@main struct Test {
 static func main() async throws {
  let base=URL(string:CommandLine.arguments[1])!
  let client=ICServerHTTPClient(resourceTimeout:0.5)
  for path in ["declared","unknown"] {
   do {
    _ = try await client.data(for:URLRequest(url:base.appendingPathComponent(path)),maximumBytes:16384)
    fatalError("Oversized response buffered and accepted")
   } catch { precondition((error as NSError).domain=="ICServerTranscription" && (error as NSError).code==24) }
  }
  let start=Date()
  do {
   _ = try await client.data(for:URLRequest(url:base.appendingPathComponent("slow")),maximumBytes:131072)
   fatalError("Slow continuous response exceeded total deadline")
  } catch { precondition((error as NSError).code==NSURLErrorTimedOut, "Expected total timeout: \\(error)") }
  precondition(Date().timeIntervalSince(start)<2)
  for _ in 0..<30 {
   let task=Task { try await client.data(for:URLRequest(url:base.appendingPathComponent("slow")),maximumBytes:131072) }
   task.cancel()
   do { _ = try await task.value; fatalError("Canceled request accepted") } catch { precondition(error is CancellationError || (error as NSError).code==NSURLErrorCancelled) }
  }
  let task=Task { try await client.data(for:URLRequest(url:base.appendingPathComponent("slow")),maximumBytes:131072) }
  try await Task.sleep(nanoseconds:100_000_000)
  task.cancel()
  do { _ = try await task.value; fatalError("In-flight cancellation ignored") } catch { precondition(error is CancellationError || (error as NSError).code==NSURLErrorCancelled) }
  try await withThrowingTaskGroup(of:Void.self) { group in
   for _ in 0..<25 { group.addTask {
    let (data,response)=try await client.data(for:URLRequest(url:base.appendingPathComponent("ok")),maximumBytes:2)
    precondition(data==Data("ok".utf8) && (response as? HTTPURLResponse)?.statusCode==200)
   }}
   try await group.waitForAll()
  }
  print("size, total deadline, cancellation races and25 concurrent valid requests passed")
 }
}
'''.replace('HELPER',helper)
try:
 with tempfile.TemporaryDirectory(prefix='instacast-http-') as directory:
  path=Path(directory);(path/'main.swift').write_text(fixture)
  subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',str(path/'main.swift'),'-o',str(path/'test')],check=True)
  subprocess.run([str(path/'test'),'http://127.0.0.1:'+str(server.server_port)],check=True,timeout=15)
finally:server.shutdown();server.server_close();thread.join()
