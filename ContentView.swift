import SwiftUI
import UniformTypeIdentifiers
import Network
import Combine
import os

private let logger = Logger(subsystem: "com.saiitanaa.syphras", category: "transfer")

enum Screen {
    case drop
    case pickRecipient(URL)
}

enum SendStatus: Equatable {
    case idle
    case sending
    case success
    case failure(String)
}

// MARK: - peer model

struct Peer: Identifiable, Hashable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

// MARK: - tr header

private struct TransferHeader {
    let filename: String
    let fileSize: UInt64
}

extension TransferHeader: Sendable {}

nonisolated extension TransferHeader: Codable {}

// MARK: - transfer

final class PeerBrowser: ObservableObject {
    @Published var peers: [Peer] = []
    @Published var sendStatus: SendStatus = .idle

    private var browser: NWBrowser?
    private var listener: NWListener?
    private let serviceType = "_syphras._tcp"

    func start() {
        browse()
        advertise()
    }

    func stop() {
        browser?.cancel()
        browser = nil
        listener?.cancel()
        listener = nil
        peers = []
    }

    private func browse() {
        let params = NWParameters()
        params.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: params)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                self?.peers = results.compactMap { result in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    return Peer(id: name, name: name, endpoint: result.endpoint)
                }
            }
        }

        browser.stateUpdateHandler = { state in
            logger.debug("Browser state: \(String(describing: state))")
            if case let .failed(error) = state {
                logger.error("Browser failed: \(error.localizedDescription)")
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    private func advertise() {
        do {
            let listener = try NWListener(using: .tcp)
            let deviceName = Host.current().localizedName ?? "Mac"

            listener.service = NWListener.Service(name: deviceName, type: serviceType)

            listener.newConnectionHandler = { [weak self] connection in
                logger.debug("Incoming connection")
                self?.acceptIncoming(connection)
            }

            listener.stateUpdateHandler = { state in
                logger.debug("Listener state: \(String(describing: state))")
                if case let .failed(error) = state {
                    logger.error("Listener failed: \(error.localizedDescription)")
                }
            }

            listener.start(queue: .main)
            self.listener = listener
        } catch {
            logger.error("Could not start advertising: \(error.localizedDescription)")
        }
    }

    // MARK: send time!!!

    func send(fileURL: URL, to peer: Peer) {
        var sourceURL = fileURL
        var isTemporaryZip = false

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let zipURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(fileURL.lastPathComponent)
                .appendingPathExtension("zip")
            
            try? FileManager.default.removeItem(at: zipURL)
            
            var error: NSError?
            let coordinator = NSFileCoordinator()
            
            // Méthode native Apple pour archiver un dossier
            coordinator.coordinate(readingItemAt: fileURL, options: .forUploading, error: &error) { zipCreatedURL in
                try? FileManager.default.moveItem(at: zipCreatedURL, to: zipURL)
            }
            
            if FileManager.default.fileExists(atPath: zipURL.path) {
                sourceURL = zipURL
                isTemporaryZip = true
            } else {
                sendStatus = .failure("Compressor error !")
                return
            }
        }

        guard let fileData = try? Data(contentsOf: sourceURL) else {
            sendStatus = .failure("Unable to read the file/folder")
            if isTemporaryZip { try? FileManager.default.removeItem(at: sourceURL) }
            return
        }

        let header = TransferHeader(filename: sourceURL.lastPathComponent, fileSize: UInt64(fileData.count))
        guard let headerData = try? JSONEncoder().encode(header) else { return }

        var lengthPrefix = UInt32(headerData.count).bigEndian
        let lengthData = Data(bytes: &lengthPrefix, count: 4)

        let connection = NWConnection(to: peer.endpoint, using: .tcp)
        sendStatus = .sending

        connection.stateUpdateHandler = { [weak self] state in
            logger.debug("Send connection state: \(String(describing: state))")

            switch state {
            case .ready:
                let payload = lengthData + headerData + fileData
                connection.send(content: payload, completion: .contentProcessed { error in
                    DispatchQueue.main.async {
                        if isTemporaryZip { try? FileManager.default.removeItem(at: sourceURL) }
                        
                        if let error {
                            logger.error("Send failed: \(error.localizedDescription)")
                            self?.sendStatus = .failure(error.localizedDescription)
                        } else {
                            logger.debug("File sent successfully")
                            self?.sendStatus = .success
                        }
                    }
                    connection.cancel()
                })
            case .failed(let error):
                if isTemporaryZip { try? FileManager.default.removeItem(at: sourceURL) }
                logger.error("Connection failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.sendStatus = .failure(error.localizedDescription)
                }
                connection.cancel()
            case .waiting(let error):
                logger.debug("Connection waiting: \(error.localizedDescription)")
            default:
                break
            }
        }

        connection.start(queue: .main)
    }

    // MARK: receiver

    private func acceptIncoming(_ connection: NWConnection) {
        connection.start(queue: .main)
        readHeaderLength(on: connection)
    }

    private func readHeaderLength(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, error in
            guard let data, data.count == 4, error == nil else {
                logger.error("Failed reading header length: \(error?.localizedDescription ?? "unknown")")
                connection.cancel()
                return
            }
            let length = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
            self.readHeader(on: connection, length: Int(length))
        }
    }

    private func readHeader(on connection: NWConnection, length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
            guard let data, let header = try? JSONDecoder().decode(TransferHeader.self, from: data), error == nil else {
                logger.error("Failed reading header: \(error?.localizedDescription ?? "unknown")")
                connection.cancel()
                return
            }
            logger.debug("Receiving \(header.filename), \(header.fileSize) bytes")
            self.readFile(on: connection, header: header, buffer: Data())
        }
    }

    private func readFile(on connection: NWConnection, header: TransferHeader, buffer: Data) {
        let remaining = Int(header.fileSize) - buffer.count

        connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, min(remaining, 65536))) { data, _, isComplete, error in
            var buffer = buffer
            if let data {
                buffer.append(data)
            }

            if buffer.count >= header.fileSize {
                self.saveToDownloads(filename: header.filename, data: buffer)
                connection.cancel()
                return
            }

            if let error {
                logger.error("Error receiving file body: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            if isComplete {
                logger.error("Connection closed before file fully received (\(buffer.count)/\(header.fileSize))")
                connection.cancel()
                return
            }

            self.readFile(on: connection, header: header, buffer: buffer)
        }
    }

    private func saveToDownloads(filename: String, data: Data) {
        guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            logger.error("Could not resolve Downloads folder")
            return
        }

        var destination = downloadsURL.appendingPathComponent(filename)
        let baseName = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        var counter = 1

        while FileManager.default.fileExists(atPath: destination.path) {
            let newName = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
            destination = downloadsURL.appendingPathComponent(newName)
            counter += 1
        }

        do {
            try data.write(to: destination)
            logger.debug("Saved incoming file to \(destination.path)")
        } catch {
            logger.error("Could not save file: \(error.localizedDescription)")
        }
    }
}

