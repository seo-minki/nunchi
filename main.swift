// nunchi — 실행 중인 카카오톡(macOS)을 손쉬운 사용(Accessibility) API로 읽고 쓰는 터미널 클라이언트
import Cocoa
import ApplicationServices

// MARK: - 터미널 스타일

let dim = "\u{1B}[2m", bold = "\u{1B}[1m", reset = "\u{1B}[0m"
let orange = "\u{1B}[38;5;173m", cyan = "\u{1B}[36m", yellow = "\u{1B}[33m"

func die(_ msg: String) -> Never {
  FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
  exit(1)
}

// MARK: - AX 헬퍼
// 카톡은 AX 요청 하나에 10ms 안팎이 걸리므로, 요청 횟수를 줄이는 게 속도의 전부다.

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
  var v: AnyObject?
  AXUIElementCopyAttributeValue(e, a as CFString, &v)
  return v
}
func str(_ e: AXUIElement, _ a: String) -> String? { attr(e, a) as? String }
func kids(_ e: AXUIElement) -> [AXUIElement] { attr(e, "AXChildren") as? [AXUIElement] ?? [] }
func role(_ e: AXUIElement) -> String { str(e, "AXRole") ?? "" }

func find(_ e: AXUIElement, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
  if match(e) { return e }
  for k in kids(e) { if let r = find(k, match) { return r } }
  return nil
}

func same(_ a: AnyObject?, _ b: AXUIElement) -> Bool {
  guard let a else { return false }
  return CFEqual(a, b)
}

/// 요소 하나의 자주 쓰는 속성을 요청 한 번으로 가져온다
struct Node {
  let el: AXUIElement
  var role = "", id = "", value = "", desc = "", title = ""
  var frame = CGRect.zero
}
let nodeAttrs = ["AXRole", "AXIdentifier", "AXValue", "AXDescription", "AXTitle", "AXPosition", "AXSize"] as CFArray
func node(_ e: AXUIElement) -> Node {
  var n = Node(el: e)
  var raw: CFArray?
  guard AXUIElementCopyMultipleAttributeValues(e, nodeAttrs, [], &raw) == .success,
        let vals = raw as? [AnyObject], vals.count == 7 else { return n }
  n.role = vals[0] as? String ?? ""
  n.id = vals[1] as? String ?? ""
  n.value = vals[2] as? String ?? ""
  n.desc = vals[3] as? String ?? ""
  n.title = vals[4] as? String ?? ""
  var p = CGPoint.zero, s = CGSize.zero
  if CFGetTypeID(vals[5]) == AXValueGetTypeID() { AXValueGetValue(vals[5] as! AXValue, .cgPoint, &p) }
  if CFGetTypeID(vals[6]) == AXValueGetTypeID() { AXValueGetValue(vals[6] as! AXValue, .cgSize, &s) }
  n.frame = CGRect(origin: p, size: s)
  return n
}

// MARK: - 카카오톡 연결

let version = "0.5.3"
if CommandLine.arguments.contains("--version") { print("nunchi \(version)"); exit(0) }

// MARK: - 업데이트
// install.sh가 저장소 위치를 ~/.config/nunchi/source에 적어 둔다. --update는 거기서 git pull 후 다시 설치한다.

// install.sh와 같은 곳을 보도록 $HOME을 따른다
let configDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()).appendingPathComponent(".config/nunchi")
func sourceDir() -> String? {
  guard let s = try? String(contentsOf: configDir.appendingPathComponent("source"), encoding: .utf8) else { return nil }
  let path = s.trimmingCharacters(in: .whitespacesAndNewlines)
  return FileManager.default.fileExists(atPath: path + "/.git") ? path : nil
}

if CommandLine.arguments.contains("--update") {
  guard let src = sourceDir() else {
    die("저장소 위치를 모릅니다. 클론한 폴더에서 git pull && ./install.sh 를 실행해 주세요.")
  }
  print("업데이트: \(src)")
  fflush(stdout)
  // 자식 프로세스(Process)로 띄우면 터미널의 백그라운드가 되어 sudo 비밀번호가 평문으로 보이고 입력도 안 된다.
  // 이 프로세스 자체를 셸로 바꿔(exec) 포그라운드에서 실행한다.
  var args: [UnsafeMutablePointer<CChar>?] = []
  for a in ["sh", "-c", "cd \"$1\" && git pull --ff-only && ./install.sh", "sh", src] { args.append(strdup(a)) }
  args.append(nil)
  execv("/bin/sh", args)
  die("업데이트를 실행하지 못했습니다.")
}

/// "0.10.0" > "0.9.1" 처럼 숫자로 비교한다
func isNewer(_ a: String, than b: String) -> Bool {
  let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
  for i in 0..<max(x.count, y.count) {
    let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
    if p != q { return p > q }
  }
  return false
}

