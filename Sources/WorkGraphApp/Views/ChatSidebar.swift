import SwiftUI
import WorkGraphCore

/// 채팅 탭 왼쪽 대화 목록 (Figma CH-02, 29, 30). 폭 261, 오른쪽 선은 바깥에서 그린다.
struct ChatSidebar: View {
    @ObservedObject var chat: ChatState
    @Binding var pane: ChatPane
    var isSearching: Bool
    var onSearch: () -> Void
    var onSchedules: () -> Void
    var onCollapse: () -> Void
    var onRename: (ChatConversation) -> Void
    var onDelete: (ChatConversation) -> Void

    @State private var pinnedOpen = true
    @State private var recentOpen = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(spacing: 2) {
                navRow("새 대화", "plus", selected: pane == .chat && chat.messages.isEmpty && !isSearching) {
                    chat.newConversation(); pane = .chat
                }
                navRow("검색", "magnifyingglass", selected: isSearching, action: onSearch)
                navRow("프로젝트", "folder", selected: isProjectPane) { pane = .projects }
                navRow("결과물", "square.on.square", selected: pane == .results) { pane = .results }
                navRow("예약 작업", "clock", selected: false, trailing: "\(chat.automations.count)", action: onSchedules)
            }
            .padding(.leading, 12).padding(.trailing, 12).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !chat.pinnedConversations.isEmpty {
                        sectionHeader("고정됨", open: $pinnedOpen)
                        if pinnedOpen { ForEach(chat.pinnedConversations) { conversationRow($0) } }
                    }
                    sectionHeader("최근 항목", open: $recentOpen)
                    if recentOpen {
                        ForEach(chat.recentConversations) { conversationRow($0) }
                        Button { pane = .allConversations } label: {
                            Text("모두 보기").font(Brand.suit(11)).foregroundStyle(Brand.tabText)
                                .padding(.leading, 10).frame(height: 32, alignment: .leading)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 16)
            }
        }
        .frame(width: ChatPalette.sidebarWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Brand.paper)
    }

    private var isProjectPane: Bool {
        switch pane { case .projects, .project: return true; default: return false }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onCollapse) {
                Image(systemName: "sidebar.left").font(.system(size: 15)).foregroundStyle(Brand.tabText)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).help("목록 접기").accessibilityLabel("목록 접기")
            Text("채팅").font(Brand.suit(20, .bold)).foregroundStyle(Brand.ink)
            Spacer(minLength: 0)
        }.padding(.leading, 14).padding(.top, 14).frame(height: 56, alignment: .topLeading)
    }

    private func navRow(_ title: String, _ icon: String, selected: Bool, trailing: String? = nil,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 16)
                Text(title).font(Brand.suit(12, selected ? .medium : .regular))
                Spacer(minLength: 0)
                if let trailing { Text(trailing).font(Brand.suit(11)).foregroundStyle(Brand.gray) }
            }
            .foregroundStyle(Brand.ink)
            .padding(.leading, 10).padding(.trailing, 12).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? ChatPalette.navSelected : .clear))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).hoverHighlight(cornerRadius: 7)
    }

    private func sectionHeader(_ title: String, open: Binding<Bool>) -> some View {
        Button { open.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Text(title).font(Brand.suit(11))
                Image(systemName: "triangle.fill").font(.system(size: 5)).rotationEffect(.degrees(open.wrappedValue ? 180 : 90))
            }
            .foregroundStyle(Brand.gray).padding(.leading, 10).frame(height: 28, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func conversationRow(_ item: ChatConversation) -> some View {
        ConversationRow(item: item, isCurrent: pane == .chat && chat.current.id == item.id,
                        isBusy: chat.activeMessage?.conversationID == item.id,
                        open: { chat.select(item); pane = .chat }) { menu(item) }
            .padding(.vertical, 1)     // 줄 30 + 사이 2 = 피치 32 (Figma CH-02)
    }

    @ViewBuilder private func menu(_ item: ChatConversation) -> some View {
        let busy = chat.activeMessage?.conversationID == item.id
        Button { chat.togglePin(item) } label: {
            item.pinnedAt != nil ? Label("고정 해제", systemImage: "pin.slash") : Label("고정", systemImage: "pin")
        }
        Button { onRename(item) } label: { Label("이름 바꾸기", systemImage: "pencil") }
        ProjectMoveMenu(projects: chat.projects, itemID: "conversation:\(item.id)").disabled(busy)
        Divider()
        Button(role: .destructive) { onDelete(item) } label: { Label("삭제", systemImage: "trash") }.disabled(busy)
    }
}

private struct ConversationRow<MenuContent: View>: View {
    let item: ChatConversation
    let isCurrent: Bool
    let isBusy: Bool
    let open: () -> Void
    @ViewBuilder var menu: () -> MenuContent
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                Text(item.title).font(Brand.suit(11)).foregroundStyle(isCurrent ? Brand.ink : Brand.tabText)
                    .lineLimit(1).padding(.leading, 10)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if isBusy {
                // CH-14: 응답이 도는 대화는 메뉴 자리에 스피너 (메뉴는 오른쪽 클릭으로)
                ProgressView().controlSize(.small).frame(width: 28, height: 30)
            } else {
                Menu { menu() } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Brand.tabText)
                        .frame(width: 28, height: 30).contentShape(Rectangle())
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .opacity(isCurrent || hovering ? 1 : 0)
            }
        }
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 5).fill(isCurrent ? Color.white.opacity(0.6) : (hovering ? Color.white.opacity(0.35) : .clear)))
        .onHover { hovering = $0 }
        .contextMenu { menu() }
    }
}
