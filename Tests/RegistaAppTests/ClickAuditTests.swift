import AppKit
import SwiftUI
import Testing
@testable import Regista

// Tests of the click audit itself (ClickAudit.swift): what it clicks is what it says it clicked.

/// Two buttons of the same name, one on each side of the window; each counts its own clicks and shows a line when
/// clicked (a change on screen, which the audit sees).
@MainActor
private final class Twins: ObservableObject {
    @Published var left = 0
    @Published var right = 0
}

private struct TwinsView: View {
    @ObservedObject var twins: Twins

    var body: some View {
        HStack(spacing: 0) {
            VStack {
                Button { twins.left += 1 } label: { Text(verbatim: "Voce") }
                if twins.left > 0 { Text(verbatim: "left clicked") }
            }
            .frame(width: 200, height: 200)
            VStack {
                Button { twins.right += 1 } label: { Text(verbatim: "Voce") }
                if twins.right > 0 { Text(verbatim: "right clicked") }
            }
            .frame(width: 200, height: 200)
        }
        .frame(width: 400, height: 200)
    }
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct ClickAuditTests {
    /// A name that exists inside and outside the audited area: the control inside is the one clicked (#48), never the
    /// first one of that name in the window.
    @Test func aControlIsFoundAgainInsideTheArea() async throws {
        let app = try await AppRig(project: nil)
        defer { app.close() }
        let twins = Twins()
        app.host(TwinsView(twins: twins), size: CGSize(width: 400, height: 200))
        await app.settle()
        let named = app.rig.controls().filter { $0.name == "Voce" }
        try #require(named.count == 2, "the screen should show two controls named Voce: \(app.rig.controls().map(\.description))")
        let rows = await ClickAudit(app: app, screen: "audit-self-test", area: CGRect(x: 200, y: 0, width: 200, height: 200)).run()
        #expect(rows.count == 1, "the audit should list the one control inside the area: \(rows.map(\.control))")
        #expect(twins.right == 1, "the control inside the area was clicked \(twins.right) times")
        #expect(twins.left == 0, "the control of the same name outside the area was clicked")
        #expect(rows.first.map { $0.at.x >= 200 } == true, "the row says it clicked at \(rows.first.map { "\($0.at)" } ?? "nowhere")")
        ClickAudit.check(rows, screen: "audit-self-test")
    }
}
}
