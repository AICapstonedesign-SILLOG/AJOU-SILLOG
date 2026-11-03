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

    @State private var inputHeight: CGFloat = 38
    @State private var showPlus = false
    @State private var showSkills = false
    @State private var showSources = false
    @State private var showLibraryPicker = false
    @State private var sourceOptionsHeight: CGFloat = 552   // 참고할 자료 설정 내용 높이 (CH-31, 600까지만 키우고 넘치면 스크롤)

    /// 이 대화에 응답이 도는 중이면 자료 설정을 잠근다
    private var busy: Bool { chat.activeMessage?.conversationID == chat.current.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            box
            HStack(spacing: 0) {
                ChatFocusButton(chat: chat).padding(.leading, 12)
                Spacer(minLength: 8)
                if !modelName.isEmpty { ChatModelMenu(name: modelName, fontSize: 11, openSettings: openSettings).padding(.trailing, 12) }
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
                // CH-18: 첨부 칩은 입력 줄 위에 줄바꿈으로 놓이고 상자가 위로 커진다. 연결한 폴더에만 빼기(x), 파일은 참고할 자료 설정에서 연결 해제
                ChatChipFlow(spacing: 6) {
                    ForEach(attachments) { item in attachmentChip(icon: "doc", text: item.title, help: item.title) }
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
        .background { Color.clear.popover(isPresented: $showSources, arrowEdge: .bottom) { sourceOptions } }
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
            MenuRow(icon: "sparkles", title: "스킬") { showSkills = true } trailing: {
                Text(skillName).font(Brand.suit(11)).foregroundStyle(Brand.gray).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Brand.gray)
            }
            .popover(isPresented: $showSkills, arrowEdge: .trailing) { skillList }
            MenuRow(icon: "globe", title: "웹 검색") { chat.current.scope.useWeb.toggle() } trailing: {
                WebSwitch(on: chat.current.scope.useWeb)
            }
            Rectangle().fill(Brand.line).frame(height: 1).padding(.vertical, 4)
            MenuRow(icon: "slider.horizontal.3", title: "참고할 자료 설정") {
                showPlus = false; DispatchQueue.main.async { showSources = true }
            }
        }
        .padding(6).frame(width: 190)
    }

    private var skillName: String {
        guard chat.current.skillID != "general" else { return "자동 선택" }
        return chat.skills.first(where: { $0.id == chat.current.skillID })?.title ?? "자동 선택"
    }

    private var skillList: some View {
        VStack(alignment: .leading, spacing: 0) {
            skillRow("자동 선택", on: chat.current.skillID == "general") { chat.current.skillID = "general" }
            ForEach(chat.skills) { skill in
                skillRow(skill.title, on: chat.current.skillID == skill.id) { chat.current.skillID = skill.id }
            }
        }
        .padding(6).frame(minWidth: 112)
    }

    private func skillRow(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        MenuRow(icon: nil, title: title) { action(); showSkills = false; showPlus = false } trailing: {
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

    // MARK: 참고할 자료 설정

    private var sourceOptions: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 13) {
            Text("답변에 사용할 자료").font(Brand.suit(13, .medium)).foregroundStyle(Brand.ink)
            Toggle("내 활동 기록", isOn: Binding(get: { chat.current.scope.useActivity },
                                             set: { on in chat.current.scope.useActivity = on; if !on { chat.current.scope.focus = [] } }))
            Toggle("웹 검색 허용", isOn: $chat.current.scope.useWeb)
            Divider()
            Text("플러그인").font(Brand.suit(13, .medium)).foregroundStyle(Brand.ink)
            Toggle("Gmail", isOn: pluginBinding("gmail"))
            Toggle("Google Drive", isOn: pluginBinding("drive"))
            Toggle("GitHub", isOn: githubBinding())
            Toggle("Notion", isOn: pluginBinding("notion"))
            Divider()
            HStack {
                Text("보관 자료").font(Brand.suit(13, .medium)).foregroundStyle(Brand.ink)
                Spacer()
                Menu {
                    Button("파일 업로드") { showSources = false; chat.uploadFiles() }
                    Button("보관함에서 선택") { showSources = false; DispatchQueue.main.async { showLibraryPicker = true } }
                } label: {
                    HStack(spacing: 4) { Text("추가"); Image(systemName: "chevron.down").font(.system(size: 8)) }.sourcePill()
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).disabled(library.busy).fixedSize()
            }
            ForEach(library.sources(conversationID: chat.current.id, projectID: chat.current.projectID)) { item in
                HStack {
                    Text(item.title).font(Brand.suit(10)).lineLimit(2)
                    Spacer()
                    Button("연결 해제") { library.detach(item, conversationID: chat.current.id) }.font(Brand.suit(10)).buttonStyle(.plain)
                }
            }
            if library.busy { ProgressView().controlSize(.small) }
            if let error = library.error { Text(error).font(Brand.suit(10)).foregroundStyle(.red) }
            Divider()
            HStack {
                Text("원본 파일과 폴더 연결").font(Brand.suit(13, .medium)).foregroundStyle(Brand.ink)
                Spacer()
                Button { showSources = false; chat.connectFiles() } label: { Text("추가").sourcePill() }.buttonStyle(.plain)
            }
            if chat.current.scope.paths.isEmpty {
                Text("연결된 자료가 없습니다.").font(Brand.suit(10)).foregroundStyle(Brand.gray)
            } else {
                ForEach(chat.current.scope.paths, id: \.self) { path in
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(Brand.gray)
                        Text(path).font(Brand.suit(10)).lineLimit(2).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button { chat.current.scope.paths.removeAll { $0 == path } } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).help("연결 해제").accessibilityLabel("\(path) 연결 해제")
                    }
                }
            }
            Divider()
            Text("질문·공통 지침·관련 과거 기록과 보관 자료 일부가 모델에 전달됩니다. 추가 원문은 모델이 조회할 때 전송됩니다. 원본 연결은 파일을 복사하지 않습니다.")
                .font(Brand.suit(10)).foregroundStyle(Brand.gray)
            Text("웹 검색은 Codex 또는 OpenAI API를 사용합니다. 플러그인 조회 대상은 선택한 서비스에 전송됩니다.")
                .font(Brand.suit(10)).foregroundStyle(Brand.gray)
            Button("플러그인 둘러보기") { showSources = false; onOpenPlugins() }.buttonStyle(.link)
        }.font(Brand.suit(12)).foregroundStyle(Brand.tabText).padding(20)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sourceOptionsHeight = $0 }
        }.frame(width: 380, height: min(sourceOptionsHeight, 600)).disabled(busy)
    }

    /// Args: id는 대화에서 켜거나 끌 플러그인이다.
    /// Returns: 대화별 플러그인 선택 바인딩. 연결 안 된 플러그인을 켜면 플러그인 화면으로 간다.
    /// Raises: 없음.
    private func pluginBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { chat.current.scope.plugins.contains(id) }, set: { enabled in
            if enabled {
                guard (try? PluginAuth.isConnected(id)) == true else { showSources = false; onOpenPlugins(); return }
                if !chat.current.scope.plugins.contains(id) { chat.current.scope.plugins.append(id) }
            } else { chat.current.scope.plugins.removeAll { $0 == id } }
        })
    }

    /// Args: 없음.
    /// Returns: GitHub 연결 상태를 확인한 뒤 변경하는 대화별 자료 바인딩.
    /// Raises: 없음. 미연결 상태에서는 플러그인 화면으로 간다.
    private func githubBinding() -> Binding<Bool> {
        Binding(get: { chat.current.scope.useGitHub }, set: { enabled in
            if enabled && (try? PluginAuth.isConnected("github")) != true { showSources = false; onOpenPlugins(); return }
            chat.current.scope.useGitHub = enabled
        })
    }
}

extension ChatComposer.MenuRow where Trailing == EmptyView {
    init(icon: String?, title: String, action: @escaping () -> Void) {
        self.init(icon: icon, title: title, action: action) { EmptyView() }
    }
}

/// 참고할 자료 설정 안의 '추가' 단추(CH-31): 글자 11, 높이 22, 흰 바탕에 1pt 테두리, 둥글기 4
private extension View {
    func sourcePill() -> some View {
        font(Brand.suit(11)).foregroundStyle(Brand.ink)
            .padding(.horizontal, 7).frame(height: 22)
            .background(.white, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ChatPalette.inputLine))
            .contentShape(Rectangle())
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
