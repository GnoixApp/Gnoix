import SwiftUI
import Kingfisher

struct HistoryView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject var manager = PlayHistoryManager.shared
    var onSelect: ((PlayHistoryItem) -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(manager.history) { item in
                        Button(action: {
                            print("[历史跳转] 视频ID: \(item.video.id), 名字: \(item.video.title), 源: \(item.video.sourceApi ?? "无")")
                            onSelect?(item)
                        }) {
                            HStack(alignment: .center, spacing: 14) {
                                KFImage(URL(string: item.video.cover ?? ""))
                                    .placeholder {
                                        Color.gray.opacity(0.15)
                                    }
                                    .resizable()
                                    .aspectRatio(1, contentMode: .fill)
                                    .frame(width: 80, height: 80)
                                    .clipped()
                                    .cornerRadius(10)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.video.title)
                                        .font(.headline)
                                        .foregroundColor(themeManager.getTextColor())
                                        .lineLimit(2)
                                    if let ep = item.lastEpisode {
                                        Text("上次看到：\(ep.title)")
                                            .font(.subheadline)
                                            .foregroundColor(themeManager.getAccentColor())
                                    }
                                    Text(item.playedAt, style: .date)
                                        .font(.caption2)
                                        .foregroundColor(themeManager.getSecondaryTextColor())
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(10)
                            .background(themeManager.getCardBackgroundColor())
                            .cornerRadius(14)
                            .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 2)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 16)
            }
            .background(themeManager.getBackgroundColor())
            .navigationTitle("播放历史")
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                if onDismiss != nil {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("关闭") {
                            onDismiss?()
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空") {
                        manager.clear()
                    }
                }
            }
        }
        .ignoresSafeArea(.all)
    }
} 