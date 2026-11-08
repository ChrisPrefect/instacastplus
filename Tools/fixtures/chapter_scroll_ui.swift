import XCTest
final class NativeScrollTests: XCTestCase {
 func testChaptersAfterBackground() {
  let app = XCUIApplication(bundleIdentifier: "com.iteconomy.instacastplus")
  app.activate()
  XCUIDevice.shared.press(.home)
  app.activate()
  let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
  let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
  for _ in 0..<5 { start.press(forDuration: 0.05, thenDragTo: end) }
  let image = XCTAttachment(screenshot: app.screenshot())
  image.lifetime = .keepAlways
  add(image)
  let finalChapter = app.staticTexts["Postshow"]
  XCTAssertTrue(finalChapter.isHittable, app.debugDescription)
  if finalChapter.isHittable { finalChapter.tap() }
 }
}
