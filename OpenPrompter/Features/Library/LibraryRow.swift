//
//  LibraryRow.swift
//  OpenPrompter
//
//  One script row. Paper filename, ghost-mono mtime, small green status
//  dot when the file is current on-device. Per design-language.md §6 the
//  tree glyph uses a ghost bullet (`▸`) as a low-key list marker.
//

import SwiftUI

struct LibraryRow: View {
    let file: ScriptFile

    private var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: file.mtime, relativeTo: .now)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("▸")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.green)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 4) {
                Text(file.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(relativeDate.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Theme.ghost)
            }

            Spacer()

            if file.downloadState == .downloaded {
                Circle()
                    .fill(Theme.green)
                    .frame(width: 6, height: 6)
                    .shadow(color: Theme.green.opacity(0.7), radius: 3)
            } else {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(Theme.amber)
                    .font(.system(size: 16))
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }
}
