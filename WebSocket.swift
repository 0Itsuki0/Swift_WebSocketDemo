
import SwiftUI

extension URLSessionWebSocketTask.CloseCode {
    
    var displayString: String {
        switch self {
            
        case .invalid:
            "invalid"
        case .normalClosure:
            "normalClosure"
        case .goingAway:
            "goingAway"
        case .protocolError:
            "protocolError"
        case .unsupportedData:
            "unsupportedData"
        case .noStatusReceived:
            "noStatusReceived"
        case .abnormalClosure:
            "abnormalClosure"
        case .invalidFramePayloadData:
            "invalidFramePayloadData"
        case .policyViolation:
            "policyViolation"
        case .messageTooBig:
            "messageTooBig"
        case .mandatoryExtensionMissing:
            "mandatoryExtensionMissing"
        case .internalServerError:
            "internalServerError"
        case .tlsHandshakeFailure:
            "tlsHandshakeFailure"
        @unknown default:
            "unknown close code"
        }
    }
}

extension Error {
    var message: String {
        if let error = self as? WebSocketConnectionManager._Error {
            return switch error {
            case .invalidURL:
                "Invalid endpoint url"
            case .webSocketTaskUndefined:
                "webSocket Task Undefined"
            case .connectionClosed(let code, let reason):
                "Connection Closed With Error. Code: \(code.displayString). Reason: \(reason)"
            }
        }
        return self.localizedDescription
    }
    
    // error: Error Domain=NSPOSIXErrorDomain Code=57 "Socket is not connected" UserInfo={NSErrorFailingURLStringKey=ws://127.0.0.1:3000/web_socket, NSErrorFailingURLKey=ws://127.0.0.1:3000/web_socket}
    // in this case, we will receive the close code and reason within the delegate function, so we will ignore this error
    var isSocketNotConnectedError: Bool {
        let error = self as NSError
        guard error.domain == NSPOSIXErrorDomain else {
            return false
        }
        // POSIXError.ENOTCONN: 57
        // https://developer.apple.com/documentation/foundation/posixerror/enotconn
        guard error.code == POSIXError.ENOTCONN.rawValue else {
            return false
        }
        return true
        
    }
}

extension WebSocketConnectionManager {
    enum _Error: Error {
        case invalidURL
        case webSocketTaskUndefined
        case connectionClosed(URLSessionWebSocketTask.CloseCode, String)
    }
    
    enum ConnectionState {
        case notConnected
        case connecting
        case connected
    }
}



@Observable
class WebSocketConnectionManager: NSObject {
    private(set) var connectionState: ConnectionState = .notConnected
    private(set) var isStreamingMessage: Bool = false
    private(set) var isReceivingMessageSingle: Bool = false
    
   
    private var isReceivingMessage: Bool {
        self.isStreamingMessage || self.isReceivingMessageSingle
    }

    var message: URLSessionWebSocketTask.Message?
    var error: Error? {
        didSet {
            if let error = self.error {
                print(error.message)
            }
        }
    }
    
    @ObservationIgnored
    private var webSocketTask: URLSessionWebSocketTask?
    
    @ObservationIgnored
    private var receivingTask: Task<Void, Error>?
    
