#!/usr/bin/env python3
"""Configured feed locales must map to actual Whisper language codes before inference."""
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
s = (ROOT / 'Classes/TranscriptionEngine.swift').read_text()
start = s.index('    private static func validatedWhisperLanguage(')
end = s.index('\n    private func transcribeWithWhisperKit', start)
method = s[start:end].replace('private static func','static func')
fixture = '''
import Foundation
// Controlled library catalogue; production reads WhisperKit's exported supported set.
enum Constants { static let languageCodes: Set<String> = ["en", "de", "fr"] }
struct Engine { METHOD }
@main struct Test {
 static func main() throws {
  let automatic = try Engine.validatedWhisperLanguage(nil)
  precondition(automatic == nil)
  let empty = try Engine.validatedWhisperLanguage("  ")
  precondition(empty == nil)
  for (input, expected) in [("DE-ch","de"),("en_US","en"),("fr","fr")] {
   let actual = try Engine.validatedWhisperLanguage(input); precondition(actual == expected)
  }
  do { _ = try Engine.validatedWhisperLanguage("xx-XX"); fatalError("Unsupported language entered inference") }
  catch { precondition((error as NSError).userInfo["transcriptionErrorCode"] as? String == "unsupported_language") }
 }
}
'''.replace('METHOD',method)
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'main.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
print('Whisper language validation passed')
