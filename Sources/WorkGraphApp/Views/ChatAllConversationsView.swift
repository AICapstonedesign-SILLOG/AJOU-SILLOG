import SwiftUI
import WorkGraphCore

/// 모든 대화 목록 (Figma CH-44).
struct ChatAllConversationsView: View {
    @ObservedObject var chat: ChatState
    var onOpen: (ChatConversation) -> Void
    var onNew: () -> Void

    @State private var query = ""
    /// 마지막 검색에서 맞은 대화. 검색은 검색어가 바뀔 때만 돌고, 화면은 이 집합만 거른다.
    @State private var matched: Set<String>?

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var items: [ChatConversation] {
        guard !trimmed.isEmpty, let matched else { return chat.conversations }
        return chat.conversations.filter { matched.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("모든 대화").font(Brand.suit(20, .bold)).foregroundStyle(Brand.ink)
                    Spacer()
                    Button(action: onNew) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                            Text("새 대화").font(Brand.suit(12, .medium))
                        }.foregroundStyle(.white).padding(.leading, 12).padding(.trailing, 14).frame(height: 30)
                            .background(Capsule().fill(Brand.accentDark))
                    }.buttonStyle(.plain)
                }.frame(height: 30)
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Brand.gray)
                    TextField("", text: $query, prompt: Text("대화 검색").font(Brand.suit(12)).foregroundColor(Brand.gray))
                        .textFieldStyle(.plain).font(Brand.suit(12)).foregroundStyle(Brand.text)
                }.padding(.horizontal, 14).frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(ChatPalette.field)).padding(.top, 21)
                Text("대화 \(items.count)개").font(Brand.suit(11)).foregroundStyle(Brand.gray).padding(.top, 14).padding(.bottom, 4)
                ForEach(items) { item in
                    Button { onOpen(item) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(Brand.suit(12, .medium)).foregroundStyle(Brand.ink).lineLimit(1)
                                Text((chat.conversationPreviews[item.id] ?? "").replacingOccurrences(of: "\n", with: " "))
                                    .font(Brand.suit(11)).foregroundStyle(Brand.gray).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(ChatDateText.day(item.updatedAt)).font(Brand.suit(11)).foregroundStyle(Brand.gray)
                        }
                        .padding(.top, 12).padding(.bottom, 13).frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) { Rectangle().fill(ChatPalette.cardLine).frame(height: 1) }
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            .frame(width: ChatPalette.columnWidth).frame(maxWidth: .infinity).padding(.top, 40).padding(.bottom, 32)
        }.background(.white)
        .task(id: trimmed) {
            guard !trimmed.isEmpty else { matched = nil; return }
            try? await Task.sleep(for: .milliseconds(200))      // 한 글자씩 칠 때마다 DB를 훑지 않게
            guard !Task.isCancelled else { return }
            let found = Set(await chat.search(trimmed).map(\.conversationID))
            if !Task.isCancelled { matched = found }
        }
    }
}
