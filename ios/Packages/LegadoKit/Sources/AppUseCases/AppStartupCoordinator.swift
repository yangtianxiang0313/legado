public enum StartupDestination: String, CaseIterable, Equatable, Sendable {
  case main
  case reader
}

public enum StartupPrompt: String, CaseIterable, Equatable, Sendable {
  case privacy
  case help
  case localPassword = "local_password"
}

public enum StartupPrivacyState: String, Equatable, Sendable {
  case pending
  case accepted
}

public enum StartupPrivacyAction: String, Equatable, Sendable {
  case agree
  case refuse
}

public enum StartupStoredVersion: String, Equatable, Sendable {
  case zero
  case previous
  case current
}

public enum StartupPasswordState: String, Equatable, Sendable {
  case unset
  case empty
  case nonempty
}

public enum StartupPasswordAction: String, Equatable, Sendable {
  case cancel
}

public enum StartupEffect: Equatable, Sendable {
  case navigate(StartupDestination)
  case completeWelcome
  case present(StartupPrompt)
  case persistPrivacyAccepted
  case persistVersionCurrent
  case persistFirstOpen(Bool)
  case persistPassword(StartupPasswordState)
  case finishMain
  case completeMain
}

public struct StartupWelcomeOutcome: Equatable, Sendable {
  public let destinations: [StartupDestination]
  public let welcomeCompleted: Bool

  public init(
    destinations: [StartupDestination],
    welcomeCompleted: Bool
  ) {
    self.destinations = destinations
    self.welcomeCompleted = welcomeCompleted
  }
}

public struct StartupMainSnapshot: Equatable, Sendable {
  public let privacyState: StartupPrivacyState
  public let privacyAction: StartupPrivacyAction?
  public let storedVersion: StartupStoredVersion
  public let firstOpen: Bool
  public let passwordState: StartupPasswordState
  public let passwordAction: StartupPasswordAction?
  public let appCrash: Bool
  public let lastBackup: Int64
  public let isDebugBuild: Bool

  public init(
    privacyState: StartupPrivacyState,
    privacyAction: StartupPrivacyAction? = nil,
    storedVersion: StartupStoredVersion,
    firstOpen: Bool,
    passwordState: StartupPasswordState,
    passwordAction: StartupPasswordAction? = nil,
    appCrash: Bool,
    lastBackup: Int64 = 0,
    isDebugBuild: Bool = true
  ) {
    self.privacyState = privacyState
    self.privacyAction = privacyAction
    self.storedVersion = storedVersion
    self.firstOpen = firstOpen
    self.passwordState = passwordState
    self.passwordAction = passwordAction
    self.appCrash = appCrash
    self.lastBackup = lastBackup
    self.isDebugBuild = isDebugBuild
  }
}

public struct StartupMainOutcome: Equatable, Sendable {
  public let isFinishing: Bool
  public let appCrashPending: Bool
  public let isDebugBuild: Bool
  public let prompts: [StartupPrompt]
  public let firstOpen: Bool
  public let helpPromptVisible: Bool
  public let lastBackup: Int64
  public let passwordState: StartupPasswordState
  public let privacyAccepted: Bool
  public let updateLogVisible: Bool
  public let versionIsCurrent: Bool

  public init(
    isFinishing: Bool,
    appCrashPending: Bool,
    isDebugBuild: Bool,
    prompts: [StartupPrompt],
    firstOpen: Bool,
    helpPromptVisible: Bool,
    lastBackup: Int64,
    passwordState: StartupPasswordState,
    privacyAccepted: Bool,
    updateLogVisible: Bool,
    versionIsCurrent: Bool
  ) {
    self.isFinishing = isFinishing
    self.appCrashPending = appCrashPending
    self.isDebugBuild = isDebugBuild
    self.prompts = prompts
    self.firstOpen = firstOpen
    self.helpPromptVisible = helpPromptVisible
    self.lastBackup = lastBackup
    self.passwordState = passwordState
    self.privacyAccepted = privacyAccepted
    self.updateLogVisible = updateLogVisible
    self.versionIsCurrent = versionIsCurrent
  }
}

public struct StartupPlan<Outcome: Equatable & Sendable>:
  Equatable, Sendable
{
  public let effects: [StartupEffect]
  public let outcome: Outcome

  public init(effects: [StartupEffect], outcome: Outcome) {
    self.effects = effects
    self.outcome = outcome
  }
}

public enum AppStartupCoordinator {
  public static func welcome(
    defaultToRead: Bool
  ) -> StartupPlan<StartupWelcomeOutcome> {
    var destinations: [StartupDestination] = [.main]
    var effects: [StartupEffect] = [.navigate(.main)]
    if defaultToRead {
      destinations.append(.reader)
      effects.append(.navigate(.reader))
    }
    effects.append(.completeWelcome)
    return StartupPlan(
      effects: effects,
      outcome: StartupWelcomeOutcome(
        destinations: destinations,
        welcomeCompleted: true
      )
    )
  }

  public static func main(
    _ snapshot: StartupMainSnapshot
  ) -> StartupPlan<StartupMainOutcome> {
    var effects: [StartupEffect] = []
    var prompts: [StartupPrompt] = []
    var privacyAccepted = snapshot.privacyState == .accepted
    var versionIsCurrent = snapshot.storedVersion == .current
    var firstOpen = snapshot.firstOpen
    var passwordState = snapshot.passwordState

    if snapshot.privacyState == .pending {
      prompts.append(.privacy)
      effects.append(.present(.privacy))
      guard snapshot.privacyAction == .agree else {
        effects.append(.finishMain)
        return StartupPlan(
          effects: effects,
          outcome: StartupMainOutcome(
            isFinishing: true,
            appCrashPending: snapshot.appCrash,
            isDebugBuild: snapshot.isDebugBuild,
            prompts: prompts,
            firstOpen: firstOpen,
            helpPromptVisible: false,
            lastBackup: snapshot.lastBackup,
            passwordState: passwordState,
            privacyAccepted: false,
            updateLogVisible: false,
            versionIsCurrent: versionIsCurrent
          )
        )
      }
      privacyAccepted = true
      effects.append(.persistPrivacyAccepted)
    }

    if snapshot.firstOpen {
      prompts.append(.help)
      effects.append(.present(.help))
      versionIsCurrent = true
      firstOpen = false
      effects.append(.persistVersionCurrent)
      effects.append(.persistFirstOpen(false))
    } else if snapshot.storedVersion != .current {
      versionIsCurrent = true
      effects.append(.persistVersionCurrent)
    }

    if snapshot.passwordState == .unset {
      prompts.append(.localPassword)
      effects.append(.present(.localPassword))
      if snapshot.passwordAction == .cancel {
        passwordState = .empty
        effects.append(.persistPassword(.empty))
      }
    }

    effects.append(.completeMain)
    return StartupPlan(
      effects: effects,
      outcome: StartupMainOutcome(
        isFinishing: false,
        appCrashPending: snapshot.appCrash,
        isDebugBuild: snapshot.isDebugBuild,
        prompts: prompts,
        firstOpen: firstOpen,
        helpPromptVisible: false,
        lastBackup: snapshot.lastBackup,
        passwordState: passwordState,
        privacyAccepted: privacyAccepted,
        updateLogVisible: false,
        versionIsCurrent: versionIsCurrent
      )
    )
  }
}
