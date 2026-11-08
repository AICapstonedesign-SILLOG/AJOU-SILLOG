import SwiftUI
import AppKit
import WorkGraphCore

/// 스킬 목록과 상세 팝업 (Figma CH-59, 61, 63~68, 74, 75). 맞춤 설정 화면이 띄운다.
struct SkillCatalogView: View {
    @ObservedObject var chat: ChatState
    var onStart: (String) -> Void

    @State private var query = ""
    @State private var selected: ChatSkill?

    private var shown: [ChatSkill] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? chat.skills : chat.skills.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.summary.localizedCaseInsensitiveContains(q) }
    }

    private func count(_ id: String) -> Int { chat.conversations.filter { $0.skillIDs.contains(id) }.count }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("스킬").font(Brand.suit(22, .medium)).foregroundStyle(Brand.ink)
                        Text("답변에 쓸 작업 방식이에요. 여러 개를 함께 쓸 수 있어요.").font(Brand.suit(12)).foregroundStyle(Brand.gray)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Brand.gray)
                        TextField("스킬 검색", text: $query).textFieldStyle(.plain).font(Brand.suit(12))
                    }
                    .padding(.horizontal, 12).frame(width: 190, height: 30)
                    .overlay(Capsule().strokeBorder(Brand.line))
                }
                if shown.isEmpty {
                    Text("맞는 스킬이 없어요").font(Brand.suit(12)).foregroundStyle(Brand.gray).padding(.top, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible())], spacing: 8) {
                        ForEach(shown) { skill in row(skill) }
                    }.padding(.top, 28)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32).padding(.top, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let skill = selected {
                Color.black.opacity(0.18).onTapGesture { selected = nil }
                SkillDetailSheet(skill: skill, close: { selected = nil }) { selected = nil; onStart(skill.id) }
            }
        }
        .background(Color.white)
    }

    private func row(_ skill: ChatSkill) -> some View {
        SkillRow(skill: skill, count: count(skill.id)) { selected = skill }
    }
}

private struct SkillRow: View {
    let skill: ChatSkill
    let count: Int
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: skill.icon).font(.system(size: 13)).foregroundStyle(Brand.tabText)
                    .frame(width: 30, height: 30)
                    .background(Brand.paper, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Brand.line))
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.title).font(Brand.suit(12, .medium)).foregroundStyle(Brand.tabText)
                    Text(skill.summary).font(Brand.suit(10)).foregroundStyle(Brand.gray).lineLimit(1)
                }
                Spacer(minLength: 6)
                if count > 0 { Text("대화 \(count)개").font(Brand.suit(10)).foregroundStyle(Brand.gray) }
            }
            .padding(.horizontal, 6).frame(height: 44)
            .background(hover ? ChatPalette.rowHover : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover = $0 }
    }
}

private struct SkillDetailSheet: View {
    let skill: ChatSkill
    let close: () -> Void
    let start: () -> Void
    @State private var menuOpen = false

    var body: some View {
        let detail = SkillDetail.all[skill.id]
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: skill.icon).font(.system(size: 18)).foregroundStyle(Brand.tabText)
                    .frame(width: 42, height: 42)
                    .background(Brand.paper, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.line))
                Spacer()
                ChatIconButton(systemName: "ellipsis", help: "더보기") { menuOpen.toggle() }
                    .popover(isPresented: $menuOpen, arrowEdge: .bottom) {
                        PopRow(icon: "doc.on.doc", title: "지침 복사") {
                            menuOpen = false
                            if let text = try? skill.instructions() {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                            }
                        }.padding(6).frame(width: 150)
                    }
                ChatIconButton(systemName: "xmark", help: "닫기", action: close)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(skill.title).font(Brand.suit(20, .bold)).foregroundStyle(Brand.ink)
                Text("스킬").font(Brand.suit(16)).foregroundStyle(Brand.gray)
            }.padding(.top, 10)
            Text(detail?.description ?? skill.summary).font(Brand.suit(13)).foregroundStyle(Brand.gray)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array((detail?.sections ?? []).enumerated()), id: \.offset) { i, section in
                        Text(section.title).font(Brand.suit(12, .medium)).foregroundStyle(Brand.ink)
                            .padding(.top, i == 0 ? 0 : 16).padding(.bottom, 8)
                        ForEach(section.lines, id: \.self) { line in
                            Text(line).font(Brand.suit(12)).foregroundStyle(Brand.tabText)
                                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 6)
                        }
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(hex: 0xF8F7F5), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 14)
            HStack {
                Spacer()
                Button(action: start) {
                    Text("이 스킬로 새 대화").font(Brand.suit(12, .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 28).background(Brand.accent, in: Capsule())
                }.buttonStyle(.plain)
            }.padding(.top, 14)
        }
        .padding(24).frame(width: 520, height: 600)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
    }
}

