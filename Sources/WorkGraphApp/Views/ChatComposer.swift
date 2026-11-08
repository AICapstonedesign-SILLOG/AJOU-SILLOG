import SwiftUI
import WorkGraphCore

/// 채팅 입력: 입력 상자(+ 메뉴, 칩, 보내기) + 아래 줄(범위, 모델) + 안내문. 폭은 ChatPalette.columnWidth
struct ChatComposer: View {
    @ObservedObject var chat: ChatState
    @ObservedObject var library: LibraryState
    var modelName: String
    var openSettings: () -> Void
    var pendingRecords: Int = 0
    var tidyNow: () -> Void = {}
    var onOpenPlugins: () -> Void = {}
    var onSent: () -> Void = {}
    var showsNotice: Bool = true
    var showsSkills: Bool = false

    @EnvironmentObject private var state: AppState
    @State private var inputHeight: CGFloat = 38
    @State private var showPlus = false
    @State private var showFocus = false
    @State private var showPlugins = false
    @State private var showConnect = false
    @State private var showLibraryPicker = false

    /// 이 대화에 응답이 도는 중이면 자료 설정을 잠근다
    private var busy: Bool { chat.activeMessage?.conversationID == chat.current.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            box
            HStack(spacing: 0) {
                if showsSkills { skillChips.padding(.leading, 12) }
                Spacer(minLength: 8)
                if !modelName.isEmpty { connectionButton.padding(.trailing, 12) }
            }
            .frame(height: 20).padding(.top, 8)
            if !chat.current.scope.focus.isEmpty, chat.current.scope.useActivity, pendingRecords > 0 {
                tidyHint.padding(.top, 8).padding(.leading, 12)
            }
            if showsNotice {
                Text("질문과 조회한 자료는 연결한 AI로 전송돼요. 웹 검색과 플러그인은 허용한 범위만 사용해요.")
                    .font(Brand.suit(9)).foregroundStyle(Brand.gray).lineLimit(1)
                    .frame(maxWidth: .infinity).padding(.top, 8)
            }
        }
        .frame(maxWidth: ChatPalette.columnWidth).frame(maxWidth: .infinity)
        .sheet(isPresented: $showLibraryPicker) { LibraryPicker(library: library) { chat.attachLibraryItem($0) } }
    }

    /// 보내기가 시작됐을 때만 알린다 (프로젝트 상세에서 대화로 넘어가는 용도)
    private func send() { if chat.send() { onSent() } }

    static func placeholder(_ scope: ChatScope) -> String {
        guard scope.useActivity, !scope.focus.isEmpty else { return "기록을 바탕으로 무엇을 할까요?" }
        return "\(ChatFocusButton.summary(scope.focus))에 대해 물어보세요"
    }

    // MARK: 입력 상자

    private var box: some View {
        let attachments = library.sources(conversationID: chat.current.id, projectID: chat.current.projectID)
        let paths = chat.current.scope.paths
        return VStack(alignment: .leading, spacing: 0) {
            if !attachments.isEmpty || !paths.isEmpty {
                // CH-18: 첨부 칩은 입력 줄 위에 줄바꿈으로 놓이고 상자가 위로 커진다. 모두 x 로 연결 해제
                ChatChipFlow(spacing: 6) {
                    ForEach(attachments) { item in
                        attachmentChip(icon: "doc", text: item.title, help: item.title) { library.detach(item, conversationID: chat.current.id) }
                    }
                    ForEach(paths, id: \.self) { path in
                        attachmentChip(icon: "folder", text: URL(fileURLWithPath: path).lastPathComponent, help: path) {
                            chat.current.scope.paths.removeAll { $0 == path }
                        }
                    }
                }.padding(.top, 12).padding(.horizontal, 13)
            }
            ZStack(alignment: .topLeading) {
                if chat.draft.isEmpty {
                    Text(Self.placeholder(chat.current.scope))
                        .font(Brand.suit(12)).foregroundStyle(Brand.text.opacity(0.5)).lineLimit(1)
                        .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                }
                ChatInput(text: $chat.draft, height: $inputHeight, minimumHeight: 38, focusRequest: chat.inputFocusRequest, onSend: send)
                    .frame(height: inputHeight)
            }
            .padding(.top, 18).padding(.horizontal, 13)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                plusButton
                chips
                Spacer(minLength: 0)
                sendButton
            }
            .padding(.horizontal, 13).padding(.bottom, 11).padding(.top, 4)
        }
        .frame(minHeight: 96)
        .fixedSize(horizontal: false, vertical: true)   // 남는 세로 공간을 차지하지 않게: 글이 늘 때만 커진다 (Figma 96)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ChatPalette.inputLine))
    }

    private var plusButton: some View {
        Button { showPlus = true } label: {
            Image(systemName: "plus").font(.system(size: 16)).foregroundStyle(Brand.tabText)
                .frame(width: 20, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(busy || library.busy)
        .help("자료 추가").accessibilityLabel("자료 추가")
        .popover(isPresented: $showPlus, arrowEdge: .bottom) { plusMenu }
        .background { Color.clear.popover(isPresented: $showFocus, arrowEdge: .bottom) { ChatFocusPicker(chat: chat) } }
    }

    private var sendButton: some View {
        let empty = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button {
            if chat.running { chat.cancel() } else { send() }
        } label: {
            Image(systemName: chat.running ? "stop.fill" : "arrow.up")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Brand.accent.opacity(chat.running || !empty ? 1 : 0.3), in: Circle())
        }
        .buttonStyle(.plain).disabled(!chat.running && empty)
        .help(chat.running ? "응답 중단" : "전송 (Enter)").accessibilityLabel(chat.running ? "응답 중단" : "전송")
    }

    // MARK: 칩 (웹 검색, 첨부)

    /// 첨부 칩(CH-18): 옅은 바탕, 1pt 테두리, 둥글기 4, 높이 22
    private func attachmentChip(icon: String, text: String, help: String, remove: (() -> Void)? = nil) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(Brand.suit(10)).lineLimit(1)
            if let remove {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)) }
                    .buttonStyle(.plain).disabled(busy).help("빼기").accessibilityLabel("\(text) 빼기")
            }
        }
        .foregroundStyle(Brand.tabText)
        .padding(.horizontal, 7).frame(height: 22)
        .background(ChatPalette.soft, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Brand.line))
        .help(help)
    }

    private func chip(icon: String, text: String, help: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(Brand.suit(11)).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)) }
                .buttonStyle(.plain).disabled(busy).help("빼기").accessibilityLabel("\(text) 빼기")
        }
        .foregroundStyle(Brand.chipSelectedText)
        .padding(.horizontal, 9).frame(height: 22)
        .background(Brand.chipSelectedFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Brand.chipSelectedBorder, lineWidth: 1))
        .help(help)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if !chat.current.scope.focus.isEmpty || !chat.current.scope.useActivity {
                    chip(icon: "diamond", text: ChatFocusButton.label(chat.current.scope, choices: chat.focusChoices), help: "범위 빼기") {
                        chat.current.scope.focus = []; chat.current.scope.useActivity = true
                    }
                }
                if chat.current.scope.useWeb {
                    chip(icon: "globe", text: "웹 검색", help: "웹 검색 끄기") { chat.current.scope.useWeb = false }
                }
                if library.busy {
                    ProgressView().controlSize(.small)
                    Text("소스를 추가하고 있어요").font(Brand.suit(10)).foregroundStyle(Brand.gray)
                }
            }
        }
        .frame(height: 22)
    }

    // MARK: + 메뉴

    private var plusMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(icon: "square.and.arrow.up", title: "파일 업로드") { showPlus = false; chat.uploadFiles() }
            MenuRow(icon: "archivebox", title: "보관함에서 선택") { showPlus = false; DispatchQueue.main.async { showLibraryPicker = true } }
            MenuRow(icon: "folder.badge.plus", title: "원본 파일과 폴더 연결") { showPlus = false; chat.connectFiles() }
            Rectangle().fill(Brand.line).frame(height: 1).padding(.vertical, 4)
            MenuRow(icon: "diamond", title: "참고할 기록") { showPlus = false; DispatchQueue.main.async { showFocus = true } } trailing: {
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Brand.gray)
            }
            MenuRow(icon: "globe", title: "웹 검색") { chat.current.scope.useWeb.toggle() } trailing: {
                WebSwitch(on: chat.current.scope.useWeb)
            }
            MenuRow(icon: "puzzlepiece.extension", title: "플러그인") { showPlugins = true } trailing: {
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Brand.gray)
            }
            .popover(isPresented: $showPlugins, arrowEdge: .trailing) { pluginMenu }
        }
        .padding(6).frame(width: 190)
    }

    /// CH-31, CH-71: 플러그인 스위치 넷과 둘러보기
    private var pluginMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            pluginRow("Gmail", "envelope", pluginBinding("gmail"))
            pluginRow("Google Drive", "externaldrive", pluginBinding("drive"))
            pluginRow("GitHub", "chevron.left.forwardslash.chevron.right", githubBinding())
            pluginRow("Notion", "doc.text", pluginBinding("notion"))
            Rectangle().fill(Brand.line).frame(height: 1).padding(.vertical, 4)
            MenuRow(icon: "square.grid.2x2", title: "플러그인 둘러보기") { showPlugins = false; showPlus = false; onOpenPlugins() }
        }
        .padding(6).frame(width: 190)
    }

    private func pluginRow(_ title: String, _ icon: String, _ on: Binding<Bool>) -> some View {
        MenuRow(icon: icon, title: title) { on.wrappedValue.toggle() } trailing: { WebSwitch(on: on.wrappedValue) }
    }

    // MARK: 스킬 칩 (CH-01, CH-33)

    private var skillChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chat.skills) { skill in
                    let on = chat.current.skillIDs.contains(skill.id)
                    Button {
                        if on { chat.current.skillIDs.removeAll { $0 == skill.id } } else { chat.current.skillIDs.append(skill.id) }
                    } label: {
                        Text(skill.title).font(Brand.suit(10)).lineLimit(1)
                            .foregroundStyle(on ? Brand.chipSelectedText : Brand.tabText)
                            .padding(.horizontal, 9).frame(height: 22)
                            .background(on ? Brand.chipSelectedFill : ChatPalette.soft, in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? Brand.chipSelectedBorder : Brand.line))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain).disabled(busy).accessibilityLabel("\(skill.title) \(on ? "끄기" : "켜기")")
                }
            }
        }
        .frame(height: 22)
    }

    // MARK: 연결과 모델 (CH-08)

    private var connectHost: String { URL(string: state.settings.chatEndpoint.url)?.host?.lowercased() ?? "" }
    private var connectLabel: String {
        let provider = state.settings.effectiveChatProvider
        if provider == "codex" {
            if case .loggedIn(_, let plan, _) = state.codexStatus, let plan, !plan.isEmpty { return "ChatGPT \(plan.prefix(1).uppercased() + plan.dropFirst())" }
            return "ChatGPT"
        }
        if provider == "ajou" { return "아주대 LLM API" }
        return connectHost.contains("anthropic") ? "Claude API" : "API"
    }

    @ViewBuilder private func providerLogo(_ provider: String, claude: Bool = false) -> some View {
        if provider == "codex", let mark = Brand.openAIMark {
            Image(nsImage: mark).renderingMode(.template).resizable().scaledToFit().foregroundStyle(Color(hex: 0x4A3E37))
        } else if provider == "ajou", let emblem = Brand.ajouEmblem {
            Image(nsImage: emblem).resizable().scaledToFit().scaleEffect(14 / 13)
        } else if claude {
            SVGIcon(d: Brand.claudePath).fill(Color(hex: 0xD97757))
        } else {
            SVGIcon(d: RailIcon.link).stroke(Brand.tabText, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    private var connectionButton: some View {
        Button { showConnect = true } label: {
            HStack(spacing: 6) {
                providerLogo(state.settings.effectiveChatProvider, claude: connectHost.contains("anthropic")).frame(width: 13, height: 13)
                Text(connectLabel).font(Brand.suit(11, .medium)).foregroundStyle(Color(hex: 0x4A3E37))
                Rectangle().fill(Color(hex: 0xCFC8C1)).frame(width: 1, height: 10)
                Text(modelName).font(Brand.suit(11)).foregroundStyle(Color(hex: 0x7A716B)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundStyle(Brand.tabText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize().help("연결 방식 바꾸기")
        .popover(isPresented: $showConnect, arrowEdge: .top) { connectMenu }
    }

    /// 방식을 고르는 곳은 설정 AI 연결이라, 줄을 누르면 그 방식을 고른 채 설정으로 간다
    private var connectMenu: some View {
        let current = state.settings.effectiveChatProvider
        return VStack(alignment: .leading, spacing: 0) {
            connectRow("ChatGPT 구독", "codex", on: current == "codex")
            connectRow("아주대 LLM API", "ajou", on: current == "ajou")
            connectRow("API", "openai", on: current != "codex" && current != "ajou")
        }
        .padding(6).frame(width: 190)
    }

    private func connectRow(_ title: String, _ provider: String, on: Bool) -> some View {
        MenuRow(icon: nil, title: title) {
            showConnect = false
            state.settings.llmProvider = provider     // 설정의 연결 방식 메뉴와 같은 값
            state.settings.chatProvider = provider
            openSettings()
        } trailing: {
            if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Brand.tabText) }
        }
    }

    /// + 메뉴 한 줄: 24 높이, 둥글기 6, 마우스를 올리면 rowHover
    fileprivate struct MenuRow<Trailing: View>: View {
        let icon: String?
        let title: String
        let action: () -> Void
        @ViewBuilder var trailing: Trailing
        @State private var hover = false

        init(icon: String?, title: String, action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
            self.icon = icon; self.title = title; self.action = action; self.trailing = trailing()
        }

        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    if let icon { Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Brand.tabText).frame(width: 14) }
                    Text(title).font(Brand.suit(12)).foregroundStyle(Brand.text).lineLimit(1)
                    Spacer(minLength: 6)
                    trailing
                }
                .padding(.horizontal, 8).frame(height: 24).frame(maxWidth: .infinity)
                .background(hover ? ChatPalette.rowHover : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).onHover { hover = $0 }
        }
    }

    /// 26×15 스위치 (그림만, 누르는 것은 줄 전체)
    private struct WebSwitch: View {
        let on: Bool
        var body: some View {
            Capsule().fill(on ? Brand.accent : ChatPalette.inputLine).frame(width: 26, height: 15)
                .overlay(alignment: on ? .trailing : .leading) { Circle().fill(.white).frame(width: 11, height: 11).padding(2) }
                .accessibilityLabel(on ? "웹 검색 켬" : "웹 검색 끔")
        }
    }

    // MARK: 범위 아래 안내

    /// 범위를 좁혔을 때: 정리 전 기록은 아직 업무가 없어 빠진다
    private var tidyHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").font(.system(size: 10))
            Text("정리 전 최근 기록 \(pendingRecords)건은 아직 빠져요")
            Button(action: tidyNow) { Text("지금 정리").underline().foregroundStyle(Brand.ink) }.buttonStyle(.plain)
        }
        .font(Brand.suit(10)).foregroundStyle(Brand.gray)
    }

    /// Args: id는 대화에서 켜거나 끌 플러그인이다.
    /// Returns: 대화별 플러그인 선택 바인딩. 연결 안 된 플러그인을 켜면 플러그인 화면으로 간다.
    /// Raises: 없음.
    private func pluginBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { chat.current.scope.plugins.contains(id) }, set: { enabled in
            if enabled {
                guard (try? PluginAuth.isConnected(id)) == true else { showPlugins = false; showPlus = false; onOpenPlugins(); return }
                if !chat.current.scope.plugins.contains(id) { chat.current.scope.plugins.append(id) }
            } else { chat.current.scope.plugins.removeAll { $0 == id } }
        })
    }

    /// Args: 없음.
    /// Returns: GitHub 연결 상태를 확인한 뒤 변경하는 대화별 자료 바인딩.
    /// Raises: 없음. 미연결 상태에서는 플러그인 화면으로 간다.
    private func githubBinding() -> Binding<Bool> {
        Binding(get: { chat.current.scope.useGitHub }, set: { enabled in
            if enabled && (try? PluginAuth.isConnected("github")) != true { showPlugins = false; showPlus = false; onOpenPlugins(); return }
            chat.current.scope.useGitHub = enabled
        })
    }
}

extension ChatComposer.MenuRow where Trailing == EmptyView {
    init(icon: String?, title: String, action: @escaping () -> Void) {
        self.init(icon: icon, title: title, action: action) { EmptyView() }
    }
}

/// 칩을 폭 안에서 왼쪽부터 채우고 넘치면 다음 줄로 넘긴다
struct ChatChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1] = (last.indices + [index], last.width + spacing + size.width, max(last.height, size.height))
            } else {
                rows.append(([index], min(size.width, width), size.height))
            }
        }
        return rows
    }
}