/// GitHub의 최신 버전 태그. 하루에 한 번만 확인하고 결과를 기억해 둔다.
/// 버전 태그 목록만 받아 오고 카카오톡 데이터는 아무것도 보내지 않는다.
func latestVersion() -> String? {
  if ProcessInfo.processInfo.environment["NUNCHI_NO_UPDATE_CHECK"] != nil { return nil }
  guard let src = sourceDir() else { return nil }
  let stamp = configDir.appendingPathComponent("latest-version")
  if let d = (try? FileManager.default.attributesOfItem(atPath: stamp.path))?[.modificationDate] as? Date,
     Date().timeIntervalSince(d) < 86400 {
    return (try? String(contentsOf: stamp, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  let p = Process(), pipe = Pipe()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  p.arguments = ["-C", src, "ls-remote", "--tags", "--refs", "origin", "v*"]
  p.standardOutput = pipe
  p.standardError = FileHandle.nullDevice
  guard (try? p.run()) != nil else { return nil }
  DispatchQueue.global().asyncAfter(deadline: .now() + 8) { if p.isRunning { p.terminate() } }
  p.waitUntilExit()
  guard p.terminationStatus == 0 else { return nil }
  let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  let tags = out.split(separator: "\n").compactMap { $0.split(separator: "/").last.map { String($0.dropFirst()) } }
  guard let best = tags.max(by: { isNewer($1, than: $0) }) else { return nil }
  try? best.write(to: stamp, atomically: true, encoding: .utf8)
  return best
}

// --demo: 카톡에 연결하지 않고 가짜 데이터로 화면을 한 번 그린다 (README 스크린샷용)
let demo = CommandLine.arguments.contains("--demo")
guard demo || AXIsProcessTrusted() else {
  die("손쉬운 사용 권한이 필요합니다: 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 터미널 앱을 켜 주세요.")
}
guard let kakao = NSRunningApplication.runningApplications(withBundleIdentifier: "com.kakao.KakaoTalkMac").first
        ?? (demo ? NSRunningApplication.current : nil) else {
  die("카카오톡이 실행 중이 아닙니다.")
}
let app = AXUIElementCreateApplication(kakao.processIdentifier)
AXUIElementSetMessagingTimeout(app, 2.0)

func windows() -> [Node] { (attr(app, "AXWindows") as? [AXUIElement] ?? []).map(node) }
func mainWindow() -> AXUIElement? { windows().first { $0.id == "Main Window" }?.el }
func roomWindow(_ name: String) -> AXUIElement? {
  windows().first { $0.title == name && $0.id != "Main Window" }?.el
}
func alive(_ win: AXUIElement) -> Bool { (attr(app, "AXWindows") as? [AXUIElement] ?? []).contains { CFEqual($0, win) } }

/// 채팅방 목록 표. 메인 창이 친구·더보기 탭이면 목록 표가 사라지므로 채팅 탭 버튼(chatrooms)을 눌러 돌려놓는다.
var cachedChat: (scroll: AXUIElement, table: AXUIElement)?
func mainTable() -> AXUIElement? {
  guard let main = mainWindow() else { return nil }
  let children = kids(main)
  // 채팅 목록 스크롤 영역이 아직 메인 창에 붙어 있으면 캐시를 그대로 쓴다 (탭이 바뀌면 떨어져 나간다)
  if let c = cachedChat, children.contains(where: { CFEqual($0, c.scroll) }) { return c.table }
  func chatScroll() -> AXUIElement? { kids(main).first { str($0, "AXIdentifier") == "_NS:101" } }
  var scroll = chatScroll()
  if scroll == nil, let tab = children.first(where: { str($0, "AXIdentifier") == "chatrooms" }) {
    AXUIElementPerformAction(tab, "AXPress" as CFString)
    for _ in 0..<10 { usleep(50_000); scroll = chatScroll(); if scroll != nil { break } }
  }
  guard let scroll, let table = kids(scroll).first(where: { role($0) == "AXTable" }) else { return nil }
  cachedChat = (scroll, table)
  return table
}
func mainRows() -> [AXUIElement] { mainTable().flatMap { attr($0, "AXRows") as? [AXUIElement] } ?? [] }

// MARK: - 채팅방 목록

var cachedUnreadTotal: AXUIElement?
/// 메인 창 왼쪽의 "안 읽은 메시지 총합" 숫자. 목록이 바뀌었는지 싸게 확인하는 데 쓴다.
func unreadTotal() -> String {
  if cachedUnreadTotal == nil || role(cachedUnreadTotal!) != "AXStaticText" {
    cachedUnreadTotal = mainWindow().flatMap { kids($0).map(node).first { $0.role == "AXStaticText" && $0.id == "_NS:148" }?.el }
  }
  return cachedUnreadTotal.flatMap { str($0, "AXValue") } ?? ""
}

struct Room { let name: String; let unread: Int; var last = ""; var time = "" }

/// 목록 한 줄: 이름, 안 읽은 수, 마지막 메시지 미리보기와 시간.
/// 미리보기는 방을 열지 않고 엿볼 수 있게 읽는다 (목록에서 읽는 건 읽음 처리되지 않는다).
func room(_ row: AXUIElement) -> Room? {
  guard let cell = kids(row).first else { return nil }
  var name = "", unread = 0, last = "", time = ""
  for k in kids(cell) {
    let n = node(k)
    if n.role == "AXScrollArea" { last = kids(n.el).first.flatMap { str($0, "AXValue") } ?? "" }
    guard n.role == "AXStaticText" else { continue }
    if n.id == "_NS:40" { name = n.value }
    if n.id == "_NS:69" { time = n.value }
    if n.id.isEmpty, let u = Int(n.value) { unread = u }
  }
  return name.isEmpty ? nil : Room(name: name, unread: unread, last: last, time: time)
}

/// 이름만 필요할 때: 이름 칸을 찾는 즉시 멈춘다
func rowName(_ row: AXUIElement) -> String? {
  guard let cell = kids(row).first else { return nil }
  for k in kids(cell) {
    let n = node(k)
    if n.role == "AXStaticText" && n.id == "_NS:40" { return n.value }
  }
  return nil
}

func pressEnter() {
  for down in [true, false] {
    CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down)!.postToPid(kakao.processIdentifier)
  }
}

/// 키 입력이 다른 창으로 새지 않도록, 대상 창이 실제로 포커스를 받았는지 확인한다
func focus(_ win: AXUIElement) -> Bool {
  if same(attr(app, "AXFocusedWindow"), win) { return true }
  AXUIElementSetAttributeValue(win, "AXMain" as CFString, kCFBooleanTrue)
  AXUIElementPerformAction(win, "AXRaise" as CFString)
  for _ in 0..<10 {
    if same(attr(app, "AXFocusedWindow"), win) { return true }
    usleep(50_000)
  }
  return false
}

func close(_ win: AXUIElement) {
  if let b = attr(win, "AXCloseButton") { AXUIElementPerformAction(b as! AXUIElement, "AXPress" as CFString) }
}

/// 카톡 목록의 행은 "방"이 아니라 "위치"에 묶여 있어서, 순서가 바뀌면 다른 방을 가리킨다.
/// 그래서 여는 순간 이름으로 다시 찾고, 실제로 선택된 행이 그 방인지 확인한 뒤에만 Enter를 누른다.
/// hint: 그 방이 있을 법한 위치 (먼저 확인해서 전체 훑기를 피한다)
func open(_ name: String, hint: Int?) -> AXUIElement? {
  if let w = roomWindow(name) { return w }
  guard let main = mainWindow(), focus(main), let table = mainTable() else { return nil }
  let rows = mainRows()
  var order = Array(rows.indices)
  if let hint, rows.indices.contains(hint) { order.insert(hint, at: 0) }
  guard let i = order.first(where: { rowName(rows[$0]) == name }) else { return nil }
  let row = rows[i]
  AXUIElementSetAttributeValue(row, "AXSelected" as CFString, kCFBooleanTrue)
  usleep(80_000)
  let selected = attr(table, "AXSelectedRows") as? [AXUIElement] ?? []
  guard selected.count == 1, same(selected[0], row), rowName(row) == name,
        same(attr(app, "AXFocusedWindow"), main) else { return nil }
  let before = Set(windows().map(\.title))
  pressEnter()
  for _ in 0..<30 {
    usleep(100_000)
    if let w = roomWindow(name) { return w }
  }
  // 엉뚱한 방이 열렸으면 닫는다
  for w in windows() where w.id == "_NS:443" && !before.contains(w.title) { close(w.el) }
  return nil
}

// MARK: - 채팅방 창 위치
// 사용자가 옮겨 둔 위치를 기억한다. 저장된 위치가 없으면 카톡 메인 창 옆에 붙인다.

let positionFile = configDir.appendingPathComponent("window-position")

func savedPosition() -> CGPoint? {
  guard let text = try? String(contentsOf: positionFile, encoding: .utf8) else { return nil }
  let parts = text.split(separator: " ").compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
  return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
}

/// nunchi가 연 창을 닫기 직전에 위치를 저장한다
func rememberPosition(_ win: AXUIElement) {
  let p = node(win).frame.origin
  guard p != .zero else { return }
  try? FileManager.default.createDirectory(at: positionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
  try? "\(Int(p.x)) \(Int(p.y))".write(to: positionFile, atomically: true, encoding: .utf8)
}

func move(_ win: AXUIElement, to p: CGPoint) {
  var p = p
  if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(win, "AXPosition" as CFString, v) }
}

func placeRoomWindow(_ win: AXUIElement) {
  if let p = savedPosition() { move(win, to: p); return }
  guard let main = mainWindow() else { return }
  let m = node(main).frame, size = node(win).frame.size
  let maxX = NSScreen.screens.map(\.frame.maxX).max() ?? m.maxX
  // 오른쪽에 자리가 있으면 오른쪽, 없으면 왼쪽
  let x = m.maxX + 8 + size.width <= maxX ? m.maxX + 8 : m.minX - 8 - size.width
  move(win, to: CGPoint(x: x, y: m.minY))
}

/// nunchi가 연 창이면 위치를 기억하고 닫는다. 사용자가 직접 열어 둔 창은 건드리지 않는다.
func closeOurs(_ win: AXUIElement, _ ours: Bool) {
  guard ours else { return }
  rememberPosition(win)
  close(win)
}

// MARK: - 메시지

struct Message: Equatable { let sender: String; var time: String; let body: String; let mine: Bool; var unread = 0 }

/// 같은 메시지인지. 맨 위 행은 앞사람 이름이 잘려 이름이 비어 있을 수 있어 이름은 느슨하게 비교한다.
func sameMessage(_ a: Message, _ b: Message) -> Bool {
  // 카톡이 행을 다시 불러오는 순간엔 묶음의 마지막 행이 빠져 시간이 비어 있을 수 있다. 빈 시간은 아무 시간과도 맞는다.
  (a.time == b.time || a.time.isEmpty || b.time.isEmpty) && a.body == b.body && a.mine == b.mine
    && (a.sender == b.sender || a.sender.isEmpty || b.sender.isEmpty)
}

/// 겹치는 메시지는 새 값을 쓰되(안 읽은 수 갱신), 새 쪽에 빠진 시간·이름은 이전 값으로 채운다
func combine(_ old: Message, _ new: Message) -> Message {
  Message(sender: new.sender.isEmpty ? old.sender : new.sender, time: new.time.isEmpty ? old.time : new.time,
          body: new.body, mine: new.mine, unread: new.unread)
}

/// 카톡은 화면 근처의 메시지만 내주고 그 범위가 수시로 바뀐다.
/// 그래서 새로 읽은 목록으로 바꿔치지 않고, 이전 목록의 끝과 겹치는 곳을 찾아 이어 붙인다.
func merge(_ old: [Message], _ new: [Message]) -> [Message] {
  if old.isEmpty { return new }
  if new.isEmpty { return old }
  // old[i...]가 new의 앞부분과 같아지는 가장 앞의 i (겹침이 가장 긴 곳)
  for i in max(0, old.count - new.count)..<old.count {
    let tail = old[i...]
    if zip(tail, new).allSatisfy(sameMessage) {
      let overlap = zip(tail, new).map(combine)
      return Array((Array(old[..<i]) + overlap + Array(new.dropFirst(overlap.count))).suffix(500))
    }
  }
  // new가 old 안에 통째로 들어 있으면(범위가 위로 밀린 경우) 그대로 둔다
  if let first = new.first, let j = old.firstIndex(where: { sameMessage($0, first) }),
     j + new.count <= old.count, zip(old[j...], new).allSatisfy(sameMessage) { return old }
  // 겹치는 곳이 없는데 새 목록이 훨씬 작으면 카톡이 행을 다시 불러오는 중인 것이다. 이전 대화를 버리지 않는다.
  if new.count < old.count / 2 { return old }
  return new
}

// 24시간제 "11:58"과 12시간제 "오후 3:05", "3:05 PM"을 모두 시간으로 본다.
// macOS는 "3:05 PM" 사이에 일반 공백 대신 좁은 공백(U+202F)을 넣기도 한다.
let timePattern = try! NSRegularExpression(
  pattern: "^(?:(?:오전|오후|AM|PM|am|pm)[\\s\\u00A0\\u202F]?)?\\d{1,2}:\\d{2}(?:[\\s\\u00A0\\u202F]?(?:AM|PM|am|pm))?$")
func isTime(_ s: String) -> Bool { timePattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

func chatRows(_ win: AXUIElement) -> [AXUIElement] {
  guard let scroll = kids(win).first(where: { role($0) == "AXScrollArea" }),
        let table = kids(scroll).first(where: { role($0) == "AXTable" }) else { return [] }
  return attr(table, "AXRows") as? [AXUIElement] ?? []
}

/// 대화가 바뀌었는지 싸게 확인하기 위한 값: 행 개수 + 마지막 행 내용
func chatSignature(_ rows: [AXUIElement]) -> String {
  guard let last = rows.last, let cell = kids(last).first else { return "\(rows.count)" }
  return "\(rows.count)|" + kids(cell).map { node($0).value }.joined(separator: "|")
}

func messages(_ win: AXUIElement) -> [Message] { messages(rows: chatRows(win)) }

func messages(rows: [AXUIElement]) -> [Message] {
  var result: [Message] = []
  var lastSender = ""
  for row in rows {
    guard let cellEl = kids(row).first else { continue }
    let items = kids(cellEl).map(node)
    var time = "", bodies: [String] = [], bodyFrame: CGRect?, hasImage = false, unread = 0
    var profile: CGRect?, texts: [Node] = []
    for n in items {
      switch n.role {
      case "AXStaticText":
        // 아직 안 읽은 사람이 있으면 "8\n11:58"처럼 안 읽은 수가 시간 앞에 붙는다
        let lines = n.value.split(separator: "\n").map(String.init)
        let last = lines.last ?? ""
        if isTime(last) {
          time = last
          if lines.count > 1, let u = Int(lines[0]) { unread = u }
        } else if let u = Int(n.value) {
          unread = u   // 시간 없이 숫자만 따로 붙는 경우 (사진 등)
        } else if !n.value.isEmpty {
          texts.append(n)
        }
      case "AXTextArea":
        bodies.append(n.value); bodyFrame = bodyFrame ?? n.frame
      case "AXScrollArea":
        bodies.append(contentsOf: kids(n.el).compactMap { str($0, "AXValue") }.filter { !$0.isEmpty })
        bodyFrame = bodyFrame ?? n.frame
      case "AXImage":
        hasImage = true; bodyFrame = bodyFrame ?? n.frame
      case "AXButton":
        if n.desc == "프로필" { profile = n.frame }
      default: break
      }
    }
    // 보낸 사람 이름은 프로필 사진 바로 오른쪽 위에 있는 글자뿐이다.
    // 그 밖의 글자(답장 표시 등)는 이름으로 오인하지 않도록 본문 앞에 붙인다.
    let nameNode = profile.flatMap { p in
      texts.first { abs($0.frame.minX - p.maxX) < 30 && abs($0.frame.minY - p.minY) < 25 }
    }
    let sender = nameNode?.value ?? ""
    let extras = texts.filter { $0.el != nameNode?.el }.map(\.value)
    bodies.insert(contentsOf: extras, at: 0)
    let hasProfile = profile != nil
    // 같은 사람이 같은 분에 연달아 보낸 메시지는 마지막 것에만 시간이 붙는다.
    // 그래서 시간이 없어도 말풍선(글·사진)이 있으면 메시지로 보고, 날짜 구분선처럼 말풍선이 없는 행만 건너뛴다.
    if time.isEmpty && bodyFrame == nil { continue }
    var body = bodies.joined(separator: "\n")
    if body.isEmpty { body = hasImage ? "[사진/이모티콘]" : "[첨부]" }
    // 내 메시지는 오른쪽 정렬: 말풍선 오른쪽 끝이 셀 오른쪽 끝에 붙어 있다
    let cellFrame = node(cellEl).frame
    let mine = !hasProfile && sender.isEmpty && bodyFrame.map { cellFrame.maxX - $0.maxX < 40 } == true
    if !sender.isEmpty { lastSender = sender }
    result.append(Message(sender: mine ? "나" : (sender.isEmpty ? lastSender : sender), time: time, body: body, mine: mine, unread: unread))
  }
  // 시간이 빠진 메시지에는 같은 묶음의 마지막 메시지 시간을 붙인다
  var carry = ""
  for i in result.indices.reversed() {
    if result[i].time.isEmpty { result[i].time = carry } else { carry = result[i].time }
  }
  return result
}

/// AXValue를 직접 바꾸면 카톡이 입력을 인식하지 못하므로, 실제 타이핑과 같은 키 이벤트로 넣는다
func type(_ text: String) {
  let units = Array(text.utf16)
  for start in stride(from: 0, to: units.count, by: 20) {
    let chunk = Array(units[start..<min(start + 20, units.count)])
    for down in [true, false] {
      let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)!
      e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
      e.postToPid(kakao.processIdentifier)
    }
    usleep(20_000)
  }
}

enum SendError: Error { case noInput, noFocus, notTyped, notSent }


/// 입력창은 창 바로 아래 스크롤 영역 안에 있다. 창 전체를 훑으면 대화 행을 전부 지나가서 느리다.
var inputCache: (win: AXUIElement, input: AXUIElement)?
func inputField(_ win: AXUIElement) -> AXUIElement? {
  if let c = inputCache, CFEqual(c.win, win), role(c.input) == "AXTextArea" { return c.input }
  for k in kids(win) where role(k) == "AXScrollArea" {
    if let t = kids(k).first, str(t, "AXDescription") == "메시지 입력" {
      inputCache = (win, t)
      return t
    }
  }
  return nil
}

func pressKey(_ code: CGKeyCode) {
  for down in [true, false] {
    CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!.postToPid(kakao.processIdentifier)
  }
}

// MARK: - 언급(@)
// 카톡은 입력창에 "@"를 치면 입력창 위에 방 사람 목록(_NS:8)을 띄우고, 이어 친 글자로 목록을 거른다.
// 목록이 떠 있을 때 Enter는 전송이 아니라 "선택"이다.

let mentionPattern = try! NSRegularExpression(pattern: "(?:^|(?<=\\s))@(\\S+)")

/// 글을 일반 글자와 "@이름" 조각으로 나눈다. (이메일 같은 a@b는 언급으로 보지 않는다)
enum Piece { case text(String), mention(String) }
func pieces(_ text: String) -> [Piece] {
  var out: [Piece] = [], last = text.startIndex
  for m in mentionPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
    guard let whole = Range(m.range, in: text), let q = Range(m.range(at: 1), in: text) else { continue }
    if last < whole.lowerBound { out.append(.text(String(text[last..<whole.lowerBound]))) }
    out.append(.mention(String(text[q])))
    last = whole.upperBound
  }
  if last < text.endIndex { out.append(.text(String(text[last...]))) }
  return out
}

func mentionPopup(_ win: AXUIElement) -> AXUIElement? {
  kids(win).first { str($0, "AXIdentifier") == "_NS:8" }
}
func mentionRows(_ popup: AXUIElement) -> (table: AXUIElement, rows: [AXUIElement])? {
  guard let table = kids(popup).first(where: { role($0) == "AXTable" }) else { return nil }
  return (table, attr(table, "AXRows") as? [AXUIElement] ?? [])
}
func memberName(_ row: AXUIElement) -> String {
  guard let cell = kids(row).first else { return "" }
  return kids(cell).map(node).first { $0.id == "_NS:17" }?.value ?? ""
}

/// "@이름"을 쳐서 목록을 띄우고, 맞는 사람을 골라 Enter로 넣는다.
/// 목록이 안 뜨거나 맞는 사람이 없으면 Enter를 누르지 않고 목록만 닫는다 (글자는 그대로 남는다).
/// 카톡은 언급을 이름표 문자(U+FFFC) + 공백으로 넣는다. 넣었으면 true.
@discardableResult
func typeMention(_ win: AXUIElement, _ query: String) -> Bool {
  // "@"와 이름을 한 번에 치면 카톡이 목록을 띄우지 않는다. "@"를 먼저 치고 목록이 뜬 뒤 이름을 친다.
  type("@")
  var popup: AXUIElement?
  for _ in 0..<15 {
    usleep(50_000)
    if let p = mentionPopup(win) { popup = p; break }
  }
  guard popup != nil else { type(query); return false }
  type(query)
  usleep(250_000)   // 목록이 이름으로 걸러질 때까지
  guard let popup = mentionPopup(win), let (table, rows) = mentionRows(popup), !rows.isEmpty else {
    if mentionPopup(win) != nil { pressKey(53) }; return false
  }
  let names = rows.map(memberName)
  guard let i = names.firstIndex(where: { $0.hasPrefix(query) }) ?? names.firstIndex(where: { $0.contains(query) }) else {
    pressKey(53)   // Esc: 목록만 닫기
    return false
  }
  AXUIElementSetAttributeValue(rows[i], "AXSelected" as CFString, kCFBooleanTrue)
  usleep(80_000)
  guard let sel = (attr(table, "AXSelectedRows") as? [AXUIElement])?.first, CFEqual(sel, rows[i]),
        mentionPopup(win) != nil else {
    pressKey(53); return false
  }
  let before = chips(win)
  pressEnter()   // 목록이 떠 있으므로 전송이 아니라 선택
  for _ in 0..<10 { usleep(50_000); if mentionPopup(win) == nil { break } }
  return chips(win) > before
}

/// 입력창에 들어간 언급 이름표 개수
func chips(_ win: AXUIElement) -> Int {
  (inputField(win).flatMap { str($0, "AXValue") } ?? "").unicodeScalars.filter { $0.value == 0xFFFC }.count
}

func send(_ win: AXUIElement, _ text: String) throws {
  guard let input = inputField(win) else { throw SendError.noInput }
  guard focus(win) else { throw SendError.noFocus }
  AXUIElementSetAttributeValue(input, "AXFocused" as CFString, kCFBooleanTrue)
  usleep(50_000)
  guard same(attr(app, "AXFocusedUIElement"), input) else { throw SendError.noFocus }
  // 입력창에 남아 있던 글은 비우고 시작한다
  AXUIElementSetAttributeValue(input, "AXValue" as CFString, "" as CFString)
  let parts = pieces(text)
  let hasMention = parts.contains { if case .mention = $0 { true } else { false } }
  var afterChip = false
  for part in parts {
    switch part {
    case .text(let t):
      // 카톡이 이름표 뒤에 공백을 이미 붙였으므로 겹치는 공백 하나를 뺀다
      type(afterChip && t.hasPrefix(" ") ? String(t.dropFirst()) : t)
      afterChip = false
    case .mention(let q):
      afterChip = typeMention(win, q)
    }
  }
  usleep(50_000)
  let typed = str(input, "AXValue") ?? ""
  // 언급이 들어가면 입력창 글자가 카톡 형식으로 바뀌므로 비어 있지 않은지만 본다
  guard hasMention ? !typed.isEmpty : typed == text else { throw SendError.notTyped }
  // 마지막 Enter가 전송이 되도록, 혹시 떠 있는 언급 목록은 닫는다
  if mentionPopup(win) != nil { pressKey(53); usleep(100_000) }
  guard mentionPopup(win) == nil else { throw SendError.notTyped }
  if ProcessInfo.processInfo.environment["KT_NO_ENTER"] != nil { return }
  pressEnter()
  for _ in 0..<20 {
    usleep(50_000)
    if str(input, "AXValue")?.isEmpty == true { return }
  }
  throw SendError.notSent
}

// MARK: - 문자 폭 (한글·이모지는 터미널에서 2칸)

func width(_ c: Character) -> Int {
  guard let s = c.unicodeScalars.first else { return 0 }
  if c.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) { return 2 }
  // ❤️ ✔️ 1️⃣ 처럼 이모지 변형 기호(U+FE0F)나 키캡(U+20E3)이 붙으면 터미널은 2칸으로 그린다
  if c.unicodeScalars.contains(where: { $0.value == 0xFE0F || $0.value == 0x20E3 }) { return 2 }
  switch s.value {
  case 0..<0x20, 0x7F: return 0
  case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
       0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1FAFF, 0x20000...0x3FFFD:
    return 2
  default: return 1
  }
}
func width(_ s: String) -> Int { s.reduce(0) { $0 + width($1) } }

