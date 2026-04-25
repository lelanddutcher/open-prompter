//
//  RemoteEventBusTests.swift
//  OpenPrompterTests
//
//  Verifies fan-in: multiple sources publish into the same bus and the
//  consumer sees every event in the order they were published.
//

import XCTest
@testable import OpenPrompter

final class RemoteEventBusTests: XCTestCase {

    func testSinglePublishYieldsOneEvent() async {
        let bus = RemoteEventBus()
        let task = Task {
            var received: [RemoteEvent] = []
            for await event in bus.events {
                received.append(event)
                if received.count == 1 { break }
            }
            return received
        }
        bus.publish(.playPause)
        let result = await task.value
        XCTAssertEqual(result, [.playPause])
    }

    func testMultipleSourcesFanIn() async {
        // Three "sources" pushing into the same bus from independent tasks
        // — exercises the actor-style serialization without depending on
        // the actual Source implementations (which require real iOS APIs).
        let bus = RemoteEventBus()
        let totalEventsExpected = 6

        let collector = Task { () -> [RemoteEvent] in
            var received: [RemoteEvent] = []
            for await event in bus.events {
                received.append(event)
                if received.count == totalEventsExpected { break }
            }
            return received
        }

        // Source A — keyboard-style events.
        let a = Task {
            bus.publish(.playPause)
            bus.publish(.speedUp)
        }
        // Source B — media-style events.
        let b = Task {
            bus.publish(.nextSection)
            bus.publish(.prevSection)
        }
        // Source C — volume-style events.
        let c = Task {
            bus.publish(.jumpToStart)
            bus.publish(.mirrorToggle)
        }

        _ = await (a.value, b.value, c.value)
        let received = await collector.value
        XCTAssertEqual(received.count, totalEventsExpected)
        // Every published event made it through.
        let set = Set(received)
        XCTAssertTrue(set.contains(.playPause))
        XCTAssertTrue(set.contains(.speedUp))
        XCTAssertTrue(set.contains(.nextSection))
        XCTAssertTrue(set.contains(.prevSection))
        XCTAssertTrue(set.contains(.jumpToStart))
        XCTAssertTrue(set.contains(.mirrorToggle))
    }

    func testEventOrderPreservedWithinSingleProducer() async {
        let bus = RemoteEventBus()
        let task = Task {
            var received: [RemoteEvent] = []
            for await event in bus.events {
                received.append(event)
                if received.count == 4 { break }
            }
            return received
        }

        bus.publish(.scrollUp)
        bus.publish(.scrollDown)
        bus.publish(.scrollLeft)
        bus.publish(.scrollRight)

        let result = await task.value
        XCTAssertEqual(result, [.scrollUp, .scrollDown, .scrollLeft, .scrollRight])
    }
}
