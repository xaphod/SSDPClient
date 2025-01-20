import Foundation
import HeliumLogger
import LoggerAPI
import Socket

// MARK: Protocols

/// Delegate for service discovery
public protocol SSDPDiscoveryDelegate {
    /// Tells the delegate a requested service has been discovered.
    func ssdpDiscovery(_ discovery: SSDPDiscovery, didDiscoverService service: SSDPService)

    /// Tells the delegate that the discovery ended due to an error.
    func ssdpDiscovery(_ discovery: SSDPDiscovery, didFinishWithError error: Error)

    /// Tells the delegate that the discovery has started.
    func ssdpDiscoveryDidStart(_ discovery: SSDPDiscovery)

    /// Tells the delegate that the discovery has finished.
    func ssdpDiscoveryDidFinish(_ discovery: SSDPDiscovery)
}

public extension SSDPDiscoveryDelegate {
    func ssdpDiscovery(_ discovery: SSDPDiscovery, didDiscoverService service: SSDPService) {}

    func ssdpDiscovery(_ discovery: SSDPDiscovery, didFinishWithError error: Error) {}

    func ssdpDiscoveryDidStart(_ discovery: SSDPDiscovery) {}

    func ssdpDiscoveryDidFinish(_ discovery: SSDPDiscovery) {}
}

/// SSDP discovery for UPnP devices on the LAN
public class SSDPDiscovery {

    /// The UDP socket
    private var sockets: [Socket] = []

    /// Delegate for service discovery
    public var delegate: SSDPDiscoveryDelegate?
    
    // MARK: Initialisation

    public init() {
        HeliumLogger.use()
    }

    deinit {
        self.stop()
    }

    // MARK: Private functions

    /// Read responses.
    private func readResponses(sockets: [Socket]) {
        for socket in sockets {
            do {
                var data = Data()
                let (bytesRead, address) = try socket.readDatagram(into: &data)
                guard
                    let address = address,
                    let (remoteHost, _) = Socket.hostnameAndPort(from: address)
                else {
                    assert(false)
                    Log.error("SSDPDiscovery readResponses: no address or remoteHost")
                    continue
                }

                if bytesRead > 0 {
                    let response = String(data: data, encoding: .utf8)
                    if let response = response {
                        Log.debug("SSDPDiscovery Received: \(response) from \(remoteHost)")
                        self.delegate?.ssdpDiscovery(self, didDiscoverService: SSDPService(host: remoteHost, response: response))
                    }
                } else {
                    Log.debug("SSDPDiscovery Received: nothing from \(remoteHost)")
                }

            } catch let error {
                Log.error("SSDPDiscovery Socket error: \(error)")
                DispatchQueue.main.async {
                    self._stop()
                    self.delegate?.ssdpDiscovery(self, didFinishWithError: error)
                }
            }
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
        Log.info("SSDPDiscovery: Start SSDP discovery for \(Int(duration)) duration...")
        assert(Thread.current.isMainThread) // sockets access on main thread
        self.delegate?.ssdpDiscoveryDidStart(self)

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
                    Log.info("SSDPDiscovery Socket address error: interface \(interface ?? "default")")
                    socket.close()
                    continue
                }
                try socket.write(from: message, to: multicastAddress)
                self.sockets.append(socket)
            } catch let error {
                // We ignore errors here because we get "-9980(0x-26FC), No route to host" if we're not allowed to multicast, and that's difficult to foresee.
                // Also, with multiple interfaces, some may fail, and we need to ignore that, too, or it gets too difficult to handle for the caller
                // to sort out which work and which don't.
                socket?.close();
                Log.info("SSDPDiscovery Socket error: \(error) on interface \(interface ?? "default")")
            }
        }

        let sockets = self.sockets
        if sockets.count == 0 {
            Log.info("SSDPDiscovery discoverService: no sockets, no-op")
            self.delegate?.ssdpDiscoveryDidFinish(self)
            assert(false)
            return
        }

        DispatchQueue.global().async() {
            self.readResponses(sockets: sockets)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.stop()
        }
    }
    
    /// Stop the discovery before the timeout.
    open func stop() {
        Log.info("SSDPDiscovery: Stop SSDP discovery")
        self._stop()
        self.delegate?.ssdpDiscoveryDidFinish(self)
    }
}
