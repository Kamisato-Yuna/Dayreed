import DayreedCore
import Foundation

/// Credentials are intentionally separate from the Codable provider configuration.
struct ProviderDraft {
    var id = UUID()
    var name = ""
    var kind = ProviderConfiguration.Kind.openAICompatible
    var endpoint = ""
    var model = ""
    var executablePath = ""
    var supportsImages = false
    var timeoutSeconds = 90.0
    var authentication = ProviderConfiguration.CLIAuthentication.dayreedAPIKey
    var loginDirectory = ""

    init(configuration: ProviderConfiguration? = nil) {
        guard let configuration else { return }
        id = configuration.id; name = configuration.name; kind = configuration.kind
        endpoint = configuration.endpoint?.absoluteString ?? ""
        model = configuration.model; executablePath = configuration.executableURL?.path ?? ""
        supportsImages = configuration.supportsImages; timeoutSeconds = configuration.timeoutSeconds
        authentication = configuration.cliAuthentication
        loginDirectory = configuration.cliConfigurationDirectory?.path ?? ""
    }

    func configuration() throws -> ProviderConfiguration {
        let executable = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = loginDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind != .openAICompatible {
            guard executable.hasPrefix("/") else { throw ReviewServiceError.invalidConfiguration }
            if authentication == .existingLogin, !directory.hasPrefix("/") { throw ReviewServiceError.invalidConfiguration }
        }
        let value = ProviderConfiguration(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: kind == .openAICompatible ? URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) : nil,
            executableURL: kind == .openAICompatible ? nil : URL(fileURLWithPath: executable),
            supportsImages: supportsImages, timeoutSeconds: timeoutSeconds,
            cliAuthentication: authentication,
            cliConfigurationDirectory: authentication == .existingLogin && kind != .openAICompatible ? URL(fileURLWithPath: directory, isDirectory: true) : nil)
        do { try value.validate() } catch { throw ReviewServiceError.invalidConfiguration }
        return value
    }
}
