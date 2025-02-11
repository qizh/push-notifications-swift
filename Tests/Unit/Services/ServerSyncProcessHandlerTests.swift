import OHHTTPStubs
import XCTest
#if canImport(OHHTTPStubsSwift)
import OHHTTPStubsSwift
#endif
@testable import PushNotifications

class ServerSyncProcessHandlerTests: XCTestCase {

    private let instanceId = "8a070eaa-033f-46d6-bb90-f4c15acc47e1"
    private let deviceId = "apns-8792dc3f-45ce-4fd9-ab6d-3bf731f813c6"
    private let deviceToken = "e4cea6a8b2419499c8c716bec80b705d7a5d8864adb2c69400bab9b7abe43ff1"
    private let noTokenProvider: () -> TokenProvider? = {
        return nil
    }
    private let deviceStateStore = InstanceDeviceStateStore("8a070eaa-033f-46d6-bb90-f4c15acc47e1")

    private let ignoreServerSyncEvent: (ServerSyncEvent) -> Void = { _ in
        return
    }

    override func setUp() {
        super.setUp()
        TestHelper.clearEverything(instanceId: instanceId)
    }

    override func tearDown() {
        HTTPStubs.removeAllStubs()
        TestHelper.clearEverything(instanceId: instanceId)
        super.tearDown()
    }

    func testStartJob() {
        let url = URL.PushNotifications.devices(instanceId: instanceId)!
        let exp = expectation(description: "It should successfully register the device")

        stub(condition: isMethodPOST() && isAbsoluteURLString(url.absoluteString)) { _ in
            let jsonObject: [String: Any] = [
                "id": self.deviceId
            ]

            exp.fulfill()

            return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 200, headers: nil)
        }

        let startJob: ServerSyncJob = .startJob(instanceId: instanceId, token: deviceToken)
        let serverSyncProcessHandler = ServerSyncProcessHandler(instanceId: instanceId, getTokenProvider: noTokenProvider, handleServerSyncEvent: ignoreServerSyncEvent)
        serverSyncProcessHandler.jobQueue.append(startJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: startJob)