    private let urlSession: URLSession = .shared

    
    deinit {
        self.webSocketTask?.cancel(with: .goingAway, reason: nil)
        self.webSocketTask = nil
        self.urlSession.finishTasksAndInvalidate()
    }
    
    
    // URL: has to be either `ws` or `wss` scheme
    func connect(to endpointURL: String, httpMethod: String) throws {
        print(#function)
        guard let url = URL(string: endpointURL) else {
            throw _Error.invalidURL
        }
        guard self.connectionState == .notConnected else {
            return
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = httpMethod
        
        self.webSocketTask = self.urlSession.webSocketTask(with: urlRequest)
        self.webSocketTask?.delegate = self
        self.webSocketTask?.resume()
        // we won't know whether if we are actually connected, ie: handshake completes,
        // until we receive the notifications through the session’s delegate
        self.connectionState = .connecting
        print("Connecting to \(endpointURL).")
    }
    
    func disconnect() {
        print(#function)
        self.stopReceiving()
        self.isReceivingMessageSingle = false
        self.webSocketTask?.cancel(with: .goingAway, reason: nil)
        self.webSocketTask = nil
        self.message = nil
        self.connectionState = .notConnected
    }
    
    // send string message
    func send(_ string: String) async throws {
        print(#function)

        guard let webSocketTask = self.webSocketTask else {
            throw _Error.webSocketTaskUndefined
        }
        try await webSocketTask.send(.string(string))
        print("Send \(string) with success")
    }
    
    // send bytes message
    func send(_ data: Data) async throws {
        print(#function)

        guard let webSocketTask = self.webSocketTask else {
            throw _Error.webSocketTaskUndefined
        }
        try await webSocketTask.send(.data(data))
        print("Send data of length \(data.count) with success")
    }
    
    
    // receive a single message
    func receiveSingle() async throws {
        print(#function)
        guard let webSocketTask = self.webSocketTask else {
            throw _Error.webSocketTaskUndefined
        }
        
        guard !self.isReceivingMessageSingle, !self.isStreamingMessage else { return }
        
        self.isReceivingMessageSingle = true
        
        let message = try await webSocketTask.receive()
        
        // webSocketTask.receive will not return until the next new message comes in.
        // therefore by the time we receive the message, we might already have cancelled the web socket task
        //
        // check self.isReceivingMessage instead because in the case of user start receive single and started receive stream immediately afterward, the next new message will still coming in here.
        if self.webSocketTask != nil, self.isReceivingMessageSingle {
            self.message = message
        }
        
        self.isReceivingMessageSingle = false

    }
    
    
    // open a receive message task (Stream)
    func startReceiving() throws {
        print(#function)
        guard self.webSocketTask != nil else {
            throw _Error.webSocketTaskUndefined
        }
        guard !self.isStreamingMessage else {
            return
        }
        
        // start receiving even if we are receiving single
        self.isStreamingMessage = true

        self.receivingTask = Task {
            while self.webSocketTask != nil, self.isStreamingMessage {
                do {
                    let message = try await self.webSocketTask!.receive()
                    // webSocketTask.receive will not return until the next new message comes in.
                    // therefore by the time we receive the message, we might already have cancelled the receiving or the web socket task
                    //
                    // check self.isReceivingMessage instead because in the case of user stop receive stream and start receive single immediately afterward, the next new message will still coming in here.
                    if self.webSocketTask != nil, self.isReceivingMessage {
                        self.message = message
                    }
                } catch (let error) {
                    // if error is isSocketNotConnectedError, we will receive the close code and reason within the delegate function, so we will ignore this error
                    if self.webSocketTask != nil, self.isReceivingMessage, !error.isSocketNotConnectedError {
                        self.error = error
                    }
                    self.stopReceiving()
                    break
                }
            }
        }
    }
    
    func stopReceiving() {
        print(#function)
        self.receivingTask?.cancel()
        self.receivingTask = nil
        self.isStreamingMessage = false
    }
    
}


extension WebSocketConnectionManager:  URLSessionWebSocketDelegate {
    // Tells the delegate that the WebSocket task successfully negotiated the handshake with the endpoint, indicating the negotiated protocol.
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print(#function)
        DispatchQueue.main.async {
            if self.connectionState == .connecting, webSocketTask == self.webSocketTask {
                self.connectionState = .connected
            }
        }
    }
    
    // Tells the delegate that the WebSocket task received a close frame from the server endpoint, optionally including a close code and reason from the server.
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print(#function)
        DispatchQueue.main.async {
            print("Close code: \(closeCode.displayString)")
            if let reason {
                print("Reason: \(String(describing: String(data: reason, encoding: .utf8)))")
            }
            // connection lost due to server close
            if self.connectionState == .connected, webSocketTask == self.webSocketTask {
                self.disconnect()
                self.error = _Error.connectionClosed(closeCode, String(data: reason ?? Data("".utf8), encoding: .utf8) ?? "unknown")
            }
        }
    }
}



final class ServerConfigurations {
    // URL has to be either ws or wss scheme
    static let serverURLString: String = "ws://127.0.0.1:3000"
    static let webSocketPath: String = "/web_socket"
    static let httpMethod: String = "GET"
}


struct WebSocketDemo: View {
    @State private var manager = WebSocketConnectionManager()
    @State private var showError = false
    
    @State private var endpointURL: String = "\(ServerConfigurations.serverURLString)\(ServerConfigurations.webSocketPath)"
    @State private var httpMethod: String = ServerConfigurations.httpMethod
    
    var body: some View {
        NavigationStack {
            
            List {
                Section("Server Configuration") {
                    HStack(spacing: 16) {
                        Text("URL")
                        TextField("", text: $endpointURL)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .foregroundStyle(.gray)
                    }
                    
                    HStack(spacing: 16) {
                        Text("Method")
                        TextField("", text: $httpMethod)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .foregroundStyle(.gray)
                    }
                }
                .font(.subheadline)
                
                Section {
                    Button(action: {
                        if self.manager.connectionState == .notConnected {
                            do {
                                try self.manager.connect(to: endpointURL, httpMethod: ServerConfigurations.httpMethod)
                            } catch(let error) {
                                self.manager.error = error
                            }
                        } else {
                            self.manager.disconnect()
                        }

                    }, label: {
                        let text = switch manager.connectionState {
                        case .connected:
                            "Disconnect"
                        case .connecting:
                            "Connecting...Disconnect?"
                        case .notConnected:
                            "Connect"
                        }
                        Text(text)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .fontWeight(.semibold)
                            .contentShape(Capsule())
                    })
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(.all, 0)
                    .listRowBackground(Color.clear)
                }
                
                if self.manager.connectionState == .connected {
                    Section {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Receive Message")
                            
                            HStack(spacing: 36) {
                                Button(action: {
                                    if !self.manager.isStreamingMessage {
                                        do {
                                            try self.manager.startReceiving()
                                            
                                        } catch(let error) {
                                            self.manager.error = error
                                        }
                                    } else {
                                        self.manager.stopReceiving()
                                    }

                                }, label: {
                                    Text(self.manager.isStreamingMessage ? "Stop Streaming" : "Start Streaming")
                                })
                                
                                
                                Button(action: {
                                    Task {
                                        do {
                                            try await manager.receiveSingle()
                                        } catch(let error) {
                                            print(error)
                                        }
                                    }
                                }, label: {
                                    Text("Receive Single")
                                })
                                .disabled(self.manager.isStreamingMessage || self.manager.isReceivingMessageSingle)

                            }
                            .font(.subheadline)
                            .buttonStyle(.borderless)
                            
                            Group {
                                if let message = manager.message {
                                    switch message {
                                    case .data(let data):
                                        Text("Data of \(data.count) bytes received.")
                                    case .string(let string):
                                        Text("String received: \n\(string)")
                                    @unknown default:
                                        Text("Unknown message received.")
                                    }
                                } else {
                                    Text("No message received yet.")

                                }
                            }
                            .foregroundStyle(.gray)
                            .font(.subheadline)
                            .multilineTextAlignment(.leading)
                            
                        }
                    }

                    
                    Section {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Send Message")
                            
                            HStack(spacing: 36) {
                                Button(action: {
                                    Task {
                                        do {
                                            try await manager.send("Some String")
                                        } catch(let error) {
                                            self.manager.error = error
                                        }
                                    }
                                }, label: {
                                    Text("Send String")
                                })
                                
                                             
                                Button(action: {
                                    Task {
                                        do {
                                            try await manager.send(Data("Some data".utf8))
                                        } catch(let error) {
                                            self.manager.error = error
                                        }
                                    }
                                }, label: {
                                    Text("Send Data")
                                })
                            }
                            .font(.subheadline)
                            .buttonStyle(.borderless)
                            
                        }
                    }

                }
            }
            .onChange(of: manager.error == nil, {
                self.showError = manager.error != nil
            })
            .alert("Oops!", isPresented: $showError, actions: {
                Button(action: {
                    manager.error = nil
                }, label: {
                    Text("OK")
                })
            }, message: {
                Text("\(manager.error?.message ?? "Unknown Error")")
            })
            .buttonStyle(.plain)
            .navigationTitle("WebSocket")
            .navigationBarTitleDisplayMode(.large)
            
        }
    }
}