/// 폭 w에 맞춰 자르고 남는 칸은 공백으로 채운다
func fit(_ s: String, _ w: Int) -> String {
  var out = "", used = 0
  for c in s where c != "\n" && c != "\t" {
    let cw = width(c)
    if used + cw > w { break }
    out.append(c); used += cw
  }
  return out + String(repeating: " ", count: max(0, w - used))
}

/// 폭 w에 맞춰 여러 줄로 감싼다
func wrap(_ s: String, _ w: Int) -> [String] {
  var lines: [String] = []
  for para in s.split(separator: "\n", omittingEmptySubsequences: false) {
    var line = "", used = 0
    for c in para {
      let cw = width(c)
      if used + cw > w { lines.append(line); line = ""; used = 0 }
      line.append(c); used += cw
    }
    lines.append(line)
  }
  return lines
}

// MARK: - 터미널

var original = termios()
func rawMode() {
  tcgetattr(STDIN_FILENO, &original)
  var raw = original
  raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
  raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
  tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
  out("\u{1B}[?1049h\u{1B}[?25h")
}
func restore() {
  tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
  out("\u{1B}[?1049l")
}
func out(_ s: String) { FileHandle.standardOutput.write(s.data(using: .utf8)!) }
var fixedSize: (rows: Int, cols: Int)?   // 데모처럼 터미널 크기와 상관없이 그릴 때
func termSize() -> (rows: Int, cols: Int) {
  if let fixedSize { return fixedSize }
  var ws = winsize()
  _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws)
  return (max(Int(ws.ws_row), 10), max(Int(ws.ws_col), 60))
}
func quit() -> Never { restore(); exit(0) }
signal(SIGTERM) { _ in quit() }

