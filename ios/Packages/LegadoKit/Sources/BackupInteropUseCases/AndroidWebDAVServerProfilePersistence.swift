import AppUseCases
import Foundation
import IntegrationKit

public struct AndroidWebDAVServerCredential: Equatable, Sendable {
  public let username: String
  public let password: String

  public init(username: String, password: String) {
    self.username = username
    self.password = password
  }
}

public protocol AndroidWebDAVServerCredentialVault: Sendable {
  func credential(
    for reference: WebDAVCredentialReference
  ) async -> AndroidWebDAVServerCredential?
  func save(
    _ credential: AndroidWebDAVServerCredential,
    for reference: WebDAVCredentialReference
  ) async throws
  func remove(reference: WebDAVCredentialReference) async
}

public struct AndroidWebDAVServerProfileRestoreUseCase: Sendable {
  private let repository: any WebDAVServerProfileRepository
  private let vault: any AndroidWebDAVServerCredentialVault

  public init(
    repository: any WebDAVServerProfileRepository,
    vault: any AndroidWebDAVServerCredentialVault
  ) {
    self.repository = repository
    self.vault = vault
  }

  public func restore(
    _ plan: AndroidServerProfileImportPlan
  ) async throws {
    let oldProfiles = try await repository.webDAVServerProfiles()
    let oldSelectedID = try await repository.selectedWebDAVServerProfileID()
    var oldCredentials: [WebDAVCredentialReference: AndroidWebDAVServerCredential] = [:]
    for profile in oldProfiles {
      if let credential = await vault.credential(
        for: profile.credentialReference
      ) {
        oldCredentials[profile.credentialReference] = credential
      }
    }

    let imported = plan.webDAVProfiles.map { value in
      WebDAVServerProfile(
        id: value.id,
        name: value.name,
        serverAddress: value.url,
        sortNumber: value.sortNumber,
        credentialReference: Self.credentialReference(id: value.id)
      )
    }
    do {
      for value in plan.webDAVProfiles {
        try await vault.save(
          AndroidWebDAVServerCredential(
            username: value.username,
            password: value.password
          ),
          for: Self.credentialReference(id: value.id)
        )
      }
      try await repository.replaceWebDAVServerProfiles(
        imported,
        selectedID: plan.selectedID
      )
      let importedReferences = Set(imported.map(\.credentialReference))
      for oldProfile in oldProfiles
      where !importedReferences.contains(oldProfile.credentialReference) {
        await vault.remove(reference: oldProfile.credentialReference)
      }
    } catch {
      let importedReferences = Set(imported.map(\.credentialReference))
      for reference in importedReferences {
        if let previous = oldCredentials[reference] {
          try? await vault.save(previous, for: reference)
        } else {
          await vault.remove(reference: reference)
        }
      }
      try? await repository.replaceWebDAVServerProfiles(
        oldProfiles,
        selectedID: oldSelectedID
      )
      throw error
    }
  }

  public static func credentialReference(
    id: Int64
  ) -> WebDAVCredentialReference {
    WebDAVCredentialReference("webdav.server.\(id)")
  }
}
