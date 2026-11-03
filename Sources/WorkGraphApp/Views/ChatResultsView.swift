import SwiftUI
import WorkGraphCore

/// CH-45: 채팅 본문의 결과물 화면. 3열 카드, 가운데 600 폭
struct ChatResultsView: View {
    @ObservedObject var library: LibraryState
    @State private var preview: ChatLibraryItem?
    @State private var deleting: ChatLibraryItem?

    var body: some View {
        let items = library.results()
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("결과물").font(Brand.suit(20, .bold)).foregroundStyle(Brand.ink)
                Text("결과물 \(items.count)개").font(Brand.suit(11)).foregroundStyle(Brand.gray).padding(.top, 4)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(192), spacing: 12), count: 3), alignment: .leading, spacing: 12) {
                    ForEach(items) { item in
                        ChatResultCard(library: library, item: item) { preview = $0 }
                            .contextMenu {
                                Button("파일 내보내기") { library.export(item) }
                                Button("보관함에서 삭제", role: .destructive) { deleting = item }
                            }
                    }
                }.padding(.top, 14)
                if let error = library.error { Text(error).font(Brand.suit(12)).foregroundStyle(.red).padding(.top, 12) }
            }.frame(width: 600, alignment: .leading)
                .padding(.top, 40).padding(.bottom, 40)
                .frame(maxWidth: .infinity)
        }.background(.white)
        .sheet(item: $preview) { LibraryPreview(library: library, item: $0) }
        .alert("자료를 삭제할까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) { if let item = deleting { library.delete(item) } }
        } message: { Text("보관함의 복사본과 모든 대화 연결이 삭제됩니다. 업로드한 원본 파일과 기존 채팅 답변은 남습니다.") }
    }
}

/// 192x156 결과물 카드. 새 대화 화면도 쓴다
struct ChatResultCard: View {
    @ObservedObject var library: LibraryState
    let item: ChatLibraryItem
    var onOpen: (ChatLibraryItem) -> Void
    @State private var first = ""

    var body: some View {
        Button { onOpen(item) } label: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(Brand.suit(9, .medium)).foregroundStyle(Brand.ink).lineLimit(1)
                    Text(first).font(Brand.suit(7)).foregroundStyle(Brand.gray).lineLimit(2)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 10).padding(.top, 10)
                    .frame(width: 164, height: 86, alignment: .topLeading)
                    .background(.white, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.line, lineWidth: 1))
                Text(item.title).font(Brand.suit(12, .medium)).foregroundStyle(Brand.ink).lineLimit(1).padding(.top, 12)
                Text(ChatDateText.relative(item.createdAt)).font(Brand.suit(10)).foregroundStyle(Brand.gray).padding(.top, 4)
            }.padding(13).frame(width: 192, height: 156, alignment: .topLeading)
                .background(Brand.paper, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ChatPalette.cardLine, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
            .task(id: item.id) { first = LibraryTextInfo.read(library.store.url(for: item)).first }
    }
}