/// 팝업의 설명과 내용: Figma CH-61, 64~68 글자 그대로
private struct SkillDetail {
    struct Section { let title: String; let lines: [String] }
    let description: String
    let sections: [Section]

    static let all: [String: SkillDetail] = [
        "writing": .init(description: "보고서, 진행 보고, 제안서, 포트폴리오, 회고를 쓸 때 써요. 기록을 근거로 쓰고, 근거가 없는 곳은 비워 두고 표시해요.", sections: [
            .init(title: "문서별로 이렇게 써요", lines: [
                "업무 보고: 현황, 결정이 필요한 사항, 위험, 지난 보고 뒤 바뀐 점을 앞에 둬요.",
                "중간·최종 보고서: 양식을 그대로 따르고, 근거가 없는 곳은 [확인 필요]로 남겨요.",
                "제안서: 기록에 근거한 문제, 제안, 비슷한 지난 업무로 잡은 예상 공수, 위험을 담아요.",
                "포트폴리오: 상황, 내가 한 일, 확인된 결과 순으로 써요."]),
            .init(title: "끝내기 전에 확인해요", lines: [
                "문서 종류와 독자에 맞는지", "요약에 현황과 독자에게 요청할 일이 있는지", "내가 했다고 쓴 일마다 작성 근거가 있는지",
                "양식이나 공고의 요구 사항을 확인했는지", "남은 항목이 보이게 적혀 있는지"])]),
        "research": .init(description: "질문을 조사하고, 선택지를 비교하고, 근거를 모을 때 써요. 내 상황에서 나온 기준으로 답해요.", sections: [
            .init(title: "답변에 이런 걸 담아요", lines: [
                "질문과 답: 답을 한 문단으로 쓰고, 확신 정도와 근거를 함께 적어요.",
                "비교: 내 기준으로 표를 만들고, 칸마다 출처를 달아요.",
                "근거: 자료마다 출처의 강도와 날짜를 적어요.",
                "상충·불확실: 자료끼리 다른 곳과 그 이유를 적어요.",
                "내 상황에 대한 함의: 결과가 내 프로젝트와 결정에 뜻하는 바를 적어요."]),
            .init(title: "끝내기 전에 확인해요", lines: [
                "바로 답했는지", "기준이 내 상황에서 나왔는지", "중요한 주장을 원문과 날짜로 확인했는지", "자료끼리 다른 곳을 적었는지",
                "함의가 내 기록과 이어지는지", "전에 본 자료를 반영했는지", "남은 질문을 적었는지"])]),
        "planning": .init(description: "프로젝트 계획, 요구사항 문서, 우선순위, 로드맵, 일정을 만들 때 써요. 일이 실제로 어디까지 왔는지에서 시작해요.", sections: [
            .init(title: "계획에 이런 걸 담아요", lines: [
                "목표와 완료 조건: 업무 목표나 요구 자료에서 가져와 잴 수 있게 써요.",
                "현재 상태: 끝난 일(근거 포함), 진행 중, 요청됨, 시작 전으로 나눠요.",
                "작업 분해: 선행 작업과 예상 공수를 근거와 함께 적어요.",
                "일정: 자료의 날짜를 쓰거나 예상 공수에서 계산해요.",
                "위험과 대응: 풀리지 않은 문제, 외부 의존, 빠듯한 예상에서 찾아요.",
                "지금 할 일: 다시 열 파일이나 페이지와 함께 첫 단계를 적어요."]),
            .init(title: "끝내기 전에 확인해요", lines: [
                "현재 상태에 근거가 있는지", "예상마다 근거가 있는지", "의존과 위험에 출처가 있는지", "지어낸 날짜가 없는지", "지금 시작할 첫 단계가 있는지"])]),
        "learning": .init(description: "개념 설명, 공부 자료, 연습 문제, 피드백이 필요할 때 써요. 내 자료를 바탕으로 내 수준에 맞춰 설명해요.", sections: [
            .init(title: "공부 자료에 이런 걸 담아요", lines: [
                "지금까지 본 내용: 기록에서 확인한 내용과 본 때를 적어요.",
                "핵심 개념: 내 파일이나 프로젝트의 예로 설명해요.",
                "막혔던 부분: 기록에서 보이는 헷갈림과 맞는 설명을 적어요.",
                "연습 문제: 내 자료로 쉬운 순서대로 만들고, 답은 맨 뒤에 둬요.",
                "다음 단계: 저장만 하고 거의 안 본 자료부터 권해요."]),
            .init(title: "끝내기 전에 확인해요", lines: [
                "설명이 내 자료와 이어지는지", "막힐 만한 곳을 다루고 추정임을 표시했는지", "이해했는지 스스로 확인할 방법이 있는지", "다음 단계가 있는지"])]),
        "content": .init(description: "블로그 글, 발표, 소개 페이지처럼 읽을 사람이 정해진 글을 만들 때 써요. 기록에 남은 실제 이야기로 써요.", sections: [
            .init(title: "이렇게 만들어요", lines: [
                "블로그 글(Markdown): 기록의 구체적인 순간으로 시작해 이야기를 풀고, 배운 점과 참고 자료로 끝내요.",
                "발표 자료(HTML): 장마다 메시지 하나를 제목에 쓰고 근거를 넣고, 끝에 발표 메모를 둬요.",
                "소개 페이지(HTML), 대본과 문구(TXT)도 만들 수 있어요.",
                "일화, 인용, 결과는 지어내지 않아요."]),
            .init(title: "끝내기 전에 확인해요", lines: [
                "열어 볼 수 있는 결과물이 있는지", "메시지가 하나로 분명한지", "날짜 있는 기록으로 이야기를 만들었는지",
                "사실을 따라가 확인할 수 있는지", "말투가 내 말투와 맞는지", "요청하지 않은 비공개 내용이 없는지"])]),
        "automation": .init(description: "반복 보고서, 모니터링, 주기적인 요약을 예약할 때 써요. 먼저 한 번 실행해 보여 주고, 승인하면 예약해요.", sections: [
            .init(title: "예약 지침에 이런 걸 담아요", lines: [
                "기간: 실행 시점 기준으로 적어요. 예: 지난 7일",
                "자료: 첫 실행에서 찾은 업무, 프로젝트, 파일 이름을 적어요.",
                "목차와 제목: 실행마다 같은 틀로 쓰게 정해요.",
                "지난 실행과 비교: 지난 보고서를 찾아 바뀐 점을 앞에 둬요.",
                "바뀐 것이 없을 때: 확인한 범위와 변경 없음만 짧게 적어요."]),
            .init(title: "끝내기 전에 확인해요", lines: [
                "한 번 실행한 결과를 보여 줬는지", "기간, 자료, 목차, 변경 규칙이 지침에 다 있는지", "내가 승인할 수 있는 제안인지"])]),
    ]
}
