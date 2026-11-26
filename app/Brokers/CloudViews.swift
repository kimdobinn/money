import SwiftUI

/// "다른 Mac에서 · 3분 전" — shown instead of the update time while viewing cloud data.
struct CloudSyncLabel: View {
    @EnvironmentObject var model: AppModel
    var short = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let age = model.cloudUpdated.map { Date().timeIntervalSince($0) } ?? .infinity
            let stale = age > 300
            Label(short ? Fmt.relative(model.cloudUpdated) : "다른 Mac에서 · \(Fmt.relative(model.cloudUpdated))",
                  systemImage: stale ? "icloud.slash" : "icloud")
                .foregroundStyle(stale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .help(stale
                      ? "데이터를 모으는 Mac이 \(Fmt.stamp(model.cloudUpdated)) 이후로 올리지 않았어요 (꺼져 있거나 오프라인)"
                      : "Google 계정으로 동기화된 데이터 · 보기 전용")
        }
    }
}

struct CloudSignInButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button { Task { await model.signInCloud() } } label: {
            HStack(spacing: 6) {
                if model.signingIn { ProgressView().controlSize(.small) } else { Image(systemName: "person.crop.circle.badge.plus") }
                Text(model.signingIn ? "브라우저에서 로그인 중…" : "Google로 로그인")
            }
        }
        .disabled(model.signingIn || CloudConfig.shared == nil)
    }
}

/// Shown on a Mac without a helper: sign in to view another Mac's numbers.
struct CloudViewerPrompt: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("다른 Mac의 데이터 보기", systemImage: "icloud").font(.s(.headline))
            if let s = model.cloud {
                Text("\(s.email ?? "Google 계정")으로 로그인됨").font(.s(.callout)).foregroundStyle(.secondary)
                if let e = model.cloudError {
                    Text(e).font(.s(.caption)).foregroundStyle(.orange)
                    Button("다시 시도") { Task { await model.refreshNow() } }
                } else {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("불러오는 중…").font(.s(.callout)) }
                }
            } else {
                Text("데이터를 모으는 Mac과 같은 Google 계정으로 로그인하면 여기서도 같은 숫자를 볼 수 있어요.")
                    .font(.s(.callout)).foregroundStyle(.secondary)
                CloudSignInButton()
            }
        }
    }
}

struct CloudTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Google 계정") {
                if let s = model.cloud {
                    HStack {
                        Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary)
                        Text(s.email ?? "Google 계정")
                        Spacer()
                        Button("로그아웃") { Task { await model.signOutCloud() } }
                    }
                } else if CloudConfig.shared == nil {
                    Text("이 빌드에는 클라우드 설정(cloud-config.json)이 없어서 동기화를 쓸 수 없어요.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("로그인하면 다른 Mac에서도 같은 숫자를 볼 수 있어요.").foregroundStyle(.secondary)
                        Spacer()
                        CloudSignInButton()
                    }
                }
            }

            if model.cloud != nil {
                Section("이 Mac의 역할") { role }
            }

            Section {
                Text("올라가는 것: 보유 종목, 자산 추이, 관심 종목, 목표, 하루 한 장 스냅샷. 증권사 API 키와 토큰은 올라가지 않아요. 저장된 데이터는 로그인한 본인 계정만 읽을 수 있어요.")
                    .font(.s(.caption)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var role: some View {
        if model.cloudMode {
            Label("보기 전용 — 다른 Mac이 올린 데이터를 보여줘요", systemImage: "eye")
            LabeledContent("마지막 업로드", value: "\(Fmt.stamp(model.cloudUpdated)) · \(Fmt.relative(model.cloudUpdated))")
            if let e = model.cloudError { Text(e).font(.s(.caption)).foregroundStyle(.orange) }
        } else if model.helperReachable {
            let c = model.status?.cloud
            Label("데이터 수집 — 1분마다 클라우드에 올려요", systemImage: "icloud.and.arrow.up")
            LabeledContent("마지막 업로드",
                           value: c?.lastSync.map { "\(Fmt.stamp($0)) · \(Fmt.relative($0))" } ?? "아직 없음")
            if let e = c?.error { Text(e).font(.s(.caption)).foregroundStyle(.orange) }
        } else if let e = model.cloudError {
            Text(e).font(.s(.caption)).foregroundStyle(.orange)
        } else {
            Text("확인 중…").foregroundStyle(.secondary)
        }
    }
}
