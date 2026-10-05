import SwiftUI
import AppKit

/// The About page: a centered app hero, project links, a privacy note, and the
/// GPL attribution to the upstream project this app is derived from.
struct AboutPage: View {
    private static let brandTint  = Color(red: 0.16, green: 0.17, blue: 0.20)

    private var versionString: String {
        String(format: L("about.version.format"), Brand.version, Brand.build)
    }

    private var repoURL: URL { Brand.repoURL ?? Brand.projectURL }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    // Pre-scaled to exactly 84pt, like the sidebar's AppLogo34.
                    Image("AppLogo84")
                    Text(Brand.name).font(.title2).fontWeight(.bold)
                    Text(versionString).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                Text(L("popbar.about.body"))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }

            Section {
                linkRow(asset: "GitHubLogo", tint: Self.brandTint,
                        title: L("GitHub Repository"), url: repoURL)
                linkRow(systemImage: "arrow.down.circle", tint: .blue,
                        title: L("about.releases.title"),
                        url: repoURL.appendingPathComponent("releases"))
                linkRow(systemImage: "doc.text", tint: .gray,
                        title: L("about.license.title"),
                        url: repoURL.appendingPathComponent("blob/main/LICENSE"))
            }

            Section {
                Text(L("about.derived.notice"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("about.privacy.notice"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Text(L("about.copyright"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("About"))
    }

    private func linkRow(asset: String? = nil, systemImage: String? = nil,
                         tint: Color, title: String, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 10) {
                if let asset {
                    AssetIconTile(asset: asset, color: tint)
                } else if let systemImage {
                    IconTile(symbol: systemImage, color: tint)
                }
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
