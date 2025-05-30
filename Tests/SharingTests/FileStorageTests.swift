#if canImport(AppKit) || canImport(UIKit) || canImport(WatchKit)
  import CustomDump
  import Dependencies
  import DependenciesTestSupport
  import Foundation
  @_spi(Internals) import Sharing
  import Testing

  @Suite struct FileStorageTests {
    let fileSystem = LockIsolated<[URL: Data]>([:])
    let testScheduler = DispatchQueue.test

    @Test func basics() throws {
      try withDependencies {
        $0.defaultFileStorage = .inMemory(fileSystem: fileSystem, scheduler: .immediate)
      } operation: {
        @Shared(.fileStorage(.fileURL)) var users = [User]()
        #expect($users.loadError == nil)
        expectNoDifference(
          fileSystem.value, [.fileURL: Data()]
        )
        $users.withLock { $0.append(.blob) }
        try expectNoDifference(fileSystem.value.users(for: .fileURL), [.blob])
      }
    }

    @Test func customEncodeDecode() {
      withDependencies {
        $0.defaultFileStorage = .inMemory(fileSystem: fileSystem, scheduler: .immediate)
      } operation: {
        @Shared(.utf8String) var string = ""
        #expect($string.loadError == nil)
        expectNoDifference(
          fileSystem.value, [.utf8StringURL: Data()]
        )
        $string.withLock { $0 = "hello" }
        expectNoDifference(
          fileSystem.value[.utf8StringURL].map { String(decoding: $0, as: UTF8.self) },
          "hello"
        )
      }
    }

    @Test func throttle() throws {
      try withDependencies {
        $0.defaultFileStorage = .inMemory(
          fileSystem: fileSystem,
          scheduler: testScheduler.eraseToAnyScheduler()
        )
      } operation: {
        @Shared(.fileStorage(.fileURL)) var users = [User]()
        try expectNoDifference(fileSystem.value.users(for: .fileURL), nil)

        $users.withLock { $0.append(.blob) }
        try expectNoDifference(fileSystem.value.users(for: .fileURL), [.blob])

        $users.withLock { $0.append(.blobJr) }
        testScheduler.advance(by: .seconds(1) - .milliseconds(1))
        try expectNoDifference(fileSystem.value.users(for: .fileURL), [.blob])

        $users.withLock { $0.append(.blobSr) }
        testScheduler.advance(by: .milliseconds(1))
        try expectNoDifference(fileSystem.value.users(for: .fileURL), [.blob, .blobJr, .blobSr])

        testScheduler.advance(by: .seconds(1))
        try expectNoDifference(fileSystem.value.users(for: .fileURL), [.blob, .blobJr, .blobSr])

        testScheduler.advance(by: .seconds(0.5))
        $users.withLock { $0.append(.blobEsq) }
        try expectNoDifference(
          fileSystem.value.users(for: .fileURL),
          [
            .blob,
            .blobJr,
            .blobSr,
            .blobEsq,
          ]
        )
      }
    }

    @Test func noThrottling() throws {
      try withDependencies {
        $0.defaultFileStorage = .inMemory(
          fileSystem: fileSystem,
          scheduler: testScheduler.eraseToAnyScheduler()
        )
      } operation: {
        @Shared(.fileStorage(.fileURL)) var users = [User]()
        try expectNoDifference(fileSystem.value.users(for: .fileURL), nil)

        $users.withLock { $0.append(.blob) }
        try expectNoDifference(fileSystem.value.users(for: .fileURL), [.blob])

        testScheduler.advance(by: .seconds(2))
        $users.withLock { $0.append(.blobJr) }
        try expectNoDifference(fileSystem.value.users(for: .fileURL), [.blob, .blobJr])
      }
    }

    @Test func multipleFiles() throws {
      try withDependencies {
        $0.defaultFileStorage = .inMemory(fileSystem: fileSystem)
      } operation: {
        @Shared(.fileStorage(.fileURL)) var users = [User]()
        @Shared(.fileStorage(.anotherFileURL)) var otherUsers = [User]()

        $users.withLock { $0.append(.blob) }
        try expectNoDifference(fileSystem.value.users(for: .fileURL), [.blob])
        try expectNoDifference(fileSystem.value.users(for: .anotherFileURL), nil)

        $otherUsers.withLock { $0.append(.blobJr) }
        try expectNoDifference(fileSystem.value.users(for: .fileURL), [.blob])
        try expectNoDifference(fileSystem.value.users(for: .anotherFileURL), [.blobJr])
      }
    }

    @Test func initialValue() async throws {
      let fileSystem = try LockIsolated<[URL: Data]>(
        [.fileURL: try JSONEncoder().encode([User.blob])]
      )
      try await withDependencies {
        $0.defaultFileStorage = .inMemory(fileSystem: fileSystem)
      } operation: {
        @Shared(.fileStorage(.fileURL)) var users = [User]()
        _ = users
        await Task.yield()
        try expectNoDifference(fileSystem.value.users(for: .fileURL), [.blob])
      }
    }

    @Test func decodeFailure() async throws {
      let fileSystem = LockIsolated<[URL: Data]>(
        [.fileURL: Data("corrupt".utf8)]
      )
      try withDependencies {
        $0.defaultFileStorage = .inMemory(fileSystem: fileSystem)
      } operation: {
        @Shared(.fileStorage(.fileURL)) var users = [User]()
        let loadError = try #require($users.loadError)
        #expect(loadError is DecodingError)
        $users.withLock { $0.append(User(id: 1, name: "Blob")) }
        #expect($users.loadError == nil)
      }
    }

    @Test func multipleInMemoryFileStorages() {
      @Shared var shared1: User
      _shared1 = withDependencies {
        $0.defaultFileStorage = .inMemory
      } operation: {
        @Shared(.fileStorage(.userURL)) var user = User(id: 1, name: "Blob")
        return $user
      }
      @Shared var shared2: User
      _shared2 = withDependencies {
        $0.defaultFileStorage = .inMemory
      } operation: {
        @Shared(.fileStorage(.userURL)) var user = User(id: 1, name: "Blob")
        return $user
      }

      $shared1.withLock { $0.name = "Blob Jr" }
      #expect(shared1.name == "Blob Jr")
      #expect(shared2.name == "Blob")
      $shared2.withLock { $0.name = "Blob Sr" }
      #expect(shared1.name == "Blob Jr")
      #expect(shared2.name == "Blob Sr")
    }

    @Suite
    struct InMemoryFileStorageTests {
      let numbers = FileStorageKey<[Int]>.Default[
        .fileStorage(
          URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("numbers.json"),
          decode: { try JSONDecoder().decode([Int].self, from: $0) },
          encode: { try JSONEncoder().encode(Array($0.prefix(2))) }
        ),
        default: []
      ]

      @Test
      func modificationDate() {
        let numbers = Shared(wrappedValue: [], numbers)
        #expect(numbers.wrappedValue == [])
        numbers.withLock { $0.append(contentsOf: [1, 2, 3]) }
        #expect(numbers.wrappedValue == [1, 2, 3])
      }
    }

    @Suite(
      .dependency(\.defaultFileStorage, .fileSystem),
      .serialized
    )
    struct LiveTests {
      init() {
        try? FileManager.default.removeItem(at: .fileURL)
        try? FileManager.default.removeItem(at: .anotherFileURL)
        try? FileManager.default.removeItem(at: .countsURL)
      }

      @Test func basics() async throws {
        @Shared(.fileStorage(.fileURL)) var users = [User]()
        #expect($users.loadError == nil)

        $users.withLock { $0.append(.blob) }
        try expectNoDifference(
          JSONDecoder().decode([User].self, from: Data(contentsOf: .fileURL)),
          [.blob]
        )
      }

      @Test func initialValue() async throws {
        try JSONEncoder().encode([User.blob]).write(to: .fileURL)

        @Shared(.fileStorage(.fileURL)) var users = [User]()
        _ = users
        await Task.yield()
        try expectNoDifference(
          JSONDecoder().decode([User].self, from: Data(contentsOf: .fileURL)),
          [.blob]
        )
      }

      @Test func writeFile() async throws {
        try JSONEncoder().encode([User.blob]).write(to: .fileURL)

        @Shared(.fileStorage(.fileURL)) var users = [User]()
        await Task.yield()
        expectNoDifference(users, [.blob])

        try JSONEncoder().encode([User.blobJr]).write(to: .fileURL)
        try await Task.sleep(nanoseconds: 100_000_000)
        expectNoDifference(users, [.blobJr])
      }

      @Test func deleteFile() async throws {
        try JSONEncoder().encode([User.blob]).write(to: .fileURL)

        @Shared(.fileStorage(.fileURL)) var users = [User]()
        await Task.yield()
        expectNoDifference(users, [.blob])

        try FileManager.default.removeItem(at: .fileURL)
        try await Task.sleep(nanoseconds: 100_000_000)
        expectNoDifference(users, [])
      }

      @Test func moveFile() async throws {
        try await withMainSerialExecutor {
          try JSONEncoder().encode([User.blob]).write(to: .fileURL)

          @Shared(.fileStorage(.fileURL)) var users = [User]()
          await Task.yield()
          expectNoDifference(users, [.blob])

          try FileManager.default.moveItem(at: .fileURL, to: .anotherFileURL)
          try await Task.sleep(nanoseconds: 100_000_000)
          expectNoDifference(users, [])

          try FileManager.default.removeItem(at: .fileURL)
          try FileManager.default.moveItem(at: .anotherFileURL, to: .fileURL)
          try await Task.sleep(nanoseconds: 1_000_000_000)
          expectNoDifference(users, [.blob])
        }
      }

      @Test func moveFileThenWrite() async throws {
        try await withMainSerialExecutor {
          try JSONEncoder().encode([User.blob]).write(to: .fileURL)

          @Shared(.fileStorage(.fileURL)) var users = [User]()
          await Task.yield()
          expectNoDifference(users, [.blob])

          try FileManager.default.moveItem(at: .fileURL, to: .anotherFileURL)
          try await Task.sleep(nanoseconds: 100_000_000)
          expectNoDifference(users, [])

          try JSONEncoder().encode([User.blobEsq]).write(to: .fileURL)
          try await Task.sleep(nanoseconds: 1_000_000_000)
          expectNoDifference(users, [.blobEsq])
        }
      }

      @Test func testDeleteFileThenWriteToFile() async throws {
        try await withMainSerialExecutor {
          try JSONEncoder().encode([User.blob]).write(to: .fileURL)

          @Shared(.fileStorage(.fileURL)) var users = [User]()
          await Task.yield()
          expectNoDifference(users, [.blob])

          try FileManager.default.removeItem(at: .fileURL)
          try await Task.sleep(nanoseconds: 100_000_000)
          expectNoDifference(users, [])

          try JSONEncoder().encode([User.blobJr]).write(to: .fileURL)
          try await Task.sleep(nanoseconds: 100_000_000)
          expectNoDifference(users, [.blobJr])
        }
      }

      @Test func cancelThrottleWhenFileIsDeleted() async throws {
        try await withMainSerialExecutor {
          @Shared(.fileStorage(.fileURL)) var users = [User.blob]
          await Task.yield()
          expectNoDifference(users, [.blob])

          $users.withLock { $0 = [.blobJr] }  // NB: Saved immediately
          $users.withLock { $0 = [.blobSr] }  // NB: Throttled for 1 second
          try FileManager.default.removeItem(at: .fileURL)
          try await Task.sleep(nanoseconds: 1_200_000_000)
          expectNoDifference(users, [.blob])
          #expect(
            try Data(contentsOf: .fileURL) == Data()
          )
        }
      }

      @Test func writeFileWhileThrottling() async throws {
        try await withMainSerialExecutor {
          @Shared(.fileStorage(.fileURL)) var users = [User]()

          $users.withLock { $0.append(.blob) }
          expectNoDifference(
            try JSONDecoder().decode([User].self, from: Data(contentsOf: .fileURL)),
            [.blob]
          )
          $users.withLock { $0.append(.blobJr) }
          expectNoDifference(
            try JSONDecoder().decode([User].self, from: Data(contentsOf: .fileURL)),
            [.blob]
          )

          try Data().write(to: .fileURL)
          try await Task.sleep(nanoseconds: 1_200_000_000)

          expectNoDifference(users, [.blob, .blobJr])
          withKnownIssue("Throttled work should be cancelled when an external write occurs.") {
            #expect($users.loadError != nil)
            try #expect(Data(contentsOf: .fileURL) == Data())
          }
        }
      }

      #if canImport(Combine)
        @MainActor
        @Test func updateFileSystemFromBackgroundThread() async throws {
          @Shared(.fileStorage(.fileURL)) var count = 0

          await confirmation { confirm in
            let cancellable = $count.publisher.dropFirst().sink { _ in
              #expect(Thread.isMainThread)
              confirm()
            }
            defer { _ = cancellable }

            await withUnsafeContinuation { continuation in
              DispatchQueue.global().async {
                #expect(!Thread.isMainThread)
                try! Data("1".utf8).write(to: .fileURL)
                continuation.resume()
              }
            }
          }
        }
      #endif

      @MainActor
      @Test func multipleMutations() async throws {
        @Shared(.counts) var counts
        let iterations = 1_000
        let buckets = 10
        for m in 1...iterations {
          for n in 1...buckets {
            $counts.withLock {
              $0[n, default: 0] += 1
            }
          }
          expectNoDifference(
            Dictionary((1...buckets).map { n in (n, m) }, uniquingKeysWith: { $1 }),
            counts
          )
          try await Task.sleep(nanoseconds: 1_000_000)
        }
      }

      @Test func multipleMutationsFromMultipleThreads() async throws {
        @Shared(.counts) var counts

        await withTaskGroup(of: Void.self) { group in
          for _ in 1...1000 {
            group.addTask { [$counts] in
              for _ in 1...10 {
                $counts.withLock { $0[0, default: 0] += 1 }
                try? await Task.sleep(nanoseconds: 1_000_000)
              }
            }
          }
        }

        #expect(counts[0] == 10_000)
      }

      @Test func emptyData() throws {
        try? FileManager.default.removeItem(at: .fileURL)
        try Data().write(to: .fileURL)
        @Shared(.fileStorage(.fileURL)) var count = 0
        #expect(count == 0)
      }

      @Test func corruptData() async throws {
        try? FileManager.default.removeItem(at: .fileURL)
        try Data("corrupted".utf8).write(to: .fileURL)
        @Shared(value: 0) var count: Int
        $count = Shared(wrappedValue: 0, .fileStorage(.fileURL))
        #expect(count == 0)
        $count.withLock { $0 = 1 }
        try await Task.sleep(for: .seconds(0.01))
        #expect(count == 1)
        #expect(try String(decoding: Data(contentsOf: .fileURL), as: UTF8.self) == "1")
      }

      @Test func twoShareds() async throws {
        let count1URL = URL(fileURLWithPath: NSTemporaryDirectory())
          .appendingPathComponent("file.json")
        let count2URL = URL(fileURLWithPath: NSTemporaryDirectory() + "/")
          .appendingPathComponent("file.json")
        try? FileManager.default.removeItem(at: count1URL)
        try? FileManager.default.removeItem(at: count2URL)

        @Shared(.fileStorage(count1URL)) var count1 = 0
        @Shared(.fileStorage(count2URL)) var count2 = 0

        $count1.withLock { $0 = 42 }
        #expect(count1 == 42)
        try await Task.sleep(for: .seconds(1.5))
        #expect(count2 == 42)

        $count2.withLock { $0 = 1728 }
        #expect(count2 == 1728)
        try await Task.sleep(for: .seconds(1.5))
        #expect(count1 == 1728)

        $count1.withLock { $0 = 999 }
        #expect(count1 == 999)
        try await Task.sleep(for: .seconds(1.5))
        #expect(count2 == 999)
      }

      @Test func externalAtomicWrite() async throws {
        @Shared(.fileStorage(.fileURL)) var count = 0

        try Data("42".utf8).write(to: .fileURL, options: .atomic)
        try await Task.sleep(for: .seconds(1.5))
        #expect(count == 42)

        try Data("1728".utf8).write(to: .fileURL, options: .atomic)
        try await Task.sleep(for: .seconds(1.5))
        #expect(count == 1728)

        $count.withLock { $0 = 999 }
        try await Task.sleep(for: .seconds(1.5))
        #expect(count == 999)
        #expect(try String(decoding: Data(contentsOf: .fileURL), as: UTF8.self) == "999")
      }
    }
  }

  extension [URL: Data] {
    fileprivate func users(for url: URL) throws -> [User]? {
      guard
        let data = self[url],
        !data.isEmpty
      else { return nil }
      return try JSONDecoder().decode([User].self, from: data)
    }
  }

  extension SharedKey where Self == FileStorageKey<[Int: Int]>.Default {
    fileprivate static var counts: Self {
      Self[.fileStorage(.countsURL), default: [:]]
    }
  }

  extension SharedKey where Self == FileStorageKey<String> {
    fileprivate static var utf8String: Self {
      .fileStorage(
        .utf8StringURL,
        decode: { data in String(decoding: data, as: UTF8.self) },
        encode: { string in Data(string.utf8) }
      )
    }
  }

  private struct User: Codable, Equatable, Identifiable {
    let id: Int
    var name: String
    static let blob = User(id: 1, name: "Blob")
    static let blobJr = User(id: 2, name: "Blob Jr.")
    static let blobSr = User(id: 3, name: "Blob Sr.")
    static let blobEsq = User(id: 4, name: "Blob Esq.")
  }

  extension URL {
    fileprivate static let countsURL = Self(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("counts.json")
    fileprivate static let fileURL = Self(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("file.json")
    fileprivate static let userURL = Self(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("user.json")
    fileprivate static let anotherFileURL = Self(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("another-file.json")
    fileprivate static let utf8StringURL = Self(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("utf8-string.json")
  }
#endif
