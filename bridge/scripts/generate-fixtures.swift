import Foundation
let samples: [String: String] = [
  "short": "hello",
  "korean": "안녕하세요 Hermes 👋",
  "long": String(repeating: "가나다라마바사 ", count: 40),
  "huge": String(repeating: "x", count: 70000),
]
for (name, text) in samples {
  let s = NSMutableAttributedString(string: text)
  s.addAttribute(NSAttributedString.Key("__kIMMessagePartAttributeName"), value: 0, range: NSRange(location: 0, length: (text as NSString).length))
  let data = NSArchiver.archivedData(withRootObject: s)
  try! data.write(to: URL(fileURLWithPath: "\(name).bin"))
  print(name, data.count)
}
