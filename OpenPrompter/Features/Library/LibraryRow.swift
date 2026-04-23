//
//  LibraryRow.swift
//  OpenPrompter
//
//  Single row in the script library list.
//

import SwiftUI

struct LibraryRow: View {
    let file: ScriptFile

    private var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: file.mtime, relativeTo: .now)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(file.displayName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                    .lineLimit(1)

                Text(relativeDate)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.dim)
            }

            Spacer()

            if file.downloadState != .downloaded {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(Theme.dim)
                    .font(.system(size: 18))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }
}