        waitForExpectations(timeout: 1)
    }

    func testStartJobRetriesDeviceCreation() {
        let url = URL.PushNotifications.devices(instanceId: instanceId)!
        let exp = expectation(description: "It should successfully register the device")

        var numberOfAttempts = 0
        stub(condition: isMethodPOST() && isAbsoluteURLString(url.absoluteString)) { _ in
            let jsonObject: [String: Any] = [
                "description": "Something went terribly wrong"
            ]

            numberOfAttempts += 1
            if numberOfAttempts == 2 {
                exp.fulfill()
                let jsonObject: [String: Any] = [
                    "id": self.deviceId
                ]

                return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 200, headers: nil)
            } else {
                return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 500, headers: nil)
            }
        }

        let startJob: ServerSyncJob = .startJob(instanceId: instanceId, token: deviceToken)
        let serverSyncProcessHandler = ServerSyncProcessHandler(instanceId: instanceId, getTokenProvider: noTokenProvider, handleServerSyncEvent: ignoreServerSyncEvent)
        serverSyncProcessHandler.jobQueue.append(startJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: startJob)

        waitForExpectations(timeout: 1)
    }
    
    func testStopAfterDeviceCouldNotBeCreated() {
        // This test is similar to the previous testStartJobRetriesDeviceCreation, except inverted and tests a specific "Device could not be created" response from our API. It must not retry.
        let url = URL.PushNotifications.devices(instanceId: instanceId)!
        let exp = expectation(description: "It should stop")
        exp.isInverted = true
        var numberOfAttempts = 0
        stub(condition: isMethodPOST() && isAbsoluteURLString(url.absoluteString)) { _ in
            let jsonObject: [String: Any] = [
                "description": "Device could not be created"
            ]

            numberOfAttempts += 1
            if numberOfAttempts == 2 {
                exp.fulfill()
                let jsonObject: [String: Any] = [
                    "id": self.deviceId
                ]
                
                return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 200, headers: nil)
            } else {
                return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 500, headers: nil)
            }
        }

        let startJob: ServerSyncJob = .startJob(instanceId: instanceId, token: deviceToken)
        let serverSyncProcessHandler = ServerSyncProcessHandler(instanceId: instanceId, getTokenProvider: noTokenProvider, handleServerSyncEvent: ignoreServerSyncEvent)
        serverSyncProcessHandler.jobQueue.append(startJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: startJob)

        waitForExpectations(timeout: 1)
    }


    func testItShouldSkipJobsBeforeStartJob() {
        let exp = expectation(description: "It should not trigger any server endpoints")
        exp.isInverted = true

        let anyRequestIsFineReally = { (_: URLRequest) in
            return true
        }

        stub(condition: anyRequestIsFineReally) { _ in
            exp.fulfill()
            return HTTPStubsResponse(jsonObject: [], statusCode: 500, headers: nil)
        }

        let serverSyncProcessHandler = ServerSyncProcessHandler(instanceId: instanceId, getTokenProvider: noTokenProvider, handleServerSyncEvent: ignoreServerSyncEvent)
        let jobs: [ServerSyncJob] = [
            .refreshTokenJob(newToken: "1"),
            .subscribeJob(interest: "abc", localInterestsChanged: true),
            .unsubscribeJob(interest: "12", localInterestsChanged: true)
        ]

        for job in jobs {
            serverSyncProcessHandler.jobQueue.append(job)
            serverSyncProcessHandler.handleMessage(serverSyncJob: job)
        }

        waitForExpectations(timeout: 1)
    }

    func testItShouldMergeTheRemoteInitialInterestsSetWithLocalInterestSet() {
        let url = URL.PushNotifications.devices(instanceId: instanceId)!

        stub(condition: isMethodPOST() && isAbsoluteURLString(url.absoluteString)) { _ in
            let jsonObject: [String: Any] = [
                "id": self.deviceId,
                "initialInterestSet": ["interest-x", "hello"]
            ]

            return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 200, headers: nil)
        }

        let jobs: [ServerSyncJob] = [
            .subscribeJob(interest: "interest-0", localInterestsChanged: true),
            .subscribeJob(interest: "interest-1", localInterestsChanged: true),
            .subscribeJob(interest: "interest-2", localInterestsChanged: true),
            .unsubscribeJob(interest: "interest-0", localInterestsChanged: true),
            .unsubscribeJob(interest: "interest-x", localInterestsChanged: true),
            .startJob(instanceId: instanceId, token: deviceToken)
        ]

        let expectedInterestsSet = Set(["interest-1", "interest-2", "hello"])

        let exp = expectation(description: "Interests changed callback has been called")
        let handleServerSyncEvent: (ServerSyncEvent) -> Void = { event in
            switch event {
            case .interestsChangedEvent(let interests):
                XCTAssertTrue(interests.containsSameElements(as: Array(expectedInterestsSet)))
                exp.fulfill()

            default:
                XCTFail("The event should be of type '.InterestsChangedEvent'")
            }
            return
        }

        let serverSyncProcessHandler = ServerSyncProcessHandler(instanceId: instanceId, getTokenProvider: noTokenProvider, handleServerSyncEvent: handleServerSyncEvent)
        for job in jobs {
            serverSyncProcessHandler.jobQueue.append(job)
            serverSyncProcessHandler.handleMessage(serverSyncJob: job)
        }

        let localInterestsSet = Set(self.deviceStateStore.getInterests() ?? [])
        XCTAssertEqual(localInterestsSet, expectedInterestsSet)

        waitForExpectations(timeout: 1)
    }

    func testItShouldMergeTheRemoteInitialInterestsSetWithLocalInterestSetThisTimeUsingSetSubscriptions() {
        let url = URL.PushNotifications.devices(instanceId: instanceId)!

        stub(condition: isMethodPOST() && isAbsoluteURLString(url.absoluteString)) { _ in
            let jsonObject: [String: Any] = [
                "id": self.deviceId,
                "initialInterestSet": ["interest-x", "hello"]
            ]

            return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 200, headers: nil)
        }

        let jobs: [ServerSyncJob] = [
            .subscribeJob(interest: "interest-0", localInterestsChanged: true),
            .subscribeJob(interest: "interest-1", localInterestsChanged: true),
            .unsubscribeJob(interest: "interest-0", localInterestsChanged: true),
            .setSubscriptions(interests: ["cucas", "potatoes", "123"], localInterestsChanged: true),
            .subscribeJob(interest: "interest-2", localInterestsChanged: true),
            .unsubscribeJob(interest: "interest-x", localInterestsChanged: true),
            .startJob(instanceId: instanceId, token: deviceToken)
        ]

        let serverSyncProcessHandler = ServerSyncProcessHandler(instanceId: instanceId, getTokenProvider: noTokenProvider, handleServerSyncEvent: ignoreServerSyncEvent)
        for job in jobs {
            serverSyncProcessHandler.jobQueue.append(job)
            serverSyncProcessHandler.handleMessage(serverSyncJob: job)
        }

        let localInterestsSet = Set(self.deviceStateStore.getInterests() ?? [])
        let expectedInterestsSet = Set(["cucas", "potatoes", "123", "interest-2"])
        XCTAssertEqual(localInterestsSet, expectedInterestsSet)
    }

    func testItShouldSetSubscriptionsAfterStartingIfItDiffersFromTheInitialInterestSet() {
        let registerURL = URL.PushNotifications.devices(instanceId: instanceId)!

        stub(condition: isMethodPOST() && isAbsoluteURLString(registerURL.absoluteString)) { _ in
            let jsonObject: [String: Any] = [
                "id": self.deviceId,
                "initialInterestSet": ["interest-x", "hello"]
            ]

            return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 200, headers: nil)
        }

        let exp = expectation(description: "It should successfully set subscriptions")
        let setInterestsURL = URL.PushNotifications.interests(instanceId: instanceId,
                                                              deviceId: deviceId)!
        stub(condition: isMethodPUT() && isAbsoluteURLString(setInterestsURL.absoluteString)) { _ in
            exp.fulfill()
            return HTTPStubsResponse(jsonObject: [], statusCode: 200, headers: nil)
        }

        let jobs: [ServerSyncJob] = [
            .subscribeJob(interest: "interest-0", localInterestsChanged: true),
            .subscribeJob(interest: "interest-1", localInterestsChanged: true),
            .unsubscribeJob(interest: "interest-0", localInterestsChanged: true),
            .setSubscriptions(interests: ["cucas", "potatoes", "123"], localInterestsChanged: true),
            .subscribeJob(interest: "interest-2", localInterestsChanged: true),
            .unsubscribeJob(interest: "interest-x", localInterestsChanged: true),
            .startJob(instanceId: instanceId, token: deviceToken)
        ]

        let serverSyncProcessHandler = ServerSyncProcessHandler(instanceId: instanceId, getTokenProvider: noTokenProvider, handleServerSyncEvent: ignoreServerSyncEvent)
        for job in jobs {
            serverSyncProcessHandler.jobQueue.append(job)
            serverSyncProcessHandler.handleMessage(serverSyncJob: job)
        }

        let localInterestsSet = Set(self.deviceStateStore.getInterests() ?? [])
        let expectedInterestsSet = Set(["cucas", "potatoes", "123", "interest-2"])
        XCTAssertEqual(localInterestsSet, expectedInterestsSet)

        waitForExpectations(timeout: 1)
    }

    func testItShouldNotSetSubscriptionsAfterStartingIfItDoesntDifferFromTheInitialInterestSet() {
        let registerURL = URL.PushNotifications.devices(instanceId: instanceId)!

        stub(condition: isMethodPOST() && isAbsoluteURLString(registerURL.absoluteString)) { _ in
            let jsonObject: [String: Any] = [
                "id": self.deviceId,
                "initialInterestSet": ["interest-x", "hello"]
            ]

            return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 200, headers: nil)
        }

        let exp = expectation(description: "It should not call set subscriptions")
        exp.isInverted = true
        let setInterestsURL = URL.PushNotifications.interests(instanceId: instanceId,
                                                              deviceId: deviceId)!
        stub(condition: isMethodPUT() && isAbsoluteURLString(setInterestsURL.absoluteString)) { _ in
            exp.fulfill()
            return HTTPStubsResponse(jsonObject: [], statusCode: 200, headers: nil)
        }

        let jobs: [ServerSyncJob] = [
            .subscribeJob(interest: "hello", localInterestsChanged: true),
            .startJob(instanceId: instanceId, token: deviceToken)
        ]

        let serverSyncProcessHandler = ServerSyncProcessHandler(instanceId: instanceId, getTokenProvider: noTokenProvider, handleServerSyncEvent: ignoreServerSyncEvent)
        for job in jobs {
            serverSyncProcessHandler.jobQueue.append(job)
            serverSyncProcessHandler.handleMessage(serverSyncJob: job)
        }

        let localInterestsSet = Set(self.deviceStateStore.getInterests() ?? [])
        let expectedInterestsSet = Set(["interest-x", "hello"])
        XCTAssertEqual(localInterestsSet, expectedInterestsSet)

        waitForExpectations(timeout: 1)
    }

    func testStopJobBeforeStartSHouldNotThrowAnError() {
        let registerURL = URL.PushNotifications.devices(instanceId: instanceId)!

        stub(condition: isMethodPOST() && isAbsoluteURLString(registerURL.absoluteString)) { _ in
            let jsonObject: [String: Any] = [
                "id": self.deviceId,
                "initialInterestSet": ["interest-x", "hello"]
            ]

            return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 200, headers: nil)
        }

        let jobs: [ServerSyncJob] = [
            .stopJob,
            .startJob(instanceId: instanceId, token: deviceToken)
        ]

        let serverSyncProcessHandler = ServerSyncProcessHandler(instanceId: instanceId, getTokenProvider: noTokenProvider, handleServerSyncEvent: ignoreServerSyncEvent)
        for job in jobs {
            serverSyncProcessHandler.jobQueue.append(job)
            serverSyncProcessHandler.handleMessage(serverSyncJob: job)
        }
    }

    func testStopJobWillDeleteDeviceRemotelyAndLocally() {
        let registerURL = URL.PushNotifications.devices(instanceId: instanceId)!

        stub(condition: isMethodPOST() && isAbsoluteURLString(registerURL.absoluteString)) { _ in
            let jsonObject: [String: Any] = [
                "id": self.deviceId,
                "initialInterestSet": ["interest-x", "hello"]
            ]

            return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 200, headers: nil)
        }

        let deleteURL = URL.PushNotifications.device(instanceId: instanceId,
                                                     deviceId: deviceId)!

        stub(condition: isAbsoluteURLString(deleteURL.absoluteString)) { _ in
            return HTTPStubsResponse(jsonObject: [], statusCode: 200, headers: nil)
        }

        let startJob: ServerSyncJob = .startJob(instanceId: instanceId, token: deviceToken)
        let serverSyncProcessHandler = ServerSyncProcessHandler(instanceId: instanceId, getTokenProvider: noTokenProvider, handleServerSyncEvent: ignoreServerSyncEvent)
        serverSyncProcessHandler.jobQueue.append(startJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: startJob)

        XCTAssertNotNil(self.deviceStateStore.getDeviceId())
        XCTAssertNotNil(self.deviceStateStore.getAPNsToken())

        let stopJob: ServerSyncJob = .stopJob
        serverSyncProcessHandler.jobQueue.append(stopJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: stopJob)

        XCTAssertNil(self.deviceStateStore.getDeviceId())
        XCTAssertNil(self.deviceStateStore.getAPNsToken())
    }

    func testThatSubscribingUnsubscribingAndSetSubscriptionsWillTriggerTheAPI() {
        let url = URL.PushNotifications.devices(instanceId: instanceId)!
        var expRegisterCalled = false
        var expSubscribeCalled = false
        var expUnsubscribeCalled = false
        var expSetSubscriptionsCalled = false

        stub(condition: isMethodPOST() && isAbsoluteURLString(url.absoluteString)) { _ in
            let jsonObject: [String: Any] = [
                "id": self.deviceId
            ]

            expRegisterCalled = true

            return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 200, headers: nil)
        }

        let addInterestURL = URL.PushNotifications.interest(instanceId: instanceId,
                                                            deviceId: deviceId,
                                                            interest: "hello")!
        stub(condition: isMethodPOST() && isAbsoluteURLString(addInterestURL.absoluteString)) { _ in
            expSubscribeCalled = true
            return HTTPStubsResponse(jsonObject: [], statusCode: 200, headers: nil)
        }

        let removeInterestURL = URL.PushNotifications.interest(instanceId: instanceId,
                                                               deviceId: deviceId,
                                                               interest: "hello")!
        stub(condition: isMethodDELETE() && isAbsoluteURLString(removeInterestURL.absoluteString)) { _ in
            expUnsubscribeCalled = true
            return HTTPStubsResponse(jsonObject: [], statusCode: 200, headers: nil)
        }

        let setSubscriptionsURL = URL.PushNotifications.interests(instanceId: instanceId,
                                                                  deviceId: deviceId)!
        stub(condition: isMethodPUT() && isAbsoluteURLString(setSubscriptionsURL.absoluteString)) { _ in
            expSetSubscriptionsCalled = true
            return HTTPStubsResponse(jsonObject: [], statusCode: 200, headers: nil)
        }

        let jobs: [ServerSyncJob] = [
            .startJob(instanceId: instanceId, token: deviceToken),
            .subscribeJob(interest: "hello", localInterestsChanged: true),
            .unsubscribeJob(interest: "hello", localInterestsChanged: true),
            .setSubscriptions(interests: ["1", "2"], localInterestsChanged: true)
        ]

        let serverSyncProcessHandler = ServerSyncProcessHandler(instanceId: instanceId, getTokenProvider: noTokenProvider, handleServerSyncEvent: ignoreServerSyncEvent)
        for job in jobs {
            serverSyncProcessHandler.jobQueue.append(job)
            serverSyncProcessHandler.handleMessage(serverSyncJob: job)
        }

        XCTAssertTrue(expRegisterCalled)
        XCTAssertTrue(expSubscribeCalled)
        XCTAssertTrue(expUnsubscribeCalled)
        XCTAssertTrue(expSetSubscriptionsCalled)
    }

    func testDeviceRecreation() {
        let registerURL = URL.PushNotifications.devices(instanceId: instanceId)!

        let newDeviceId = "new-device-id"
        var isFirstTimeRegistering = true
        stub(condition: isMethodPOST() && isAbsoluteURLString(registerURL.absoluteString)) { _ in
            var jsonObject: [String: Any] = [:]

            if isFirstTimeRegistering {
                jsonObject["id"] = self.deviceId
            } else {
                jsonObject["id"] = newDeviceId
            }

            isFirstTimeRegistering = false

            return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 200, headers: nil)
        }

        let subscribeURL = URL.PushNotifications.interest(instanceId: instanceId,
                                                          deviceId: deviceId,
                                                          interest: "hello")!
        stub(condition: isMethodPOST() && isAbsoluteURLString(subscribeURL.absoluteString)) { _ in
            return HTTPStubsResponse(jsonObject: [], statusCode: 404, headers: nil)
        }

        let subscribe2URL = URL.PushNotifications.interest(instanceId: instanceId,
                                                           deviceId: newDeviceId,
                                                           interest: "hello")!
        stub(condition: isMethodPOST() && isAbsoluteURLString(subscribe2URL.absoluteString)) { _ in
            return HTTPStubsResponse(jsonObject: [], statusCode: 200, headers: nil)
        }

        let startJob: ServerSyncJob = .startJob(instanceId: instanceId, token: deviceToken)
        let serverSyncProcessHandler = ServerSyncProcessHandler(instanceId: instanceId, getTokenProvider: noTokenProvider, handleServerSyncEvent: ignoreServerSyncEvent)
        serverSyncProcessHandler.jobQueue.append(startJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: startJob)

        XCTAssertNotNil(self.deviceStateStore.getDeviceId())
        XCTAssertNotNil(self.deviceStateStore.getAPNsToken())

        let subscribeJob: ServerSyncJob = .subscribeJob(interest: "hello", localInterestsChanged: true)
        serverSyncProcessHandler.jobQueue.append(subscribeJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: subscribeJob)

        XCTAssertEqual(self.deviceStateStore.getDeviceId(), newDeviceId)
    }

    func testDeviceRecreationShouldClearPreviousUserIdIfTokenProviderIsMissing() {
        let registerURL = URL.PushNotifications.devices(instanceId: instanceId)!

        let newDeviceId = "new-device-id"
        var isFirstTimeRegistering = true
        stub(condition: isMethodPOST() && isAbsoluteURLString(registerURL.absoluteString)) { _ in
            var jsonObject: [String: Any] = [:]

            if isFirstTimeRegistering {
                jsonObject["id"] = self.deviceId
            } else {
                jsonObject["id"] = newDeviceId
            }

            isFirstTimeRegistering = false

            return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 200, headers: nil)
        }

        let subscribeURL = URL.PushNotifications.interest(instanceId: instanceId,
                                                          deviceId: deviceId,
                                                          interest: "hello")!
        stub(condition: isMethodPOST() && isAbsoluteURLString(subscribeURL.absoluteString)) { _ in
            return HTTPStubsResponse(jsonObject: [], statusCode: 404, headers: nil)
        }

        let subscribe2URL = URL.PushNotifications.interest(instanceId: instanceId,
                                                           deviceId: newDeviceId,
                                                           interest: "hello")!
        stub(condition: isMethodPOST() && isAbsoluteURLString(subscribe2URL.absoluteString)) { _ in
            return HTTPStubsResponse(jsonObject: [], statusCode: 200, headers: nil)
        }

        // Pretending we already stored the user id.
        _ = self.deviceStateStore.persistUserId(userId: "cucas")

        let startJob: ServerSyncJob = .startJob(instanceId: instanceId, token: deviceToken)
        let serverSyncProcessHandler = ServerSyncProcessHandler(instanceId: instanceId, getTokenProvider: noTokenProvider, handleServerSyncEvent: ignoreServerSyncEvent)
        serverSyncProcessHandler.jobQueue.append(startJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: startJob)

        XCTAssertNotNil(self.deviceStateStore.getDeviceId())
        XCTAssertNotNil(self.deviceStateStore.getAPNsToken())

        let subscribeJob: ServerSyncJob = .subscribeJob(interest: "hello", localInterestsChanged: true)
        serverSyncProcessHandler.jobQueue.append(subscribeJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: subscribeJob)

        XCTAssertEqual(self.deviceStateStore.getDeviceId(), newDeviceId)
        XCTAssertNil(self.deviceStateStore.getUserId())
    }

    func testMetadataSynchonizationWhenAppStarts() {
        let registerURL = URL.PushNotifications.devices(instanceId: instanceId)!
        stub(condition: isMethodPOST() && isAbsoluteURLString(registerURL.absoluteString)) { _ in
            let jsonObject: [String: Any] = [
                "id": self.deviceId
            ]

            return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 200, headers: nil)
        }

        let deleteURL = URL.PushNotifications.device(instanceId: instanceId,
                                                     deviceId: deviceId)!
        stub(condition: isAbsoluteURLString(deleteURL.absoluteString)) { _ in
            return HTTPStubsResponse(jsonObject: [], statusCode: 200, headers: nil)
        }

        var numMetadataCalled = 0
        let metadataURL = URL.PushNotifications.metadata(instanceId: instanceId, deviceId: deviceId)!
        stub(condition: isMethodPUT() && isAbsoluteURLString(metadataURL.absoluteString)) { _ in
            numMetadataCalled += 1
            return HTTPStubsResponse(jsonObject: [], statusCode: 200, headers: nil)
        }

        let startJob: ServerSyncJob = .startJob(instanceId: instanceId, token: deviceToken)
        let metadata = Metadata(sdkVersion: "123", iosVersion: "11", macosVersion: nil)
        let applicationStartJob: ServerSyncJob = .applicationStartJob(metadata: metadata)
        let serverSyncProcessHandler = ServerSyncProcessHandler(instanceId: instanceId, getTokenProvider: noTokenProvider, handleServerSyncEvent: ignoreServerSyncEvent)
        serverSyncProcessHandler.jobQueue.append(startJob)
        serverSyncProcessHandler.jobQueue.append(applicationStartJob)
        serverSyncProcessHandler.jobQueue.append(applicationStartJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: startJob)
        XCTAssertEqual(numMetadataCalled, 0)
        serverSyncProcessHandler.handleMessage(serverSyncJob: applicationStartJob)
        XCTAssertEqual(numMetadataCalled, 1)
        serverSyncProcessHandler.handleMessage(serverSyncJob: applicationStartJob)
        XCTAssertEqual(numMetadataCalled, 1) // It didn't change.

        // ... and stopping and starting the SDK will lead to the same result
        numMetadataCalled = 0
        let stopJob: ServerSyncJob = .stopJob
        serverSyncProcessHandler.jobQueue.append(stopJob)
        serverSyncProcessHandler.jobQueue.append(startJob)
        serverSyncProcessHandler.jobQueue.append(applicationStartJob)
        serverSyncProcessHandler.jobQueue.append(applicationStartJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: stopJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: startJob)
        XCTAssertEqual(numMetadataCalled, 0)
        serverSyncProcessHandler.handleMessage(serverSyncJob: applicationStartJob)
        XCTAssertEqual(numMetadataCalled, 1)
        serverSyncProcessHandler.handleMessage(serverSyncJob: applicationStartJob)
        XCTAssertEqual(numMetadataCalled, 1) // It didn't change.
    }

    func testInterestsSynchonizationWhenAppStarts() {
        let registerURL = URL.PushNotifications.devices(instanceId: instanceId)!
        stub(condition: isMethodPOST() && isAbsoluteURLString(registerURL.absoluteString)) { _ in
            let jsonObject: [String: Any] = [
                "id": self.deviceId
            ]

            return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 200, headers: nil)
        }

        let deleteURL = URL.PushNotifications.device(instanceId: instanceId,
                                                     deviceId: deviceId)!
        stub(condition: isAbsoluteURLString(deleteURL.absoluteString)) { _ in
            return HTTPStubsResponse(jsonObject: [], statusCode: 200, headers: nil)
        }

        var numInterestsCalled = 0
        let setInterestsURL = URL.PushNotifications.interests(instanceId: instanceId, deviceId: deviceId)!
        stub(condition: isMethodPUT() && isAbsoluteURLString(setInterestsURL.absoluteString)) { _ in
            numInterestsCalled += 1
            return HTTPStubsResponse(jsonObject: [], statusCode: 200, headers: nil)
        }

        let startJob: ServerSyncJob = .startJob(instanceId: instanceId, token: deviceToken)
        let metadata = Metadata(sdkVersion: "123", iosVersion: "11", macosVersion: nil)
        let applicationStartJob: ServerSyncJob = .applicationStartJob(metadata: metadata)
        let serverSyncProcessHandler = ServerSyncProcessHandler(instanceId: instanceId, getTokenProvider: noTokenProvider, handleServerSyncEvent: ignoreServerSyncEvent)
        serverSyncProcessHandler.jobQueue.append(startJob)
        serverSyncProcessHandler.jobQueue.append(applicationStartJob)
        serverSyncProcessHandler.jobQueue.append(applicationStartJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: startJob)
        XCTAssertEqual(numInterestsCalled, 0)
        serverSyncProcessHandler.handleMessage(serverSyncJob: applicationStartJob)
        XCTAssertEqual(numInterestsCalled, 1)
        serverSyncProcessHandler.handleMessage(serverSyncJob: applicationStartJob)
        XCTAssertEqual(numInterestsCalled, 1) // It didn't change.

        // ... and stopping and starting the SDK will lead to the same result
        numInterestsCalled = 0
        let stopJob: ServerSyncJob = .stopJob
        serverSyncProcessHandler.jobQueue.append(stopJob)
        serverSyncProcessHandler.jobQueue.append(startJob)
        serverSyncProcessHandler.jobQueue.append(applicationStartJob)
        serverSyncProcessHandler.jobQueue.append(applicationStartJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: stopJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: startJob)
        XCTAssertEqual(numInterestsCalled, 0)
        serverSyncProcessHandler.handleMessage(serverSyncJob: applicationStartJob)
        XCTAssertEqual(numInterestsCalled, 1)
        serverSyncProcessHandler.handleMessage(serverSyncJob: applicationStartJob)
        XCTAssertEqual(numInterestsCalled, 1) // It didn't change.
    }

    func testSetUserIdAfterStartShouldSetTheUserIdInTheServerAndLocalStorage() {
        let registerURL = URL.PushNotifications.devices(instanceId: instanceId)!
        stub(condition: isMethodPOST() && isAbsoluteURLString(registerURL.absoluteString)) { _ in
            let jsonObject: [String: Any] = [
                "id": self.deviceId
            ]

            return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 200, headers: nil)
        }

        let startJob: ServerSyncJob = .startJob(instanceId: instanceId, token: deviceToken)
        let setUserIdJob: ServerSyncJob = .setUserIdJob(userId: "cucas")
        let tokenProvider = StubTokenProvider(jwt: "dummy-jwt", error: nil)
        let serverSyncProcessHandler = ServerSyncProcessHandler(
            instanceId: instanceId,
            getTokenProvider: { return tokenProvider },
            handleServerSyncEvent: { _ in return }
        )
        serverSyncProcessHandler.jobQueue.append(startJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: startJob)

        let exp = expectation(description: "Set user id will be called in the server")
        let setUserIdURL = URL.PushNotifications.user(instanceId: instanceId, deviceId: deviceId)!
        stub(condition: isMethodPUT() && isAbsoluteURLString(setUserIdURL.absoluteString)) { _ in
            exp.fulfill()
            return HTTPStubsResponse(jsonObject: [], statusCode: 200, headers: nil)
        }

        serverSyncProcessHandler.jobQueue.append(setUserIdJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: setUserIdJob)

        waitForExpectations(timeout: 1)

        XCTAssertNotNil(self.deviceStateStore.getUserId())
    }

    func testSetUserIdSuccessCallbackIsCalled() {
        let registerURL = URL.PushNotifications.devices(instanceId: instanceId)!
        stub(condition: isMethodPOST() && isAbsoluteURLString(registerURL.absoluteString)) { _ in
            let jsonObject: [String: Any] = [
                "id": self.deviceId
            ]

            return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 200, headers: nil)
        }

        let startJob: ServerSyncJob = .startJob(instanceId: instanceId, token: deviceToken)
        let setUserIdJob: ServerSyncJob = .setUserIdJob(userId: "cucas")
        let tokenProvider = StubTokenProvider(jwt: "dummy-jwt", error: nil)

        let exp = expectation(description: "Callback should be called")

        let serverSyncProcessHandler = ServerSyncProcessHandler(
            instanceId: instanceId,
            getTokenProvider: { return tokenProvider },
            handleServerSyncEvent: { event in
                switch event {
                case .userIdSetEvent("cucas", nil):
                    exp.fulfill()

                default:
                    XCTFail("The event should be of type '.UserIdSetEvent'")
                }
            }
        )
        serverSyncProcessHandler.jobQueue.append(startJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: startJob)

        let setUserIdURL = URL.PushNotifications.user(instanceId: instanceId, deviceId: deviceId)!
        stub(condition: isMethodPUT() && isAbsoluteURLString(setUserIdURL.absoluteString)) { _ in
            return HTTPStubsResponse(jsonObject: [], statusCode: 200, headers: nil)
        }

        serverSyncProcessHandler.jobQueue.append(setUserIdJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: setUserIdJob)

        waitForExpectations(timeout: 1)
    }

    func testSetUserIdTokenProviderNilError() {
        let registerURL = URL.PushNotifications.devices(instanceId: instanceId)!
        stub(condition: isMethodPOST() && isAbsoluteURLString(registerURL.absoluteString)) { _ in
            let jsonObject: [String: Any] = [
                "id": self.deviceId
            ]

            return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 200, headers: nil)
        }

        let startJob: ServerSyncJob = .startJob(instanceId: instanceId, token: deviceToken)
        let setUserIdJob: ServerSyncJob = .setUserIdJob(userId: "cucas")

        let exp = expectation(description: "Callback should be called")

        let serverSyncProcessHandler = ServerSyncProcessHandler(
            instanceId: instanceId,
            getTokenProvider: { return nil },
            handleServerSyncEvent: { event in
                switch event {
                case .userIdSetEvent("cucas", let error):
                    XCTAssertNotNil(error)
                    exp.fulfill()

                default:
                    XCTFail("The event should be of type '.UserIdSetEvent'")
                }
            }
        )
        serverSyncProcessHandler.jobQueue.append(startJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: startJob)

        let setUserIdURL = URL.PushNotifications.user(instanceId: instanceId, deviceId: deviceId)!
        stub(condition: isMethodPUT() && isAbsoluteURLString(setUserIdURL.absoluteString)) { _ in
            return HTTPStubsResponse(jsonObject: [], statusCode: 200, headers: nil)
        }

        serverSyncProcessHandler.jobQueue.append(setUserIdJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: setUserIdJob)

        waitForExpectations(timeout: 1)
    }

    func testSetUserIdTokenProviderReturnsError() {
        let registerURL = URL.PushNotifications.devices(instanceId: instanceId)!
        stub(condition: isMethodPOST() && isAbsoluteURLString(registerURL.absoluteString)) { _ in
            let jsonObject: [String: Any] = [
                "id": self.deviceId
            ]

            return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 200, headers: nil)
        }

        let startJob: ServerSyncJob = .startJob(instanceId: instanceId, token: deviceToken)
        let setUserIdJob: ServerSyncJob = .setUserIdJob(userId: "cucas")
        let tokenProvider = StubTokenProvider(jwt: "dummy-jwt", error: TokenProviderError.error("Error"))

        let exp = expectation(description: "Callback should be called")

        let serverSyncProcessHandler = ServerSyncProcessHandler(
            instanceId: instanceId,
            getTokenProvider: { return tokenProvider },
            handleServerSyncEvent: { event in
                switch event {
                case .userIdSetEvent("cucas", let error):
                    XCTAssertNotNil(error)
                    exp.fulfill()

                default:
                    XCTFail("The event should be of type '.UserIdSetEvent'")
                }
            }
        )
        serverSyncProcessHandler.jobQueue.append(startJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: startJob)

        let setUserIdURL = URL.PushNotifications.user(instanceId: instanceId, deviceId: deviceId)!
        stub(condition: isMethodPUT() && isAbsoluteURLString(setUserIdURL.absoluteString)) { _ in
            return HTTPStubsResponse(jsonObject: [], statusCode: 200, headers: nil)
        }

        serverSyncProcessHandler.jobQueue.append(setUserIdJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: setUserIdJob)

        waitForExpectations(timeout: 1)
    }

    func testSetUserIdBeamsServerRejectsTheRequest() {
        let registerURL = URL.PushNotifications.devices(instanceId: instanceId)!
        stub(condition: isMethodPOST() && isAbsoluteURLString(registerURL.absoluteString)) { _ in
            let jsonObject: [String: Any] = [
                "id": self.deviceId
            ]

            return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 200, headers: nil)
        }

        let startJob: ServerSyncJob = .startJob(instanceId: instanceId, token: deviceToken)
        let setUserIdJob: ServerSyncJob = .setUserIdJob(userId: "cucas")
        let tokenProvider = StubTokenProvider(jwt: "dummy-jwt", error: nil)

        let exp = expectation(description: "Callback should be called")

        let serverSyncProcessHandler = ServerSyncProcessHandler(
            instanceId: instanceId,
            getTokenProvider: { return tokenProvider },
            handleServerSyncEvent: { event in
                switch event {
                case .userIdSetEvent("cucas", let error):
                    XCTAssertNotNil(error)
                    exp.fulfill()

                default:
                    XCTFail("The event should be of type '.UserIdSetEvent'")
                }
            }
        )
        serverSyncProcessHandler.jobQueue.append(startJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: startJob)

        let setUserIdURL = URL.PushNotifications.user(instanceId: instanceId, deviceId: deviceId)!
        stub(condition: isMethodPUT() && isAbsoluteURLString(setUserIdURL.absoluteString)) { _ in
            return HTTPStubsResponse(jsonObject: [], statusCode: 400, headers: nil)
        }

        serverSyncProcessHandler.jobQueue.append(setUserIdJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: setUserIdJob)

        waitForExpectations(timeout: 1)
    }

    func testSetUserIdTokenProviderThrowsException() {
        let registerURL = URL.PushNotifications.devices(instanceId: instanceId)!
        stub(condition: isMethodPOST() && isAbsoluteURLString(registerURL.absoluteString)) { _ in
            let jsonObject: [String: Any] = [
                "id": self.deviceId
            ]

            return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 200, headers: nil)
        }

        let startJob: ServerSyncJob = .startJob(instanceId: instanceId, token: deviceToken)
        let setUserIdJob: ServerSyncJob = .setUserIdJob(userId: "cucas")
        let tokenProvider = StubTokenProvider(jwt: "dummy-jwt", error: nil, exception: PushNotificationsError.error("💣"))

        let exp = expectation(description: "Callback should be called")

        let serverSyncProcessHandler = ServerSyncProcessHandler(
            instanceId: instanceId,
            getTokenProvider: { return tokenProvider },
            handleServerSyncEvent: { event in
                switch event {
                case .userIdSetEvent("cucas", let error):
                    XCTAssertNotNil(error)
                    exp.fulfill()

                default:
                    XCTFail("The event should be of type '.UserIdSetEvent'")
                }
            }
        )
        serverSyncProcessHandler.jobQueue.append(startJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: startJob)

        let setUserIdURL = URL.PushNotifications.user(instanceId: instanceId, deviceId: deviceId)!
        stub(condition: isMethodPUT() && isAbsoluteURLString(setUserIdURL.absoluteString)) { _ in
            return HTTPStubsResponse(jsonObject: [], statusCode: 200, headers: nil)
        }

        serverSyncProcessHandler.jobQueue.append(setUserIdJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: setUserIdJob)

        waitForExpectations(timeout: 1)
    }

    #if os(iOS) || os(visionOS)
    func testTrackWillSendEventTypeToTheServer() {
        let url = URL.PushNotifications.devices(instanceId: instanceId)!
        var expRegisterCalled = false
        var trackCalled = false

        stub(condition: isMethodPOST() && isAbsoluteURLString(url.absoluteString)) { _ in
            let jsonObject: [String: Any] = [
                "id": self.deviceId
            ]

            expRegisterCalled = true

            return HTTPStubsResponse(jsonObject: jsonObject, statusCode: 200, headers: nil)
        }

        let trackURL = URL.PushNotifications.events(instanceId: instanceId)!
        stub(condition: isMethodPOST() && isAbsoluteURLString(trackURL.absoluteString)) { _ in
            trackCalled = true
            return HTTPStubsResponse(jsonObject: [], statusCode: 200, headers: nil)
        }

        let startJob: ServerSyncJob = .startJob(instanceId: instanceId, token: deviceToken)

        let serverSyncProcessHandler = ServerSyncProcessHandler(instanceId: instanceId, getTokenProvider: noTokenProvider, handleServerSyncEvent: ignoreServerSyncEvent)
        serverSyncProcessHandler.jobQueue.append(startJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: startJob)

        let userInfo = ["aps": ["alert": ["title": "Hello", "body": "Hello, world!"], "content-available": 1], "data": ["pusher": ["instanceId": "8a070eaa-033f-46d6-bb90-f4c15acc47e1", "publishId": "pubid-33f3f68e-b0c5-438f-b50f-fae93f6c48df"]]]
        let eventType = EventTypeHandler.getNotificationEventType(userInfo: userInfo, applicationState: .active) as! DeliveryEventType

        let trackEventJob: ServerSyncJob = .reportEventJob(eventType: eventType)

        serverSyncProcessHandler.jobQueue.append(trackEventJob)
        serverSyncProcessHandler.handleMessage(serverSyncJob: trackEventJob)

        XCTAssertTrue(expRegisterCalled)
        XCTAssertTrue(trackCalled)
    }
    #endif

    private class StubTokenProvider: TokenProvider {
        private let jwt: String
        private let error: Error?
        private let exception: Error?

        init(jwt: String, error: Error?, exception: Error? = nil) {
            self.jwt = jwt
            self.error = error
            self.exception = exception
        }

        func fetchToken(userId: String, completionHandler completion: @escaping (String, Error?) -> Void) throws {
            if let exception = self.exception {
                throw exception
            }

            completion(jwt, error)
        }
    }
}