// MARK: - 상태
// 카톡 AX 작업은 전부 ax 큐 하나에서 차례로 돌리고, 화면·키 입력은 메인 스레드가 맡는다.
// 공유 상태는 lock으로 보호한다.

let ax = DispatchQueue(label: "nunchi.ax")
let lock = NSLock()
func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

var roomList: [Room] = []
var nameIndex: [String] = []         // 전체 방 이름 (위치 순). 새로고침마다 조금씩 채운다
var cursor = 0                       // 왼쪽 목록에서 선택된 위치
var currentName: String?             // 열려 있는 방 이름
var currentWin: AXUIElement?
var openedByUs = false               // 사용자가 직접 열어 둔 창은 닫지 않는다
var chat: [Message] = []
var inputBuf: [Character] = []
var status = ""
var busy = false                     // 방 열기·전송 중
var dirty = true                     // 다시 그려야 함
var showHelp = false                 // "/?"로 연 단축키 목록
var newVersion: String?             // GitHub에 더 새 버전이 있으면 그 번호
var lastInputAt = Date()             // 마지막 키 입력 시각 (자동 닫기용)
/// 이 시간 동안 키 입력이 없으면 방을 닫는다. 열어 두면 카톡이 새 메시지를 계속 읽음 처리하기 때문.
/// NUNCHI_IDLE=초 로 바꿀 수 있고 0이면 끈다.
let idleSeconds = Double(ProcessInfo.processInfo.environment["NUNCHI_IDLE"] ?? "") ?? 120
var scrollBack = 0                   // 대화 칸을 맨 아래에서 몇 줄 위로 올려 보고 있는지
var lastChatLines = 0                // 직전에 그린 대화 줄 수 (새 메시지가 와도 보던 위치를 유지하려고)
var newBelow = false                 // 올려 보는 동안 아래에 새 메시지가 왔는지
var listRows = 30                    // 왼쪽 목록에 보이는 줄 수

