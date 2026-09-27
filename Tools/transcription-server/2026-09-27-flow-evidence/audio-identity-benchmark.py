from pathlib import Path
import hashlib,json,platform,subprocess,tempfile
ROOT=Path('/Users/Chris/Developer/instacastplus')
source=(ROOT/'Classes/TranscriptionEngine.swift').read_text()
start=source.index('enum ICAudioIdentity {');brace=source.index('{',start);depth=0
for end in range(brace,len(source)):
    depth+=(source[end]=='{')-(source[end]=='}')
    if depth==0:
        identity=source[start:end+1];break
swift='import Foundation\nimport CryptoKit\n'+identity+'''
@main struct Bench {
 static func main() async throws {
  var results: [[String:Any]]=[]
  for path in CommandLine.arguments.dropFirst() {
   let url=URL(fileURLWithPath:path)
   let size=(try FileManager.default.attributesOfItem(atPath:path)[.size] as! NSNumber).int64Value
   var milliseconds:[Double]=[];var digest=""
   for _ in 0..<6 {
    let start=DispatchTime.now().uptimeNanoseconds
    let fingerprint=try await ICAudioIdentity.fingerprint(of:url)
    milliseconds.append(Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000)
    digest=fingerprint.sha256
   }
   results.append(["input":url.lastPathComponent,"bytes":size,"milliseconds":milliseconds,"sha256":digest])
  }
  print(String(data:try JSONSerialization.data(withJSONObject:results,options:[.sortedKeys]),encoding:.utf8)!)
 }
}
'''
with tempfile.TemporaryDirectory(prefix='instacast-audio-identity-bench-') as tmp:
 p=Path(tmp);(p/'bench.swift').write_text(swift)
 big=p/'synthetic-200MB.bin';block=bytes(range(256))*4096
 with big.open('wb') as f:
  left=200_000_000
  while left: part=block[:min(left,len(block))];f.write(part);left-=len(part)
 results={'environment':platform.platform(),'source_sha256':hashlib.sha256(identity.encode()).hexdigest(),'notes':'Actual production ICAudioIdentity, macOS host; locally written synthetic file and existing fixture. Files may be in OS page cache; no device/network/persistence timing. Six sequential samples include task scheduling and file stat/read/hash/stat.','command':'python3 /tmp/instacast_audio_identity_benchmark.py','builds':{}}
 for optimization in ['-Onone','-O']:
  subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',optimization,str(p/'bench.swift'),'-o',str(p/'bench')],check=True)
  results['builds'][optimization]=json.loads(subprocess.check_output([str(p/'bench'),str(ROOT/'Tools/fixtures/server-sponsor-e2e/fixture.wav'),str(big)],text=True))
 print(json.dumps(results,indent=2))
