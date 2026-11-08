import SwiftUI

struct PluginEntry: Identifiable {
    let id: String
    let name: String
    let summary: String
    let description: String
    let examples: [String]

    static let all: [PluginEntry] = [
        .init(id: "gmail", name: "Gmail", summary: "메일 검색과 읽기",
              description: "연결한 계정의 메일을 찾아 읽어요. 메일을 보내거나 수정하지 않아요.",
              examples: ["지난주 받은 메일에서 내가 답해야 할 내용을 정리해 줘.", "최근 프로젝트 관련 메일의 결정 사항을 찾아 줘."]),
        .init(id: "drive", name: "Google Drive", summary: "파일 검색과 문서 읽기",
              description: "Drive에서 파일을 찾고 문서를 읽어요. 파일을 만들거나 수정하지 않아요.",
              examples: ["최근 작성한 기획서를 찾아 핵심 결정을 요약해 줘.", "내 Drive 자료를 바탕으로 발표 개요를 만들어 줘."]),
        .init(id: "github", name: "GitHub", summary: "저장소, 코드와 PR 읽기",
              description: "접근 권한이 있는 저장소의 코드와 PR을 읽어요. 저장소를 변경하지 않아요.",
              examples: ["내가 작업한 저장소의 구조와 주요 기능을 설명해 줘.", "최근 PR을 바탕으로 프로젝트 진행 상황을 정리해 줘."]),
        .init(id: "notion", name: "Notion", summary: "페이지 검색과 읽기",
              description: "통합에 공유한 Notion 페이지를 검색하고 읽어요. 페이지를 수정하지 않아요.",
              examples: ["최근 회의록에서 결정 사항과 다음 할 일을 찾아 줘.", "Notion에 정리한 자료를 바탕으로 계획을 세워줘."])
    ]
}

/// 맞춤 설정의 플러그인 구역: 둘러보기 목록(검색, 설치됨 구역)과 플러그인 상세.
/// 고른 플러그인과 연결 상태는 왼쪽 목록(CustomizeView)과 나눠 쓰므로 바인딩으로 받는다
struct PluginCatalogView: View {
    var onUseInChat: (String, String) -> Void
    @Binding var selectedID: String?
    @Binding var connected: Set<String>

    @State private var query = ""
    @State private var googleSelection: Set<String> = []
    @State private var showGoogleInstall = false
    @State private var connecting = false
    @State private var verificationCode: String?
    @State private var notice: String?
    @State private var showNotice = false

    private static let soft = Brand.paper

