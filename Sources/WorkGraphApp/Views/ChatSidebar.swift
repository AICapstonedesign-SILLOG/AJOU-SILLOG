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
    @State private var hoverSection: String?

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
                        VStack(alignment: .leading, spacing: 0) {
                            sectionHeader("고정됨", open: $pinnedOpen)
                            if pinnedOpen { ForEach(chat.pinnedConversations) { conversationRow($0) } }
                        }.onHover { hoverSection = $0 ? "pinned" : (hoverSection == "pinned" ? nil : hoverSection) }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader("최근 항목", open: $recentOpen)
                        if recentOpen {
                            ForEach(chat.recentConversations) { conversationRow($0) }
                            Button { pane = .allConversations } label: {
                                Text("모두 보기").font(Brand.suit(12)).foregroundStyle(Brand.tabText)
                                    .padding(.leading, 10).frame(height: 32, alignment: .leading)
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.onHover { hoverSection = $0 ? "recent" : (hoverSection == "recent" ? nil : hoverSection) }
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
                Text(title).font(Brand.suit(13, selected ? .medium : .regular))
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
        // 삼각형은 커서가 구역 안에 있을 때, 접힌 구역은 항상 보인다 (CH-76, 77)
        let key = title == "고정됨" ? "pinned" : "recent"
        return Button { open.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Text(title).font(Brand.suit(12))
                Image(systemName: "triangle.fill").font(.system(size: 5)).rotationEffect(.degrees(open.wrappedValue ? 180 : 90))
                    .opacity(hoverSection == key || !open.wrappedValue ? 1 : 0)
            }
            .foregroundStyle(Brand.gray).padding(.leading, 10).frame(height: 28, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func conversationRow(_ item: ChatConversation) -> some View {
        ConversationRow(item: item, isCurrent: pane == .chat && chat.current.id == item.id,
                        isBusy: chat.activeMessage?.conversationID == item.id,
                        open: { chat.select(item); pane = .chat },
                        context: { menu(item) }, pop: { close in popMenu(item, close) })
            .padding(.vertical, 1)     // 줄 30 + 사이 2 = 피치 32 (Figma CH-02)
    }

    /// 오른쪽 클릭 메뉴
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

    /// ⋯ 메뉴 (CH-29, 47, 48): 아이콘이 있고 삭제는 빨강
    private func popMenu(_ item: ChatConversation, _ close: @escaping () -> Void) -> some View {
        VStack(spacing: 2) {
            PopRow(icon: item.pinnedAt != nil ? "pin.slash" : "pin", title: item.pinnedAt != nil ? "고정 해제" : "고정") { close(); chat.togglePin(item) }
            PopRow(icon: "pencil", title: "이름 바꾸기") { close(); onRename(item) }
            MoveRow(projects: chat.projects, itemID: "conversation:\(item.id)", close: close)
            Divider().padding(.vertical, 2)
            PopRow(icon: "trash", title: "삭제", color: PopRow.red) { close(); onDelete(item) }
        }.padding(6).frame(width: 190)
    }
}

/// 팝업 메뉴 한 줄: 높이 28, 둥글기 6, 커서를 올리면 rowHover
struct PopRow: View {
    static let red = Color(hex: 0xD0392B)
    let icon: String?
    let title: String
    var color: Color = Brand.text
    var chevron = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon { Image(systemName: icon).font(.system(size: 12)).frame(width: 14) }
                Text(title).font(Brand.suit(12)).lineLimit(1)
                Spacer(minLength: 6)
                if chevron { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Brand.gray) }
            }
            .foregroundStyle(color)
            .padding(.horizontal, 8).frame(height: 28).frame(maxWidth: .infinity)
            .background(hover ? ChatPalette.rowHover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover = $0 }
    }
}

/// 프로젝트로 옮기기 › : 오른쪽에 프로젝트 목록 팝업
private struct MoveRow: View {
    @ObservedObject var projects: ProjectState
    let itemID: String
    let close: () -> Void
    @State private var show = false
    private var currentID: String? { projects.items.first(where: { $0.id == itemID })?.projectID }

    var body: some View {
        PopRow(icon: "folder", title: "프로젝트로 옮기기", chevron: true) { show.toggle() }
            .popover(isPresented: $show, arrowEdge: .trailing) {
                VStack(spacing: 2) {
                    ForEach(projects.projects) { project in
                        PopRow(icon: nil, title: project.title, color: project.id == currentID ? Brand.gray : Brand.text) {
                            show = false; close(); projects.move(itemID, to: project.id)
                        }.disabled(project.id == currentID)
                    }
                    if !projects.projects.isEmpty { Divider().padding(.vertical, 2) }
                    PopRow(icon: nil, title: "일반 채팅으로 옮기기", color: currentID == nil ? Brand.gray : Brand.text) {
                        show = false; close(); projects.move(itemID, to: nil)
                    }.disabled(currentID == nil)
                }.padding(6).frame(width: 190)
            }
    }
}

private struct ConversationRow<Context: View, Pop: View>: View {
    let item: ChatConversation
    let isCurrent: Bool
    let isBusy: Bool
    let open: () -> Void
    @ViewBuilder var context: () -> Context
    @ViewBuilder var pop: (@escaping () -> Void) -> Pop
    @State private var hovering = false
    @State private var menuOpen = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                Text(item.title).font(Brand.suit(13)).foregroundStyle(isCurrent ? Brand.ink : Brand.tabText)
                    .lineLimit(1).padding(.leading, 10)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if isBusy {
                // CH-14: 응답이 도는 대화는 메뉴 자리에 스피너 (메뉴는 오른쪽 클릭으로)
                ProgressView().controlSize(.small).frame(width: 28, height: 30)
            } else {
                Button { menuOpen.toggle() } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Brand.tabText)
                        .frame(width: 28, height: 30).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("대화 메뉴")
                    .opacity(hovering || menuOpen ? 1 : 0)
                    .popover(isPresented: $menuOpen, arrowEdge: .bottom) { pop { menuOpen = false } }
            }
        }
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering || menuOpen ? Color.white.opacity(0.6) : (isCurrent ? Color.white.opacity(0.4) : .clear)))
        .onHover { hovering = $0 }
        .contextMenu { context() }
    }
}
