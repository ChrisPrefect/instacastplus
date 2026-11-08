#!/usr/bin/env python3
"""Protect the actual production hash's wire identity before optimizing formatting.

Concrete failure: changed digest text would duplicate CloudKit record identities
and invalidate saved payload hashes. An E2E with a few podcasts cannot exhaust
byte values and Unicode/empty/NUL inputs, nor verify a signed-in cloud here.
Compile the production helper, compare with independent hashlib SHA-256 vectors,
and retain the real-app rank-boundary E2E as the performance regression gate.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time

root=Path(__file__).resolve().parents[1]
source=(root/'Classes/ICiCloudSyncManager+Metadata.swift').read_text()
start=source.index('    nonisolated static func sha256Hex(_ string: String) -> String {')
opening=source.index('{',start);depth=1;end=opening+1
while depth:
    depth+=(source[end]=='{')-(source[end]=='}');end+=1
method=source[start:end]
inputs=['','abc','a\0b','é','e\u0301','🎙️ 中文 العربية','https://example.org/über/all?x=🔥']
inputs += [f'https://example.org/podcast/{i}/feed.xml' for i in range(1024)]
vectors=[dict(input=s,expected=hashlib.sha256(s.encode()).hexdigest()) for s in inputs]
assert len(set(b for s in inputs for b in hashlib.sha256(s.encode()).digest()))==256
with tempfile.TemporaryDirectory(prefix='ic-cloud-identity-') as directory:
    folder=Path(directory);fixture=folder/'vectors.json';fixture.write_text(json.dumps(vectors))
    swift=folder/'proof.swift'
    swift.write_text('''import Foundation
import CryptoKit
struct Production {
'''+method+'''
}
let rows=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:String]]
for row in rows {
 let actual=Production.sha256Hex(row["input"]!)
 guard actual==row["expected"] else {fatalError("Cloud identity changed: \\(actual)")}
}
let start=Date()
var checksum=0
for _ in 0..<10 {for row in rows { checksum &+= Int(Production.sha256Hex(row["input"]!).utf8.first!) }}
guard checksum==10*rows.reduce(0,{$0+Int($1["expected"]!.utf8.first!)}) else {fatalError("Batch identity changed")}
print("PASS \\(rows.count) independent SHA-256 wire-identity vectors, all 256 digest byte values; checksum \\(checksum); 10x batch \\(Date().timeIntervalSince(start)) seconds")
''')
    subprocess.run(['xcrun','swiftc','-O',str(swift),'-o',str(folder/'proof')],check=True)
    subprocess.run([str(folder/'proof'),str(fixture)],check=True)
