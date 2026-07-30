public enum BookDetailSourceState: String, CaseIterable, Sendable {
  case present
  case missing
}

public enum BookDetailLoginURLState: String, CaseIterable, Sendable {
  case absent
  case blank
  case whitespace
  case nonblank
}

public enum BookDetailBookKind: String, CaseIterable, Sendable {
  case remote
  case localTXT = "local_txt"
  case localEPUB = "local_epub"
}

public enum BookDetailShelfAction: String, Equatable, Sendable {
  case add
  case remove
}

public struct BookDetailActionSnapshot: Equatable, Sendable {
  public let isInBookshelf: Bool
  public let sourceState: BookDetailSourceState
  public let loginURLState: BookDetailLoginURLState
  public let bookKind: BookDetailBookKind
  public let canUpdate: Bool
  public let splitsLongChapters: Bool
  public let confirmsDeletion: Bool

  public init(
    isInBookshelf: Bool,
    sourceState: BookDetailSourceState,
    loginURLState: BookDetailLoginURLState,
    bookKind: BookDetailBookKind,
    canUpdate: Bool,
    splitsLongChapters: Bool,
    confirmsDeletion: Bool
  ) {
    self.isInBookshelf = isInBookshelf
    self.sourceState = sourceState
    self.loginURLState = loginURLState
    self.bookKind = bookKind
    self.canUpdate = canUpdate
    self.splitsLongChapters = splitsLongChapters
    self.confirmsDeletion = confirmsDeletion
  }
}

public struct BookDetailVisibleActions: Equatable, Sendable {
  public let edit: Bool
  public let login: Bool
  public let setSourceVariable: Bool
  public let setBookVariable: Bool
  public let canUpdate: Bool
  public let splitLongChapter: Bool
  public let upload: Bool

  public init(
    edit: Bool,
    login: Bool,
    setSourceVariable: Bool,
    setBookVariable: Bool,
    canUpdate: Bool,
    splitLongChapter: Bool,
    upload: Bool
  ) {
    self.edit = edit
    self.login = login
    self.setSourceVariable = setSourceVariable
    self.setBookVariable = setBookVariable
    self.canUpdate = canUpdate
    self.splitLongChapter = splitLongChapter
    self.upload = upload
  }
}

public struct BookDetailCheckedActions: Equatable, Sendable {
  public let canUpdate: Bool
  public let splitLongChapter: Bool
  public let deleteAlert: Bool

  public init(
    canUpdate: Bool,
    splitLongChapter: Bool,
    deleteAlert: Bool
  ) {
    self.canUpdate = canUpdate
    self.splitLongChapter = splitLongChapter
    self.deleteAlert = deleteAlert
  }
}

public struct BookDetailActionAvailability: Equatable, Sendable {
  public let shelfAction: BookDetailShelfAction
  public let actions: BookDetailVisibleActions
  public let checked: BookDetailCheckedActions

  public init(snapshot: BookDetailActionSnapshot) {
    let hasSource = snapshot.sourceState == .present
    let isLocalTXT = snapshot.bookKind == .localTXT
    let isLocal = snapshot.bookKind != .remote

    shelfAction = snapshot.isInBookshelf ? .remove : .add
    actions = BookDetailVisibleActions(
      edit: snapshot.isInBookshelf,
      login: hasSource && snapshot.loginURLState == .nonblank,
      setSourceVariable: hasSource,
      setBookVariable: hasSource,
      canUpdate: hasSource,
      splitLongChapter: isLocalTXT,
      upload: isLocal
    )
    checked = BookDetailCheckedActions(
      canUpdate: snapshot.canUpdate,
      splitLongChapter: snapshot.splitsLongChapters,
      deleteAlert: snapshot.confirmsDeletion
    )
  }
}
