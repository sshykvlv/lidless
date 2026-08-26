import Foundation

public final class UpdateCoordinator: Sendable {
  private static let maximumManifestBytes = 64 * 1_024
  private static let maximumDiskImageBytes: Int64 = 32 * 1_024 * 1_024

  private let downloader: any UpdateDownloading
  private let hasher: any UpdateFileHashing
  private let stager: any UpdateStaging
  private let validator: any StagedAppValidating
  private let replacer: any AppReplacing
  private let helper: any UpdateHelperControlling
  private let launcher: any UpdatedAppLaunching
  private let reporter: any UpdateReporting

  public init(
    downloader: any UpdateDownloading,
    hasher: any UpdateFileHashing,
    stager: any UpdateStaging,
    validator: any StagedAppValidating,
    replacer: any AppReplacing,
    helper: any UpdateHelperControlling,
    launcher: any UpdatedAppLaunching,
    reporter: any UpdateReporting
  ) {
    self.downloader = downloader
    self.hasher = hasher
    self.stager = stager
    self.validator = validator
    self.replacer = replacer
    self.helper = helper
    self.launcher = launcher
    self.reporter = reporter
  }

  public func install(_ release: ReleaseDescriptor, installedApp: URL) async throws {
    await reporter.updatePhaseChanged(.checking)
    var downloadedDiskImage: URL?

    do {
      let manifestText: String
      do {
        manifestText = try await downloader.text(
          URLRequest(url: release.manifestURL),
          maximumBytes: Self.maximumManifestBytes
        )
      } catch {
        throw UpdateInstallError(primary: .network)
      }

      let expectedHash: String
      do {
        expectedHash = try UpdateManifest(manifestText).expectedSHA256(for: "Lidless.dmg")
      } catch {
        throw UpdateInstallError(primary: .manifest)
      }

      await reporter.updatePhaseChanged(.downloading(release.version))
      do {
        downloadedDiskImage = try await downloader.download(
          URLRequest(url: release.diskImageURL),
          maximumBytes: Self.maximumDiskImageBytes
        )
      } catch {
        throw UpdateInstallError(primary: .network)
      }
      guard let diskImage = downloadedDiskImage else {
        throw UpdateInstallError(primary: .network)
      }

      await reporter.updatePhaseChanged(.verifying(release.version))
      do {
        guard try hasher.sha256(of: diskImage) == expectedHash else {
          throw UpdateInstallError(primary: .checksum)
        }
      } catch let error as UpdateInstallError {
        throw error
      } catch {
        throw UpdateInstallError(primary: .checksum)
      }

      await reporter.updatePhaseChanged(.mounting(release.version))
      let session: MountedUpdateSession
      do {
        session = try stager.mount(diskImage: diskImage, version: release.version)
      } catch {
        throw UpdateInstallError(primary: .mount)
      }

      do {
        try validator.validate(app: session.app, expectedVersion: release.version)
      } catch {
        throw close(session: session, primary: .identity)
      }

      await reporter.updatePhaseChanged(.preparing(release.version))
      let prepared: PreparedInstall
      do {
        prepared = try replacer.prepare(
          mountedApp: session.app,
          diskImage: diskImage,
          installedApp: installedApp,
          version: release.version,
          expectedDiskImageSHA256: expectedHash
        )
      } catch {
        throw close(session: session, primary: .prepare)
      }

      do {
        try session.detach()
      } catch {
        throw cleanup(prepared: prepared, primary: .detach)
      }

      do {
        try downloader.removeDownloadedFile(diskImage)
        downloadedDiskImage = nil
      } catch {
        throw cleanup(prepared: prepared, primary: .cleanup)
      }

      switch prepared {
      case .manualInstall(let diskImage):
        await reporter.updatePhaseChanged(.manualInstall(diskImage))
        return
      case .replacement(let replacement):
        do {
          try await helper.disarmForUpdate()
        } catch {
          throw cleanup(prepared: prepared, primary: .disarm)
        }

        await reporter.updatePhaseChanged(.installing(release.version))
        let receipt: ReplacementReceipt
        do {
          receipt = try replacer.commit(replacement)
        } catch {
          throw cleanup(prepared: prepared, primary: .swap)
        }

        do {
          try await helper.restartAfterVerifiedUpdateSwap()
        } catch {
          throw await rollback(
            receipt: receipt,
            prepared: prepared,
            primary: .helperRestart
          )
        }

        do {
          _ = try await launcher.launchNewInstance(
            app: receipt.installedApp,
            expectedVersion: receipt.version,
            oldAppSibling: receipt.oldAppSibling
          )
        } catch {
          throw await rollback(receipt: receipt, prepared: prepared, primary: .launch)
        }
        await reporter.updatePhaseChanged(.finished(release.version))
      }
    } catch {
      var failure = (error as? UpdateInstallError) ?? UpdateInstallError(primary: .cleanup)
      if let downloadedDiskImage {
        do {
          try downloader.removeDownloadedFile(downloadedDiskImage)
        } catch {
          failure = UpdateInstallError(
            primary: failure.primary,
            relatedFailures: failure.relatedFailures + [.cleanup]
          )
        }
      }
      await reporter.updatePhaseChanged(.failed(failure.primary))
      throw failure
    }
  }

  private func close(
    session: MountedUpdateSession,
    primary: UpdateFailureCode
  ) -> UpdateInstallError {
    do {
      try session.detach()
      return UpdateInstallError(primary: primary)
    } catch {
      return UpdateInstallError(primary: primary, secondary: .detach)
    }
  }

  private func cleanup(
    prepared: PreparedInstall,
    primary: UpdateFailureCode
  ) -> UpdateInstallError {
    do {
      try replacer.cleanup(prepared)
      return UpdateInstallError(primary: primary)
    } catch {
      return UpdateInstallError(primary: primary, secondary: .cleanup)
    }
  }

  private func rollback(
    receipt: ReplacementReceipt,
    prepared: PreparedInstall,
    primary: UpdateFailureCode
  ) async -> UpdateInstallError {
    do {
      try replacer.rollback(receipt)
    } catch {
      return UpdateInstallError(primary: primary, secondary: .rollback)
    }

    var relatedFailures: [UpdateFailureCode] = []
    do {
      try await helper.restartAfterVerifiedUpdateSwap()
    } catch {
      relatedFailures.append(.helperRestart)
    }
    do {
      try replacer.cleanup(prepared)
    } catch {
      relatedFailures.append(.cleanup)
    }
    return UpdateInstallError(primary: primary, relatedFailures: relatedFailures)
  }
}
