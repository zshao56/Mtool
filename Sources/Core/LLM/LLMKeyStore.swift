import Foundation

/// Store for the LLM API keys: **one key per provider** in the Keychain, account
/// `llm-key-<provider>`. The One Source of Truth for the keys.
///
/// Keys live HERE and never in the config file. The config file is meant to be
/// opened in an editor, diffed and committed to a dotfiles repo, and a secret in
/// such a file leaks the moment the repo is pushed. The service name comes from
/// `Brand`, off the suffix-free base id, so a Debug build and a Release build
/// share one set of keys.
struct LLMKeyStore {

    private static let log = FileLog("LLM.Keys")

    static var service: String { Brand.keychainService }

    private static let keychain = KeychainStore(service: Brand.keychainService)
    private static func keyAccount(_ provider: String) -> String { "llm-key-\(provider)" }

    // MARK: - Read / write (per provider)

    /// The stored key for a provider, or "" if none. Never throws — absence is "".
    func key(for provider: String) -> String {
        Self.keychain.get(Self.keyAccount(provider)) ?? ""
    }

    func hasKey(for provider: String) -> Bool {
        !key(for: provider).isEmpty
    }

    /// Store (or replace) a provider's key. Returns nil on success, else a message.
    @discardableResult
    func save(_ key: String, for provider: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            try Self.keychain.set(trimmed, account: Self.keyAccount(provider))
            Self.log.info("API key saved for \(provider)")
            return nil
        } catch {
            Self.log.error("keychain save failed for \(provider): \(error)")
            return "\(error)"
        }
    }

    func clear(for provider: String) {
        Self.keychain.remove(Self.keyAccount(provider))
        Self.log.info("API key cleared for \(provider)")
    }

    /// The set of providers that currently have a key — drives the settings UI.
    func keyedProviders() -> Set<String> {
        var set = Set<String>()
        for p in LLMConfig.providers where hasKey(for: p) { set.insert(p) }
        return set
    }
}