    private var selected: PluginEntry? { PluginEntry.all.first { $0.id == selectedID } }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var filtered: [PluginEntry] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? PluginEntry.all : PluginEntry.all.filter {
            $0.name.localizedCaseInsensitiveContains(text) || $0.summary.localizedCaseInsensitiveContains(text)
        }
    }

    var body: some View {
        Group { if let selected { detail(selected) } else { catalog } }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.white)
            .sheet(isPresented: $showGoogleInstall) { googleInstallSheet }
            .alert("플러그인 연결", isPresented: $showNotice) {
                Button("확인", role: .cancel) {}
            } message: { Text(notice ?? "") }
            .onAppear(perform: refresh)
    }

    // MARK: 목록 (CH-13, 70, 72, 73)

    private var catalog: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("플러그인").font(Brand.suit(22, .bold)).foregroundStyle(Brand.ink)
                        Text("외부 서비스를 연결해 채팅에서 내 자료를 활용해요.").font(Brand.suit(12)).foregroundStyle(Brand.gray)
                    }
                    Spacer(minLength: 16)
                    searchField
                }
                if searching {
                    section("검색 결과", filtered, empty: "맞는 플러그인이 없어요")
                } else {
                    let installed = PluginEntry.all.filter { connected.contains($0.id) }
                    if !installed.isEmpty { section("설치됨", installed) }
                    section("플러그인 둘러보기", PluginEntry.all.filter { !connected.contains($0.id) })
                }
            }
            .padding(.horizontal, 32).padding(.top, 20).padding(.bottom, 24)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Brand.gray)
            TextField("플러그인 검색", text: $query).textFieldStyle(.plain).font(Brand.suit(12)).foregroundStyle(Brand.text)
        }
        .padding(.horizontal, 12).frame(width: 190, height: 30)
        .overlay(Capsule().strokeBorder(Brand.line))
    }

    private func section(_ title: String, _ items: [PluginEntry], empty: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Brand.suit(11.5)).foregroundStyle(Brand.tabText).padding(.top, 26).padding(.bottom, 16)
            if items.isEmpty, let empty {
                Text(empty).font(Brand.suit(12)).foregroundStyle(Brand.gray)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 17, alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 26) {
                    ForEach(items) { row($0) }
                }
            }
        }
    }

    /// 아이콘, 이름, 요약, 연결 상태가 있는 한 줄. 누르면 상세로 이동한다.
    private func row(_ plugin: PluginEntry) -> some View {
        let on = connected.contains(plugin.id)
        return Button { selectedID = plugin.id } label: {
            HStack(spacing: 12) {
                pluginIcon(plugin, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.name).font(Brand.suit(12, .medium)).foregroundStyle(Brand.ink)
                    Text(plugin.summary).font(Brand.suit(10)).foregroundStyle(Brand.gray)
                }
                Spacer(minLength: 8)
                if on {
                    Text("설치됨").font(Brand.suit(10, .medium)).foregroundStyle(Brand.tabText)
                } else {
                    Text("연결").font(Brand.suit(11, .medium)).foregroundStyle(Brand.ink)
                        .padding(.horizontal, 12).frame(height: 30)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.line))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: 상세 (CH-25, 26, 37, 62)

    private func detail(_ plugin: PluginEntry) -> some View {
        let on = connected.contains(plugin.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Button { selectedID = nil } label: { Text("플러그인").font(Brand.suit(12)).foregroundStyle(Brand.gray) }.buttonStyle(.plain)
                    Text("›").font(Brand.suit(13)).foregroundStyle(Brand.gray)
                    Text(plugin.name).font(Brand.suit(12, .medium)).foregroundStyle(Brand.ink)
                }
                .padding(.horizontal, 32).padding(.top, 19)
                VStack(alignment: .leading, spacing: 0) {
                    pluginIcon(plugin, size: 48).padding(.top, 21)
                    HStack(spacing: 6) {
                        Text(plugin.name).font(Brand.suit(22, .bold)).foregroundStyle(Brand.ink)
                        Spacer()
                        if on { moreMenu(plugin) }
                        mainButton(plugin, on: on)
                    }.padding(.top, 10)
                    Text(plugin.summary).font(Brand.suit(13)).foregroundStyle(Brand.gray).padding(.top, 4)
                    examplePanel(plugin, on: on).padding(.top, 15)
                    Text(plugin.description).font(Brand.suit(13)).foregroundStyle(Brand.tabText).padding(.top, 18)
                    if let verificationCode, plugin.id == "github" {
                        Text("GitHub 승인 코드: \(verificationCode)")
                            .font(.system(size: 14, design: .monospaced)).foregroundStyle(Brand.ink).textSelection(.enabled)
                            .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .background(Self.soft, in: RoundedRectangle(cornerRadius: 10)).padding(.top, 16)
                    }
                    Text("정보").font(Brand.suit(14, .medium)).foregroundStyle(Brand.ink).padding(.top, 24).padding(.bottom, 8)
                    Rectangle().fill(Brand.line).frame(height: 1)
                    VStack(alignment: .leading, spacing: 10) {
                        infoRow("권한", "읽기만 해요")
                        infoRow("연결 정보", "이 Mac의 키체인에 보관해요")
                        infoRow("제공", ["gmail", "drive"].contains(plugin.id) ? "Google" : plugin.name)
                    }.padding(.top, 11)
                    Text("질문과 조회한 자료는 연결한 AI로 전송돼요.").font(Brand.suit(11)).foregroundStyle(Brand.gray).padding(.top, 22)
                }
                .frame(maxWidth: 561, alignment: .leading).frame(maxWidth: .infinity)
                .padding(.bottom, 32)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label).font(Brand.suit(12)).foregroundStyle(Brand.gray).frame(width: 110, alignment: .leading)
            Text(value).font(Brand.suit(12)).foregroundStyle(Brand.ink)
        }
    }

    /// 주 단추: 설치 전 "플러그인 설치"(연결 중에는 "연결 중…"), 설치됨 "채팅에서 사용해 보기". 글자 폭 알약
    private func mainButton(_ plugin: PluginEntry, on: Bool) -> some View {
        Button { if on { onUseInChat(plugin.id, plugin.examples[0]) } else { install(plugin) } } label: {
            Text(on ? "채팅에서 사용해 보기" : connecting ? "연결 중…" : "플러그인 설치")
                .font(Brand.suit(12, .medium)).foregroundStyle(.white).fixedSize()
                .padding(.horizontal, 14).frame(height: 28)
                .background(Capsule().fill(Brand.accent))
                .contentShape(Capsule())
        }.buttonStyle(.plain).disabled(connecting)
    }

    /// 설치됨일 때만: 다시 연결, 연결 해제(빨강)
    private func moreMenu(_ plugin: PluginEntry) -> some View {
        Menu {
            Button("다시 연결") { install(plugin) }
            Button("연결 해제", role: .destructive) { disconnect(plugin.id) }
        } label: {
            HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Color(hex: 0x4A4541)).frame(width: 3, height: 3) } }
                .frame(width: 28, height: 28).background(Circle().fill(Color.black.opacity(0.04)))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(connecting)
        .accessibilityLabel("더보기")
    }

    /// 예시 질문 판: 새 대화 첫 화면과 같은 바탕에 흰 반투명 줄. 설치 전에 누르면 설치를 시작한다
    private func examplePanel(_ plugin: PluginEntry, on: Bool) -> some View {
        VStack(spacing: 12) {
            ForEach(plugin.examples, id: \.self) { example in
                Button { if on { onUseInChat(plugin.id, example) } else { install(plugin) } } label: {
                    HStack(spacing: 12) {
                        Text(plugin.name).font(Brand.suit(12, .medium)).foregroundStyle(Brand.ink)
                        Text(example).font(Brand.suit(12)).foregroundStyle(Brand.ink).lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 24, height: 24).background(Circle().fill(Brand.pillFill))
                    }
                    .padding(.horizontal, 12).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.78)))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 48).padding(.top, 26).frame(maxWidth: .infinity, minHeight: 160, alignment: .top)
        .background(ChatStartBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// 앱에 포함된 서비스 공식 아이콘.
    private func pluginIcon(_ plugin: PluginEntry, size: CGFloat) -> some View {
        let url = Bundle.main.url(forResource: plugin.id, withExtension: "png", subdirectory: "PluginIcons")
            ?? Bundle.module.url(forResource: plugin.id, withExtension: "png", subdirectory: "PluginIcons")
        let image = url.flatMap { NSImage(contentsOf: $0) } ?? NSImage()
        return Image(nsImage: image).resizable().scaledToFit()
            .frame(width: size * 0.55, height: size * 0.55)
            .frame(width: size, height: size)
            .background(Self.soft, in: RoundedRectangle(cornerRadius: size * 0.23))
            .overlay(RoundedRectangle(cornerRadius: size * 0.23).strokeBorder(Brand.line))
    }

    private var googleInstallSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandPageHeader(title: "설치할 Google 플러그인 선택", detail: "승인할 자료만 골라 주세요. 연결한 뒤에도 각 플러그인을 해제할 수 있어요.") {
                Button { showGoogleInstall = false } label: {
                    Image(systemName: "xmark").font(.system(size: 13)).foregroundStyle(Brand.tabText)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("닫기")
            }
            VStack(spacing: 0) {
                ForEach(PluginEntry.all.filter { ["gmail", "drive"].contains($0.id) }) { plugin in
                    HStack(spacing: 12) {
                        pluginIcon(plugin, size: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(plugin.name).font(Brand.suit(13, .medium)).foregroundStyle(Brand.ink)
                            Text(plugin.summary).font(Brand.suit(10)).foregroundStyle(Brand.gray)
                        }
                        Spacer()
                        Toggle("", isOn: googleBinding(plugin.id)).toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Brand.accentDark)
                    }.padding(.vertical, 16)
                        .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }
                }
            }.padding(.horizontal, 32).padding(.top, 4)
            HStack {
                Spacer()
                Button("Google에서 계속") { showGoogleInstall = false; connectGoogle() }
                    .buttonStyle(BrandButtonStyle(kind: .primary)).disabled(googleSelection.isEmpty)
            }.padding(.horizontal, 32).frame(height: 63).background(Self.soft)
                .overlay(alignment: .top) { Rectangle().fill(Brand.line).frame(height: 1) }
        }.frame(width: 560).background(.white)
    }

    /// Args: id는 Google 플러그인 ID이다.
    /// Returns: 설치 선택 상태 바인딩.
    /// Raises: 없음.
    private func googleBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { googleSelection.contains(id) }, set: { enabled in
            if enabled { googleSelection.insert(id) } else { googleSelection.remove(id) }
        })
    }

    /// Args: plugin은 설치할 서비스이다.
    /// Returns: 없음. Google은 권한 선택을 보여주고 나머지는 공급자 승인을 시작한다.
    /// Raises: 없음. 오류는 화면에 표시한다.
    private func install(_ plugin: PluginEntry) {
        if ["gmail", "drive"].contains(plugin.id) {
            googleSelection = [plugin.id]
            showGoogleInstall = true
            return
        }
        do {
            guard try PluginAuth.isAvailable(plugin.id) else {
                notify("이 빌드에는 \(plugin.name) 연결 정보가 아직 없습니다. 앱 제공자가 OAuth 앱을 등록해야 사용할 수 있습니다.")
                return
            }
        } catch { notify(error.localizedDescription); return }
        connecting = true
        Task {
            do {
                if plugin.id == "github" {
                    let client = try PluginAuth.configuration("github-client", environment: "WORKGRAPH_GITHUB_CLIENT_ID")
                    try await PluginAuth.connectGitHub(clientID: client) { verificationCode = $0 }
                } else {
                    let client = try PluginAuth.configuration("notion-client", environment: "WORKGRAPH_NOTION_CLIENT_ID")
                    let secret = try PluginAuth.configuration("notion-secret", environment: "WORKGRAPH_NOTION_CLIENT_SECRET")
                    try await PluginAuth.connectNotion(clientID: client, clientSecret: secret)
                }
                connected.insert(plugin.id)
            } catch { notify(error.localizedDescription) }
            verificationCode = nil
            connecting = false
        }
    }

    /// Args: 없음. 사용자가 선택한 Google 플러그인을 승인한다.
    /// Returns: 없음. 승인 성공 시 설치됨 상태를 갱신한다.
    /// Raises: 없음. OAuth 오류는 화면에 표시한다.
    private func connectGoogle() {
        let ids = googleSelection
        do {
            guard try PluginAuth.isAvailable("gmail") else {
                notify("이 빌드에는 Google 연결 정보가 아직 없습니다. 앱 제공자가 OAuth 앱을 등록해야 사용할 수 있습니다.")
                return
            }
        } catch { notify(error.localizedDescription); return }
        connecting = true
        Task {
            do {
                let client = try PluginAuth.configuration("google-client", environment: "WORKGRAPH_GOOGLE_CLIENT_ID")
                try await PluginAuth.connectGoogle(ids, clientID: client)
                connected.formUnion(ids)
            } catch { notify(error.localizedDescription) }
            connecting = false
        }
    }

    /// Args: id는 연결을 해제할 서비스이다.
    /// Returns: 없음. 저장된 OAuth 토큰을 제거한다.
    /// Raises: 없음. Keychain 오류는 화면에 표시한다.
    private func disconnect(_ id: String) {
        do { try PluginAuth.disconnect(id); connected.remove(id) }
        catch { notify(error.localizedDescription) }
    }

    /// Args: 없음.
    /// Returns: 없음. Keychain에서 설치 상태를 다시 읽는다.
    /// Raises: 없음. Keychain 오류는 화면에 표시한다.
    private func refresh() {
        do { connected = Set(try PluginEntry.all.filter { try PluginAuth.isConnected($0.id) }.map(\.id)) }
        catch { notify(error.localizedDescription) }
    }

    /// Args: message는 사용자에게 보여줄 연결 상태나 오류이다.
    /// Returns: 없음. 알림을 표시한다.
    /// Raises: 없음.
    private func notify(_ message: String) { notice = message; showNotice = true }
}
