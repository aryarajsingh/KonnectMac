import SwiftUI
import AppKit

struct NotificationPanelView: View {
    @ObservedObject var store = NotificationStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.notifications.isEmpty {
                emptyState
            } else {
                notificationList
            }
        }
        .frame(minWidth: 380, idealWidth: 420, minHeight: 400, idealHeight: 520)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                Text("Notifications")
                    .font(.system(size: 15, weight: .semibold))
                if store.count > 0 {
                    Text("\(store.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                }
            }
            Spacer()
            if !store.notifications.isEmpty {
                Button("Clear All") {
                    store.dismissAll()
                }
                .font(.system(size: 12))
                .foregroundColor(.red.opacity(0.7))
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bell.slash")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.quaternary)
            Text("No Notifications")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Phone notifications will appear here")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notificationList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(store.notifications) { item in
                    NotificationRow(item: item)
                }
            }
            .padding(.vertical, 6)
        }
    }
}

private struct NotificationRow: View {
    let item: NotificationItem
    @State private var hovered = false

    private var displayText: String {
        item.text.isEmpty ? item.ticker : item.text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            appIcon
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.appName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(item.timestamp, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                if !item.title.isEmpty && item.title != item.appName {
                    Text(item.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }

                if !displayText.isEmpty {
                    Text(displayText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            Button {
                NotificationStore.shared.dismiss(item)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .opacity(hovered ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovered ? Color.primary.opacity(0.04) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let iconPath = item.iconPath,
           let img = NSImage(contentsOfFile: iconPath) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
                Image(systemName: "app")
                    .font(.system(size: 14))
                    .foregroundStyle(.quaternary)
            }
        }
    }
}
