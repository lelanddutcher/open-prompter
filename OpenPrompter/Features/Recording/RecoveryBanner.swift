//
//  RecoveryBanner.swift
//  OpenPrompter
//
//  Force-quit recovery surface. On app launch we scan
//  `Documents/Recordings/` for a stale `.mov` (we delete on successful
//  Photos write, so any leftover means an interrupted take). When found,
//  the user sees this banner with two options: "recover" (write the file
//  to Photos and discard) or "discard" (delete the file). Per V2 Design 02
//  review note 8 — auto-discard would silently lose the user's work.
//

import Foundation
import Photos
import SwiftUI

struct RecoveryBanner: View {
    let url: URL
    let onRecover: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 13, weight: .bold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("partial recording found")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .tracking(0.5)
                    Text("recover or discard")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
                Spacer()
                Button(action: onRecover) {
                    Text("RECOVER")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.green, in: Capsule())
                        .foregroundStyle(Color(red: 0.03, green: 0.09, blue: 0.05))
                }
                Button(action: onDiscard) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(Theme.muted)
                }
            }
            // Informed-consent secondary copy. The recovered file is the
            // raw .mov from the writer — if the previous run died mid-take
            // the moov atom may be missing and the file may not play.
            // Recovery imports it to Photos as-is so the user can verify
            // before discarding (V2 Design 02 review note 3).
            Text("this recording was interrupted and may be unplayable. recovery imports it to Photos as-is — you can verify before discarding.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.amber.opacity(0.6), lineWidth: 1)
        )
        .padding(.horizontal, 10)
    }
}

/// Small helper that drives the actual recovery write. Lives next to the
/// banner so the surface and its action are colocated.
enum RecoveryAction {
    /// Push a stale recording into Photos. Returns true on success. On
    /// success, also discards every other stale `.mov` in the recordings
    /// directory — those are orphans the user already has in Photos (or
    /// the previous take's failure was already surfaced) and we don't
    /// want them accumulating across launches (V2 Design 02 review note 7).
    /// Failure keeps the recovered file in the sandbox so the user can
    /// retry via Files; other orphans are left untouched in that case.
    @MainActor
    static func recoverToPhotos(url: URL) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                request?.creationDate = .now
                request?.location = nil
            } completionHandler: { success, _ in
                if success {
                    // Drop every stale .mov, not just the recovered one —
                    // older orphans would otherwise re-trigger the banner
                    // on the next launch.
                    RecordingFileStore.discardAllStaleRecordings()
                }
                continuation.resume(returning: success)
            }
        }
    }
}
