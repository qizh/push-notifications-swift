import XCTest
@testable import PushNotifications

class UserPersistableTests: XCTestCase {

    var deviceStateStore: InstanceDeviceStateStore!

    override func setUp() {
            super.setUp()
            UserDefaults.standard.removePersistentDomain(forName: PersistenceConstants.UserDefaults.suiteName(instanceId: nil))
            self.deviceStateStore = InstanceDeviceStateStore(nil)
        }

    override func tearDown() {
            UserDefaults.standard.removePersistentDomain(forName: PersistenceConstants.UserDefaults.suiteName(instanceId: nil))
            super.tearDown()
    }

    func testPersistUserThatWasNotSavedYet() {
        let userIdNotSetYet = self.deviceStateStore.getUserId()
        XCTAssertNil(userIdNotSetYet)
        let persistenceOperation = self.deviceStateStore.setUserId(userId: "Johnny Cash")
        XCTAssertTrue(persistenceOperation)
        let userId = self.deviceStateStore.getUserId()
        XCTAssertNotNil(userId)
        XCTAssertEqual(userId, "Johnny Cash")
    }

    func testPersistUserThatIsAlreadySaved() {
        _ = self.deviceStateStore.setUserId(userId: "Johnny Cash")
        let persistenceOperation = self.deviceStateStore.setUserId(userId: "Johnny Cash")
        XCTAssertFalse(persistenceOperation)
    }

    func testPersistUserAndRemoveUser() {
        let persistenceOperation = self.deviceStateStore.setUserId(userId: "Johnny Cash")
        XCTAssertTrue(persistenceOperation)
        let userId = self.deviceStateStore.getUserId()
        XCTAssertNotNil(userId)
        XCTAssertEqual(userId, "Johnny Cash")
        self.deviceStateStore.removeUserId()
        XCTAssertNil(self.deviceStateStore.getUserId())
    }
}