func setStatus(_ s: String) { locked { status = s; dirty = true } }

// MARK: - 백그라운드 새로고침 (ax 큐)

var indexCursor = 0
var nextIndexPass = Date.distantPast
var listSig = "", chatSig = "", lastLimit = 0
var nextFullList = Date.distantPast

/// 바뀐 게 있을 때만 다시 읽는다. 카톡 AX가 느려서 매번 전부 읽으면 몇 초씩 걸린다.
func refreshOnce() {
  let (win, limit) = locked { (currentWin, listRows) }
  if let win {
    if alive(win) {
      let rows = chatRows(win)
      let sig = chatSignature(rows)
      if sig != chatSig {
        let msgs = messages(rows: rows)
        chatSig = sig
        locked { if let cw = currentWin, CFEqual(cw, win) { chat = merge(chat, msgs); dirty = true } }
      }
    } else {
      locked {
        if let cw = currentWin, CFEqual(cw, win) {
          currentWin = nil; currentName = nil; chat = []
          status = "카톡에서 채팅방 창이 닫혔습니다."; dirty = true
        }
      }
    }
  }

  let rows = mainRows()
  let sig = "\(unreadTotal())|\(rows.count)|\(rows.first.flatMap(rowName) ?? "")"
  var names = locked { nameIndex }
  if names.count != rows.count { names = Array(repeating: "", count: rows.count) }
  var list: [Room]?
  let scanned = min(limit, rows.count)
  if sig != listSig || limit != lastLimit || Date() > nextFullList {
    var fresh: [Room] = []
    for (i, row) in rows.prefix(limit).enumerated() {
      guard let r = room(row) else { continue }
      names[i] = r.name
      fresh.append(r)
    }
    list = fresh
    listSig = sig; lastLimit = limit
    nextFullList = Date().addingTimeInterval(15)
  }
  // 목록 밖의 이름은 한 번에 30줄씩 훑어 둔다 (/검색용). 한 바퀴 돌면 60초 쉰다.
  if rows.count > scanned, Date() > nextIndexPass {
    if indexCursor < scanned { indexCursor = scanned }
    for i in indexCursor..<min(indexCursor + 30, rows.count) { names[i] = rowName(rows[i]) ?? "" }
    indexCursor += 30
    if indexCursor >= rows.count { indexCursor = scanned; nextIndexPass = Date().addingTimeInterval(60) }
  }
  locked {
    nameIndex = names
    guard let list else { return }
    let selected = roomList.indices.contains(cursor) ? roomList[cursor].name : nil
    roomList = list
    if let selected, let i = roomList.firstIndex(where: { $0.name == selected }) { cursor = i }
    cursor = min(cursor, max(roomList.count - 1, 0))
    dirty = true
  }
}

/// 새로고침을 곧 한 번 하도록 예약한다. 알림이 몰려와도 한 번만 돈다.
var pokePending = false
func poke() {
  let should = locked { () -> Bool in if pokePending { return false }; pokePending = true; return true }
  guard should else { return }
  ax.asyncAfter(deadline: .now() + 0.15) {
    locked { pokePending = false }
    refreshOnce()
  }
}