// MARK: - main

struct ContentView: View {
    @State private var screen: Screen = .drop
    @State private var isTargeted = false
    @StateObject private var browser = PeerBrowser()
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            switch screen {
            case .drop:
                dropZone
            case .pickRecipient(let fileURL):
                recipientList(fileURL: fileURL)
            }
        }
        .frame(width: 800, height: 500)
        .navigationTitle(Text("Syphras"))
        .padding()
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
        .task {
            await appState.checkForUpdateOnLaunch()
        }
        .alert(
            "Update Available",
            isPresented: $appState.showUpdateAlert,
            presenting: appState.availableRelease
        ) { release in
            Button("Download") {
                NSWorkspace.shared.open(release.htmlURL)
            }
            Button("Later", role: .cancel) { }
        } message: { release in
            Text("Version \(release.tagName) is available (current: \(appState.currentVersion)).")
        }
        .alert(
            "You're Up to Date",
            isPresented: $appState.showNoUpdateAlert
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Syphras \(appState.currentVersion) is the latest version available.")
        }
        .alert(
            "Error",
            isPresented: $appState.showUpdateErrorAlert
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(appState.updateErrorMessage ?? "Unable to check for updates.")
        }
    }

    // MARK: drag&drop

    private var dropZone: some View {
        VStack {
            Spacer()
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(isTargeted ? .blue.opacity(0.15) : .white.opacity(0.05))
                .stroke(isTargeted ? .blue : .secondary.opacity(0.2), style: StrokeStyle(lineWidth: 2, dash: [8]))
                .frame(height: 500)
                .overlay(
                    VStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 80))
                            .foregroundStyle(isTargeted ? .blue : .secondary)

                        Text("Drag & Drop your files")
                            .font(.system(size: 40))
                            .foregroundStyle(isTargeted ? .blue : .secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                )
                .onDrop(of: [.fileURL, .folder, .item], isTargeted: $isTargeted) { providers in
                    handleDrop(providers: providers)
                }
            Spacer()
        }
    }

    // MARK: picker

    private func recipientList(fileURL: URL) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation {
                        browser.sendStatus = .idle
                        screen = .drop
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(browser.sendStatus == .sending)

                Spacer()
                Text("Send \"\(fileURL.lastPathComponent)\"")
                    .font(.headline)
                Spacer()
                Color.clear.frame(width: 20)
            }
            .padding()

            statusBanner

            if browser.peers.isEmpty {
                Spacer()
                ProgressView("Looking for nearby devices…")
                Spacer()
            } else {
                List(browser.peers) { peer in
                    HStack {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(.blue)
                        Text(peer.name)
                        Spacer()

                        if browser.sendStatus == .sending {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button("Send") {
                                browser.send(fileURL: fileURL, to: peer)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch browser.sendStatus {
        case .idle, .sending:
            EmptyView()
        case .success:
            Label("File sent", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .padding(.bottom, 8)
        case .failure(let message):
            Label("Failed: \(message)", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .padding(.bottom, 8)
        }
    }


    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _, error in
            guard let url = url, error == nil else { return }
            
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.copyItem(at: url, to: tempURL)

            DispatchQueue.main.async {
                withAnimation {
                    self.screen = .pickRecipient(tempURL)
                }
            }
        }
        return true
    }
}

#Preview {
    ContentView()
}
