import AppKit
import RegistaCore

// A file taken out of the project from its Media tile (#142): the trash icon, the tile's menu, ⌫. One command
// (media.remove, one undo step); an alert first when the timeline uses it; then a notice with Annulla and, for a recording
// Regista made, «Sposta il file nel Cestino».

extension EditorStore {
    /// Whether Regista made `asset`'s file: it lies inside the project's folder or in the recordings folder (a file the
    /// person imported from elsewhere never does).
    func isOwnRecording(_ asset: MediaAsset) -> Bool {
        let path = URL(fileURLWithPath: asset.path).resolvingSymlinksInPath().standardizedFileURL.path
        return [bench.recordingsFolder, projectURL].compactMap { $0 }
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path + "/" }
            .contains { path.hasPrefix($0) }
    }

    /// Takes `assetID` out of the project: when clips of the timeline use it, one alert first (Rimuovi / Annulla); then
    /// media.remove and the notice.
    func removeAsset(_ assetID: String) {
        guard let p = project, let asset = p.asset(assetID) else { return }
        let used = p.clips(removedWith: assetID).count
        if used > 0, !confirmRemoval(asset.name, clips: used) { return }
        Task {
            do {
                try await perform("media.remove", ["assetId": .string(assetID)])
                if sourceAssetID == assetID { sourceAssetID = nil }
                bench.notice = Workbench.Notice(text: loc("Tolto «%@» dal progetto", asset.name),
                                                removal: .init(tabID: tabID, name: asset.name,
                                                               trash: isOwnRecording(asset) ? URL(fileURLWithPath: asset.path) : nil))
            } catch {
                show(error)
            }
        }
    }

    /// «Rimuovere «name»?» with the clips that go too: true for Rimuovi.
    private func confirmRemoval(_ name: String, clips: Int) -> Bool {
        Self.removalAlert(name, clips: clips).runModal() == .alertFirstButtonReturn
    }

    /// The alert before a file the timeline uses goes: Rimuovi / Annulla.
    static func removalAlert(_ name: String, clips: Int) -> NSAlert {
        let a = NSAlert()
        a.messageText = loc("Rimuovere «%@»?", name)
        a.informativeText = Plural.text(clips, "È usato in 1 clip della timeline: sparisce anche da lì.",
                                        "È usato in %@ clip della timeline: spariscono anche da lì.")
        a.addButton(withTitle: loc("Rimuovi"))
        a.addButton(withTitle: loc("Annulla"))
        return a
    }

    /// The notice's Annulla: the removal is undone while it is still this tab's last edit.
    func undoRemoval() {
        if undoNames.last == "media.remove" { undo() }
    }

    /// The notice's «Sposta il file nel Cestino»: the file goes to the macOS Trash; the notice then says so, and that the
    /// removal can no longer be undone from it.
    func trashRemovedFile(_ url: URL, name: String) {
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { return self.show(error) }
                self.bench.notice = Workbench.Notice(text: loc("Il file di «%@» è nel Cestino: la rimozione non si annulla più da qui.", name))
            }
        }
    }
}