/// 카톡이 보내는 변경 알림(글자·행 개수·창)을 받아 바로 새로고침한다. 별도 스레드의 런루프에서 돈다.
// C 콜백은 바깥 변수를 붙잡을 수 없어서, 할 일을 refcon 포인터로 넘긴다
final class Hook { let fire: () -> Void; init(_ f: @escaping () -> Void) { fire = f } }
let hook = Hook { poke() }
func startObserver() {
  Thread {
    var observer: AXObserver?
    let callback: AXObserverCallback = { _, _, _, refcon in
      Unmanaged<Hook>.fromOpaque(refcon!).takeUnretainedValue().fire()
    }
    guard AXObserverCreate(kakao.processIdentifier, callback, &observer) == .success,
          let observer else { return }
    let refcon = Unmanaged.passUnretained(hook).toOpaque()
    for n in ["AXValueChanged", "AXRowCountChanged", "AXWindowCreated", "AXTitleChanged"] {
      AXObserverAddNotification(observer, app, n as CFString, refcon)
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
    CFRunLoopRun()
  }.start()
}

/// 알림을 놓칠 때를 대비한 주기 새로고침
func scheduleRefresh() {
  ax.asyncAfter(deadline: .now() + 3) {
    refreshOnce()
    scheduleRefresh()
  }
}

// MARK: - 동작 (ax 큐에서 실행)

func openRoom(_ name: String) {
  let (prev, prevOurs, hint) = locked { () -> (AXUIElement?, Bool, Int?) in
    if name == currentName { return (nil, false, -1) }
    busy = true; status = "\(name) 여는 중…"; dirty = true
    return (currentWin, openedByUs, nameIndex.firstIndex(of: name))
  }
  if hint == -1 { return }
  if let prev { closeOurs(prev, prevOurs) }
  locked { currentWin = nil; currentName = nil; chat = [] }
  let existed = roomWindow(name) != nil
  guard let win = open(name, hint: hint) else {
    locked { busy = false; status = "\(name) 방을 열지 못했습니다. 카톡이 키 입력을 안 받는 상태일 수 있어요. 카톡 창을 한 번 클릭하고 돌아와서 다시 시도해 주세요."; dirty = true }
    return
  }
  if !existed { placeRoomWindow(win) }
  let msgs = messages(win)
  locked {
    currentWin = win; currentName = name; openedByUs = !existed
    scrollBack = 0; lastChatLines = 0; newBelow = false
    chat = msgs; busy = false; status = ""; dirty = true
    if let i = roomList.firstIndex(where: { $0.name == name }) { cursor = i }
  }
  chatSig = ""; listSig = ""
}

/// "/이름"으로 전체 목록에서 방을 찾아 연다
func search(_ query: String) {
  func matches(_ names: [String]) -> [String] {
    var seen = Set<String>()
    return names.filter { !$0.isEmpty && $0.localizedCaseInsensitiveContains(query) && seen.insert($0).inserted }
  }
  var hits = matches(locked { nameIndex + roomList.map(\.name) })
  // 이름 캐시가 아직 덜 찼으면 비어 있는 칸만 그 자리에서 훑는다 (몇 초 걸릴 수 있다)
  if hits.isEmpty, locked({ nameIndex.contains("") || nameIndex.isEmpty }) {
    setStatus("'\(query)' 찾는 중…")
    let rows = mainRows()
    var names = locked { nameIndex }
    if names.count != rows.count { names = Array(repeating: "", count: rows.count) }
    for i in rows.indices where names[i].isEmpty { names[i] = rowName(rows[i]) ?? "" }
    locked { nameIndex = names }
    hits = matches(names)
  }
  if let exact = hits.first(where: { $0 == query }) ?? (hits.count == 1 ? hits[0] : nil) {
    openRoom(exact)
  } else if hits.isEmpty {
    setStatus("'\(query)'와 일치하는 방이 없습니다.")
  } else {
    setStatus("여러 개가 일치합니다: " + hits.prefix(4).joined(separator: ", "))
  }
}

func submit(_ text: String) {
  guard let win = locked({ currentWin }) else {
    locked { status = "열린 방이 없어 보내지 못했습니다."; if inputBuf.isEmpty { inputBuf = Array(text) }; dirty = true }
    return
  }
  setStatus("전송 중…")
  do {
    try send(win, text)
    setStatus("")
    chatSig = ""; listSig = ""
    poke()
  } catch {
    let reason = switch error as? SendError {
      case .noInput: "입력창을 찾지 못했습니다."
      case .noFocus: "채팅방 창에 포커스를 줄 수 없습니다."
      case .notTyped: "입력창에 글자가 제대로 들어가지 않았습니다."
      default: "Enter를 눌렀지만 전송되지 않았습니다. 카톡 창을 한 번 클릭하고 돌아와서 다시 시도해 주세요."
    }
    locked {
      status = "전송 실패: " + reason; dirty = true
      if inputBuf.isEmpty { inputBuf = Array(text) }   // 보내려던 글을 되돌려 놓는다
    }
  }
}

/// Ctrl+O: 터미널에 가려진 채팅방 창을 맨 앞으로 가져온다
func bringToFront() {
  guard let win = locked({ currentWin }) else { setStatus("열린 방이 없습니다."); return }
  AXUIElementPerformAction(win, "AXRaise" as CFString)
  kakao.activate()
}

func shutdown() -> Never {
  let (win, ours) = locked { (currentWin, openedByUs) }
  if let win { closeOurs(win, ours) }
  quit()
}

/// Ctrl+W: 채팅방 창을 닫아 더 이상 읽음 처리되지 않게 한다
/// Esc·Ctrl+W: 화면에서는 바로 닫고, 카톡 창 닫기는 ax 큐에 맡긴다.
/// (ax 큐가 새로고침 중이면 닫기가 1~2초 늦어져 Esc를 두 번 누르게 된다)
func closeRoom() {
  let target = locked { () -> (AXUIElement, Bool)? in
    if busy { status = "방을 여는 중입니다. 잠시 뒤에 닫아 주세요."; dirty = true; return nil }
    guard let win = currentWin else { status = "열린 방이 없습니다."; dirty = true; return nil }
    let ours = openedByUs
    currentWin = nil; currentName = nil; chat = []
    scrollBack = 0; lastChatLines = 0; newBelow = false
    status = ours ? "방을 닫았습니다. 이제 새 메시지가 읽음 처리되지 않습니다." : "직접 열어 둔 창이라 닫지 않고 연결만 끊었습니다."
    dirty = true
    return (win, ours)
  }
  if let (win, ours) = target, ours { ax.async { closeOurs(win, true) } }
}

/// 입력줄 마지막 단어가 "@…"이면 그 뒤 글자로 대화에 나온 사람 이름 후보를 찾는다 (lock 안에서 호출)
func mentionCandidates() -> (query: String, names: [String])? {
  let text = String(inputBuf)
  guard let word = text.split(separator: " ", omittingEmptySubsequences: false).last, word.hasPrefix("@") else { return nil }
  let q = String(word.dropFirst())
  var seen = Set<String>()
  let names = chat.reversed().compactMap { m -> String? in
    guard !m.mine, !m.sender.isEmpty, seen.insert(m.sender).inserted else { return nil }
    return q.isEmpty || m.sender.contains(q) ? m.sender : nil
  }
  return (q, names)
}

// MARK: - 그리기 (메인 스레드, lock 안에서 호출)

func draw() {
  let (rows, cols) = termSize()
  let leftW = min(30, cols / 3)
  let rightW = cols - leftW - 3
  let bodyH = rows - 3      // 헤더 1줄 + 입력 구분선 1줄 + 입력 1줄
  listRows = bodyH

  // 왼쪽: 채팅방 목록 (선택 위치가 보이도록 스크롤)
  let top = max(0, min(cursor - bodyH / 2, roomList.count - bodyH))
  var left: [String] = []
  for i in top..<min(top + bodyH, roomList.count) {
    let r = roomList[i]
    let badge = r.unread > 0 ? " \(r.unread > 99 ? "99+" : String(r.unread))" : ""
    let name = fit(r.name, leftW - 2 - width(badge))
    let marker = r.name == currentName ? "\(orange)▍\(reset)" : " "
    if i == cursor {
      left.append("\(marker)\u{1B}[7m \(name)\(badge)\(reset)")
    } else if r.unread > 0 {
      left.append("\(marker) \(bold)\(name)\(reset)\(orange)\(badge)\(reset)")
    } else {
      left.append("\(marker) \(name)")
    }
  }
  if roomList.isEmpty { left = [" \(dim)\(fit("목록 읽는 중…", leftW - 1))\(reset)"] }

  // 오른쪽: 대화 (아래쪽 정렬)
  var right: [String] = []
  for m in chat {
    let unread = m.unread > 0 ? " \(yellow)\(m.unread)\(reset)" : ""
    if m.mine {
      right.append("\(cyan)❯\(reset) \(bold)나\(reset) \(dim)\(m.time)\(reset)\(unread)")
      for l in wrap(m.body, rightW - 2) { right.append("  \(cyan)\(fit(l, rightW - 2))\(reset)") }
    } else {
      right.append("\(orange)⏺\(reset) \(bold)\(m.sender)\(reset) \(dim)\(m.time)\(reset)\(unread)")
      for l in wrap(m.body, rightW - 2) { right.append("  \(fit(l, rightW - 2))") }
    }
  }
  let helpScreen = showHelp || currentName == nil
  if helpScreen {
    right = helpLines()
    // 방을 열기 전에는 고른 방의 마지막 메시지를 엿보기로 보여준다
    if !showHelp, roomList.indices.contains(cursor) {
      let r = roomList[cursor]
      var peek = ["", "  \(bold)\(r.name)\(reset) \(dim)\(r.time) · 마지막 메시지 (열지 않아 읽음 처리 안 됨)\(reset)"]
      peek += wrap(r.last.isEmpty ? "(미리보기 없음)" : r.last, rightW - 4).prefix(4).map { "  \($0)" }
      peek += ["  \(dim)Enter로 방 열기\(reset)", "  \(dim)\(String(repeating: "─", count: max(0, rightW - 4)))\(reset)"]
      right = peek + right.dropFirst()
    }
  }
  // 위로 올려 보는 중이면 새 줄이 생긴 만큼 같이 올려서 보던 위치를 유지한다
  if !helpScreen {
    if scrollBack > 0, right.count > lastChatLines, lastChatLines > 0 {
      scrollBack += right.count - lastChatLines
      newBelow = true
    }
    lastChatLines = right.count
    scrollBack = min(scrollBack, max(0, right.count - bodyH))
    if scrollBack == 0 { newBelow = false }
    right = Array(right.dropLast(scrollBack).suffix(bodyH))
    right = Array(repeating: "", count: bodyH - right.count) + right
  } else {
    right = Array(right.prefix(bodyH))   // 단축키 목록은 위에서부터 보여준다
  }

  var s = "\u{1B}[H"
  var title = currentName.map { "\(bold)\($0)\(reset)" } ?? "\(dim)nunchi\(reset)"
  if let v = newVersion { title += "  \(yellow)새 버전 v\(v) 있음 · nunchi --update\(reset)" }
  s += "\(dim)\(fit(" sessions", leftW))\(reset) │ \(title)\u{1B}[K\r\n"
  for i in 0..<bodyH {
    let l = i < left.count ? left[i] : String(repeating: " ", count: leftW)
    let r = i < right.count ? right[i] : ""
    s += "\(l)\(reset) \(dim)│\(reset) \(r)\u{1B}[K\r\n"
  }
  let mention = mentionCandidates().map { c in
    c.names.isEmpty ? "@\(c.query): 대화에 나온 사람 중 일치 없음 (보낼 때 카톡 목록에서 찾음)" : "Tab → " + c.names.prefix(5).joined(separator: ", ")
  }
  let scrolled = scrollBack > 0 ? "↑ \(scrollBack)줄 위를 보는 중 · End 맨 아래로" + (newBelow ? " · 새 메시지 있음" : "") : nil
  let idleLeft = idleSeconds - Date().timeIntervalSince(lastInputAt)
  let idleHint = currentName != nil && idleSeconds > 0 && idleLeft <= 20 && idleLeft > 0 ? "\(Int(idleLeft.rounded(.up)))초 뒤 자동으로 방을 닫습니다 (아무 키나 누르면 유지)" : nil
  let hint = showHelp ? "아무 키나 누르면 닫힙니다" : idleHint != nil && status.isEmpty ? idleHint! : !status.isEmpty ? status : mention ?? scrolled ?? (currentName == nil ? "" : "Enter 전송 · Shift+↑↓ 스크롤 · Esc 닫기 · /? 단축키")
  s += "\(dim)\(String(repeating: "─", count: leftW + 1))┴─ \(fit(hint, rightW - 1))\(reset)\u{1B}[K\r\n"

  // 입력줄: 오른쪽 끝이 넘치면 뒷부분만 보여준다
  var shown = String(inputBuf)
  while width(shown) > cols - 4 { shown.removeFirst() }
  s += "\(cyan)❯\(reset) \(shown)\u{1B}[K"
  out(s)
  dirty = false
}

/// 단축키 목록 (방을 열기 전 첫 화면과 "/?"에서 보여준다)
func helpLines() -> [String] {
  let keys: [(String, String)] = [
    ("↑ ↓", "채팅방 고르기"),
    ("Enter (빈 입력창)", "고른 채팅방 열기"),
    ("글 입력 + Enter", "열린 채팅방으로 전송"),
    ("/이름 + Enter", "채팅방 검색해서 열기"),
    ("@이름", "언급 (Tab 자동 완성)"),
    ("Shift+↑ ↓", "대화 3줄씩 스크롤"),
    ("PageUp/Down (fn+↑↓)", "대화 반 화면씩 스크롤"),
    ("End (fn+→)", "대화 맨 아래로"),
    ("Esc", "채팅방 닫기 (읽음 처리 멈춤)"),
    ("Ctrl+O", "카톡 창 맨 앞으로 (사진 보기)"),
    ("Ctrl+U", "입력줄 지우기"),
    ("/?", "이 목록 보기"),
    ("Ctrl+C", "종료"),
  ]
  return ["", "  \(bold)단축키\(reset)", ""] + keys.map { "  \(cyan)\(fit($0.0, 22))\(reset) \($0.1)" }
}

// MARK: - 입력 처리 (메인 스레드)

var pending: [UInt8] = []

/// 터미널에서 이미 도착했거나 waitMs 안에 도착하는 입력을 읽는다
func pendingInput(waitMs: Int32) -> [UInt8] {
  var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
  guard poll(&fds, 1, waitMs) > 0 else { return [] }
  var b = [UInt8](repeating: 0, count: 256)
  let n = read(STDIN_FILENO, &b, b.count)
  return n > 0 ? Array(b[0..<n]) : []
}

func handle(_ bytes: [UInt8]) {
  locked { lastInputAt = Date() }
  // 단축키 목록은 아무 키나 누르면 닫는다 (그 키는 소비한다)
  if locked({ showHelp }) { locked { showHelp = false; dirty = true }; return }
  var i = 0
  while i < bytes.count {
    let b = bytes[i]
    switch b {
    case 3: shutdown()                                    // Ctrl+C
    case 27:
      // ESC [ … 끝글자 형태의 키 (화살표, PageUp 등)
      if i + 1 < bytes.count, bytes[i + 1] == 91 {
        var j = i + 2
        while j < bytes.count, !(0x40...0x7E).contains(bytes[j]) { j += 1 }
        guard j < bytes.count else { return }
        let seq = String(decoding: bytes[(i + 2)...j], as: UTF8.self)
        let page = max(1, (termSize().rows - 3) / 2)
        locked {
          switch seq {
          case "A": cursor = max(0, cursor - 1)                          // ↑ 방 고르기
          case "B": cursor = min(roomList.count - 1, cursor + 1)         // ↓
          case "1;2A": scrollBack += 3                                   // Shift+↑ 대화 위로
          case "1;2B": scrollBack = max(0, scrollBack - 3)               // Shift+↓
          case "5~": scrollBack += page                                  // PageUp (fn+↑)
          case "6~": scrollBack = max(0, scrollBack - page)              // PageDown (fn+↓)
          case "F", "4~", "8~": scrollBack = 0                           // End (fn+→)
          default: break
          }
          dirty = true
        }
        i = j + 1; continue
      }
      if bytes.count == 1 { closeRoom(); return }         // Esc 단독: 방 닫기
      return   // 그 밖의 ESC 시퀀스는 무시한다
    case 13:                                              // Enter
      // 한글 조합 중에 Enter를 누르면 마지막 글자가 Enter보다 늦게 올 수 있다. 잠깐 기다렸다가 먼저 넣는다.
      if i == bytes.count - 1 {
        let late = pendingInput(waitMs: 40)
        if !late.isEmpty { handle(late.filter { $0 != 13 }) }
      }
      enter()
    case 127, 8:                                          // Backspace
      locked { if !inputBuf.isEmpty { inputBuf.removeLast() } }
    case 21: locked { inputBuf = [] }                     // Ctrl+U
    case 9:                                               // Tab: @언급 자동 완성
      locked {
        guard let c = mentionCandidates(), let name = c.names.first else { return }
        // 카톡 목록은 이름 앞부분으로 거르므로 공백 앞까지만 넣는다
        let token = name.split(separator: " ").first.map(String.init) ?? name
        inputBuf.removeLast(c.query.count + 1)
        inputBuf.append(contentsOf: "@" + token + " ")
      }
    case 15: ax.async { bringToFront() }                  // Ctrl+O
    case 23: closeRoom()                                  // Ctrl+W
    default:
      if b >= 32 {
        pending.append(b)
        if let s = String(bytes: pending, encoding: .utf8) {
          locked { inputBuf.append(contentsOf: s) }; pending = []
        } else if pending.count > 4 { pending = [] }
      }
    }
    i += 1
  }
}

/// 입력창에 글이 있으면 전송, 비어 있으면 선택한 방 열기. "/이름"은 검색.
func enter() {
  let (text, selected, current, isBusy) = locked {
    (String(inputBuf).trimmingCharacters(in: .whitespaces),
     roomList.indices.contains(cursor) ? roomList[cursor].name : nil, currentName, busy)
  }
  if ["/?", "/도움말", "/help"].contains(text) {
    locked { inputBuf = []; showHelp = true; dirty = true }
    return
  }
  if isBusy, text.isEmpty || text.hasPrefix("/") { setStatus("방을 여는 중입니다. 잠시만 기다려 주세요."); return }
  if text.hasPrefix("/"), text.count > 1 {
    locked { inputBuf = [] }
    ax.async { search(String(text.dropFirst())) }
  } else if !text.isEmpty {
    guard current != nil else { setStatus("먼저 방을 열어 주세요. (입력창을 비우고 Enter)"); return }
    locked { inputBuf = [] }
    ax.async { submit(text) }
  } else if let selected, selected != current {
    ax.async { openRoom(selected) }
  }
}

// MARK: - 데모

func runDemo() -> Never {
  fixedSize = (rows: 20, cols: 96)
  roomList = [
    Room(name: "개발 스터디", unread: 0), Room(name: "김철수", unread: 2), Room(name: "주말 등산 모임", unread: 12),
    Room(name: "가족", unread: 0), Room(name: "이영희", unread: 0), Room(name: "회사 동기", unread: 5),
    Room(name: "나와의 채팅", unread: 0), Room(name: "박민수", unread: 0), Room(name: "대학 동아리", unread: 128),
    Room(name: "최지우", unread: 0), Room(name: "택배 알림", unread: 1),
  ]
  cursor = 0
  currentName = "개발 스터디"
  chat = [
    Message(sender: "김철수", time: "11:52", body: "오늘 스터디 몇 시에 시작해요?", mine: false),
    Message(sender: "이영희", time: "11:53", body: "저녁 8시요! 장소는 지난번이랑 같아요", mine: false),
    Message(sender: "나", time: "11:55", body: "저 발표 자료 거의 다 만들었어요", mine: true),
    Message(sender: "나", time: "11:55", body: "터미널에서 카톡 보내는 거 데모로 보여 드릴게요 🙂", mine: true, unread: 1),
    Message(sender: "김철수", time: "11:58", body: "오 기대된다 ㅋㅋ\n혹시 노트북 충전기 있으신 분?", mine: false, unread: 2),
  ]
  inputBuf = Array("@영희 충전기 제가 챙겨 갈게요")
  out("\u{1B}[?25l")   // 커서 숨김
  draw()
  out("\u{1B}[0m\r\n")
  exit(0)
}

// MARK: - main

if demo { runDemo() }
Thread {
  if let v = latestVersion(), isNewer(v, than: version) { locked { newVersion = v; dirty = true } }
}.start()
rawMode()
locked { draw() }
ax.async { refreshOnce() }
scheduleRefresh()
startObserver()
var buf = [UInt8](repeating: 0, count: 1024)
while true {
  var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
  if poll(&fds, 1, 100) > 0 {
    let n = read(STDIN_FILENO, &buf, buf.count)
    if n <= 0 { shutdown() }
    handle(Array(buf[0..<n]))
    locked { draw() }
  } else {
    // 입력이 한동안 없으면 방을 닫아 읽음 처리를 멈춘다
    let (open, isBusy, idle) = locked { (currentName != nil, busy, Date().timeIntervalSince(lastInputAt)) }
    if open, !isBusy, idleSeconds > 0, idle > idleSeconds {
      closeRoom()
      let span = idleSeconds >= 60 ? "\(Int(idleSeconds / 60))분" : "\(Int(idleSeconds))초"
      setStatus("\(span) 동안 입력이 없어 방을 닫았습니다. 이제 읽음 처리되지 않습니다.")
    } else if open, idleSeconds > 0, idle > idleSeconds - 21 {
      locked { dirty = true }   // 카운트다운 안내 갱신
    }
    locked { if dirty { draw() } }
  }
}
