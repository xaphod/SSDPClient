import Foundation
import Socket

// MARK: Logging

public struct SSDPDiscoveryLog {
    public static var debug: (String)->Void = { NSLog($0) }
    public static var info: (String)->Void = { NSLog($0) }
    public static var error: (String)->Void = { NSLog($0) }
}

// MARK: Protocols

/// Delegate for service discovery
public protocol SSDPDiscoveryDelegate {
    /// Tells the delegate a requested service has been discovered. Not on the main thread.
    func ssdpDiscovery(_ discovery: SSDPDiscovery, didDiscoverService service: SSDPService)

    /// Tells the delegate that the discovery has started. Always on the main thread.
    func ssdpDiscoveryDidStart(_ discovery: SSDPDiscovery)

    /// Tells the delegate that the discovery has finished.  Always on the main thread.
    func ssdpDiscoveryDidFinish(_ discovery: SSDPDiscovery, probablyShowingIOSPermissionDialog: Bool)
}

public extension SSDPDiscoveryDelegate {
    func ssdpDiscovery(_ discovery: SSDPDiscovery, didDiscoverService service: SSDPService) {}

    func ssdpDiscoveryDidStart(_ discovery: SSDPDiscovery) {}

    func ssdpDiscoveryDidFinish(_ discovery: SSDPDiscovery, probablyShowingIOSPermissionDialog: Bool) {}
}

/// SSDP discovery for UPnP devices on the LAN
public class SSDPDiscovery {
    private let queue = DispatchQueue.init(label: "SSDPDiscovery")

    /// The UDP socket
    private var sockets: [Socket] = []

    /// Delegate for service discovery
    public var delegate: SSDPDiscoveryDelegate?
    
    // MARK: Initialisation

    public init() {}

    deinit {
        self.stop()
    }

    // MARK: Private functions

    /// Read responses.
    private func readResponses(socket: Socket) {
        do {
            var data = Data()
            let (bytesRead, address) = try socket.readDatagram(into: &data)
            guard
                let address = address,
                let (remoteHost, _) = Socket.hostnameAndPort(from: address)
            else {
                assert(false)
                SSDPDiscoveryLog.error("SSDPDiscovery readResponses: no address or remoteHost")
                return
            }

            if bytesRead > 0 {
                let response = String(data: data, encoding: .utf8)
                if let response = response {
                    SSDPDiscoveryLog.debug("SSDPDiscovery Received from \(remoteHost): \(response.replacingOccurrences(of: "\n", with: "\\n"))")
                    self.delegate?.ssdpDiscovery(self, didDiscoverService: SSDPService(host: remoteHost, response: response))
                } else {
                    SSDPDiscoveryLog.debug("SSDPDiscovery Received: got \(bytesRead) bytes but could not make utf8 string, host=\(remoteHost)")
                }
            } else {
                SSDPDiscoveryLog.debug("SSDPDiscovery Received: nothing from \(remoteHost)")
            }

        } catch let error {
            SSDPDiscoveryLog.error("SSDPDiscovery Socket error during read: \(error)")
        }
    }

    /// Force stop discovery closing the socket.
    private func _stop() {
        assert(Thread.current.isMainThread) // sockets access on main thread
        while self.sockets.count > 0 {
            self.sockets.removeLast().close()
        }
    }

    // MARK: Public functions

    /**
        Discover SSDP services for a duration.
        - Parameters:
            - duration: The amount of time to wait.
            - searchTarget: The type of the searched service.
    */
    open func discoverService(forDuration duration: TimeInterval = 10, searchTarget: String = "ssdp:all", port: Int32 = 1900, onInterfaces:[String?] = [nil]) {
        assert(Thread.current.isMainThread) // sockets access on main thread
        self._stop()
        self.delegate?.ssdpDiscoveryDidStart(self)

        self.queue.async {
            var sockets = [Socket]()
            
            for interface in onInterfaces {
                var socket: Socket? = nil
                do {
                    // Determine the multicase address based on the interface's address type (ipv4 vs ipv6)
                    let interfaceAddr = Socket.createAddress(for: interface ?? "127.0.0.1", on: 0)
                    let multicastAddr: String
                    let family: Socket.ProtocolFamily
                    switch interfaceAddr {
                    case .ipv6?:
                        multicastAddr = "ff02::c"   // use "ff02::c" for "link-local" or "ff05::c" for "site-local"
                        family = .inet6
                    default:
                        multicastAddr = "239.255.255.250"
                        family = .inet
                    }
                    socket = try Socket.create(family: family, type: .datagram, proto: .udp)
                    guard let socket = socket else {
                        continue
                    }
                    try socket.listen(on: 0, node: interface)   // node:nil means the default interface, for all others it should be the interface's IP address
                    
                    // Use Multicast (Caution: Gets blocked by iOS 16 unless the app has the multicast entitlement!)
                    let message = "M-SEARCH * HTTP/1.1\r\n" +
                    "MAN: \"ssdp:discover\"\r\n" +
                    "HOST: \(multicastAddr):\(port)\r\n" +
                    "ST: \(searchTarget)\r\n" +
                    "MX: \(Int(duration))\r\n\r\n"
                    guard let multicastAddress = Socket.createAddress(for: multicastAddr, on: port) else {
                        assert(false)
                        SSDPDiscoveryLog.info("SSDPDiscovery Socket address error: interface \(interface ?? "default")")
                        socket.close()
                        continue
                    }
                    try socket.write(from: message, to: multicastAddress)
                    sockets.append(socket)
                } catch let error {
                    // We ignore errors here because we get "-9980(0x-26FC), No route to host" if we're not allowed to multicast, and that's difficult to foresee.
                    // Also, with multiple interfaces, some may fail, and we need to ignore that, too, or it gets too difficult to handle for the caller
                    // to sort out which work and which don't.
                    socket?.close();
                    SSDPDiscoveryLog.info("SSDPDiscovery Socket error during setup: \(error) on interface \(interface ?? "default")")
                }
            } // end: for
            
            if sockets.count == 0 {
                // NOTE: this is what gets hit when "Allow appname to find devices on local networks?" iOS popup is showing (user has not made a choice yet).
                SSDPDiscoveryLog.info("SSDPDiscovery discoverService: no sockets, no-op")
                DispatchQueue.main.async {
                    self.delegate?.ssdpDiscoveryDidFinish(self, probablyShowingIOSPermissionDialog: true)
                }
                return
            }
            
            DispatchQueue.main.async { // self.sockets is always read/written on main thread (avoids race conditions)
                self.sockets = sockets
            }
            
            for socket in sockets {
                DispatchQueue.global().async() { // read on concurrent queue, as this can block
                    self.readResponses(socket: socket)
                }
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                self?.stop()
            }
        }
    }
    
    /// Stop the discovery before the timeout.
    open func stop() {
        SSDPDiscoveryLog.info("SSDPDiscovery: Stop SSDP discovery")
        self._stop()
        self.delegate?.ssdpDiscoveryDidFinish(self, probablyShowingIOSPermissionDialog: false)
    }
}
