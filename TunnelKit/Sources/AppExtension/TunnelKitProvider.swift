//
//  TunnelKitProvider.swift
//  TunnelKit
//
//  Created by Davide De Rosa on 2/1/17.
//  Copyright (c) 2019 Davide De Rosa. All rights reserved.
//
//  https://github.com/keeshux
//
//  This file is part of TunnelKit.
//
//  TunnelKit is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  TunnelKit is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with TunnelKit.  If not, see <http://www.gnu.org/licenses/>.
//
//  This file incorporates work covered by the following copyright and
//  permission notice:
//
//      Copyright (c) 2018-Present Private Internet Access
//
//      Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
//
//      The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
//      THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
//

import NetworkExtension
import SwiftyBeaver
import __TunnelKitNative

private let log = SwiftyBeaver.self

/**
 Provides an all-in-one `NEPacketTunnelProvider` implementation for use in a
 Packet Tunnel Provider extension both on iOS and macOS.
 */
open class TunnelKitProvider: NEPacketTunnelProvider {
    
    // MARK: Tweaks
    
    /// An optional string describing host app version on tunnel start.
    public var appVersion: String?

    /// The log separator between sessions.
    public var logSeparator = "--- EOF ---"
    
    /// The maximum number of lines in the log.
    public var maxLogLines = 1000
    
    /// The number of milliseconds after which a DNS resolution fails.
    public var dnsTimeout = 3000
    
    /// The number of milliseconds after which the tunnel gives up on a connection attempt.
    public var socketTimeout = 5000
    
    /// The number of milliseconds after which the tunnel is shut down forcibly.
    public var shutdownTimeout = 2000
    
    /// The number of milliseconds after which a reconnection attempt is issued.
    public var reconnectionDelay = 1000
    
    /// The number of link failures after which the tunnel is expected to die.
    public var maxLinkFailures = 3

    /// The number of milliseconds between data count updates. Set to 0 to disable updates (default).
    public var dataCountInterval = 0
    
    /// A list of public DNS servers to use as fallback when none are provided (defaults to CloudFlare).
    public var fallbackDNSServers = [
        "1.1.1.1",
        "1.0.0.1",
        "2606:4700:4700::1111",
        "2606:4700:4700::1001"
    ]
    
    // MARK: Constants
    
    private let memoryLog = MemoryDestination()

    private let observer = InterfaceObserver()
    
    private let tunnelQueue = DispatchQueue(label: TunnelKitProvider.description())
    
    private let prngSeedLength = 64
    
    private var cachesURL: URL {
        guard let appGroup = appGroup else {
            fatalError("Accessing cachesURL before parsing app group")
        }
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            fatalError("No access to app group: \(appGroup)")
        }
        return containerURL.appendingPathComponent("Library/Caches/")
    }

    // MARK: Tunnel configuration

    private var appGroup: String!

    private lazy var defaults = UserDefaults(suiteName: appGroup)
    
    private var cfg: Configuration!
    
    private var strategy: ConnectionStrategy!
    
    // MARK: Internal state

    private var proxy: SessionProxy?
    
    private var socket: GenericSocket?

    private var pendingStartHandler: ((Error?) -> Void)?
    
    private var pendingStopHandler: (() -> Void)?
    
    private var isCountingData = false
    
    // MARK: NEPacketTunnelProvider (XPC queue)
    
    /// :nodoc:
    open override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {

        // required configuration
        do {
            guard let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol else {
                throw ProviderConfigurationError.parameter(name: "protocolConfiguration")
            }
            guard let serverAddress = tunnelProtocol.serverAddress else {
                throw ProviderConfigurationError.parameter(name: "protocolConfiguration.serverAddress")
            }
            guard let providerConfiguration = tunnelProtocol.providerConfiguration else {
                throw ProviderConfigurationError.parameter(name: "protocolConfiguration.providerConfiguration")
            }
            try appGroup = Configuration.appGroup(from: providerConfiguration)
            try cfg = Configuration.parsed(from: providerConfiguration)
            
            // inject serverAddress into sessionConfiguration.hostname
            if !serverAddress.isEmpty {
                var sessionBuilder = cfg.sessionConfiguration.builder()
                sessionBuilder.hostname = serverAddress
                var cfgBuilder = cfg.builder()
                cfgBuilder.sessionConfiguration = sessionBuilder.build()
                cfg = cfgBuilder.build()
            }
        } catch let e {
            var message: String?
            if let te = e as? ProviderConfigurationError {
                switch te {
                case .parameter(let name):
                    message = "Tunnel configuration incomplete: \(name)"
                    
                default:
                    break
                }
            }
            NSLog(message ?? "Unexpected error in tunnel configuration: \(e)")
            completionHandler(e)
            return
        }

        // optional credentials
        let credentials: SessionProxy.Credentials?
        if let username = protocolConfiguration.username, let passwordReference = protocolConfiguration.passwordReference,
            let password = try? Keychain.password(for: username, reference: passwordReference) {
            credentials = SessionProxy.Credentials(username, password)
        } else {
            credentials = nil
        }

        strategy = ConnectionStrategy(configuration: cfg)

        if let content = cfg.existingLog(in: appGroup) {
            var existingLog = content.components(separatedBy: "\n")
            if let i = existingLog.firstIndex(of: logSeparator) {
                existingLog.removeFirst(i + 2)
            }
            
            existingLog.append("")
            existingLog.append(logSeparator)
            existingLog.append("")
            memoryLog.start(with: existingLog)
        }

        configureLogging(
            debug: cfg.shouldDebug,
            customFormat: cfg.debugLogFormat
        )
        
        // override library configuration
        if let masksPrivateData = cfg.masksPrivateData {
            CoreConfiguration.masksPrivateData = masksPrivateData
        }

        log.info("Starting tunnel...")
        cfg.clearLastError(in: appGroup)
        
        guard SessionProxy.EncryptionBridge.prepareRandomNumberGenerator(seedLength: prngSeedLength) else {
            completionHandler(ProviderConfigurationError.prngInitialization)
            return
        }

        cfg.print(appVersion: appVersion)
        
        let proxy: SessionProxy
        do {
            proxy = try SessionProxy(queue: tunnelQueue, configuration: cfg.sessionConfiguration, cachesURL: cachesURL)
            refreshDataCount()
        } catch let e {
            completionHandler(e)
            return
        }
        proxy.credentials = credentials
        proxy.delegate = self
        self.proxy = proxy

        logCurrentSSID()

        pendingStartHandler = completionHandler
        tunnelQueue.sync {
            self.connectTunnel()
        }
    }
    
    /// :nodoc:
    open override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        pendingStartHandler = nil
        log.info("Stopping tunnel...")
        cfg.clearLastError(in: appGroup)

        guard let proxy = proxy else {
            flushLog()
            completionHandler()
            return
        }

        pendingStopHandler = completionHandler
        tunnelQueue.schedule(after: .milliseconds(shutdownTimeout)) { [weak self] in
            guard let weakSelf = self else {
                return
            }
            guard let pendingHandler = weakSelf.pendingStopHandler else {
                return
            }
            log.warning("Tunnel not responding after \(weakSelf.shutdownTimeout) milliseconds, forcing stop")
            weakSelf.flushLog()
            pendingHandler()
        }
        tunnelQueue.sync {
            proxy.shutdown(error: nil)
        }
    }
    
    /// :nodoc:
    open override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        var response: Data?
        switch Message(messageData) {
        case .requestLog:
            response = memoryLog.description.data(using: .utf8)

        case .dataCount:
            if let proxy = proxy, let dataCount = proxy.dataCount() {
                response = Data()
                response?.append(UInt64(dataCount.0)) // inbound
                response?.append(UInt64(dataCount.1)) // outbound
            }
            
        default:
            break
        }
        completionHandler?(response)
    }
    
    // MARK: Connection (tunnel queue)
    
    private func connectTunnel(upgradedSocket: GenericSocket? = nil, preferredAddress: String? = nil) {
        log.info("Creating link session")
        
        // reuse upgraded socket
        if let upgradedSocket = upgradedSocket, !upgradedSocket.isShutdown {
            log.debug("Socket follows a path upgrade")
            connectTunnel(via: upgradedSocket)
            return
        }
        
        strategy.createSocket(from: self, timeout: dnsTimeout, preferredAddress: preferredAddress, queue: tunnelQueue) { (socket, error) in
            guard let socket = socket else {
                self.disposeTunnel(error: error)
                return
            }
            self.connectTunnel(via: socket)
        }
    }
    
    private func connectTunnel(via socket: GenericSocket) {
        log.info("Will connect to \(socket)")
        cfg.clearLastError(in: appGroup)

        log.debug("Socket type is \(type(of: socket))")
        self.socket = socket
        self.socket?.delegate = self
        self.socket?.observe(queue: tunnelQueue, activeTimeout: socketTimeout)
    }
    
    private func finishTunnelDisconnection(error: Error?) {
        if let proxy = proxy, !(reasserting && proxy.canRebindLink()) {
            proxy.cleanup()
        }
        
        socket?.delegate = nil
        socket?.unobserve()
        socket = nil
        
        if let error = error {
            log.error("Tunnel did stop (error: \(error))")
            setErrorStatus(with: error)
        } else {
            log.info("Tunnel did stop on request")
        }
    }
    
    private func disposeTunnel(error: Error?) {
        flushLog()

        // failed to start
        if (pendingStartHandler != nil) {
            
            //
            // CAUTION
            //
            // passing nil to this callback will result in an extremely undesired situation,
            // because NetworkExtension would interpret it as "successfully connected to VPN"
            //
            // if we end up here disposing the tunnel with a pending start handled, we are
            // 100% sure that something wrong happened while starting the tunnel. in such
            // case, here we then must also make sure that an error object is ALWAYS
            // provided, so we do this with optional fallback to .socketActivity
            //
            // socketActivity makes sense, given that any other error would normally come
            // from SessionProxy.stopError. other paths to disposeTunnel() are only coming
            // from stopTunnel(), in which case we don't need to feed an error parameter to
            // the stop completion handler
            //
            pendingStartHandler?(error ?? ProviderError.socketActivity)
            pendingStartHandler = nil
        }
        // stopped intentionally
        else if (pendingStopHandler != nil) {
            pendingStopHandler?()
            pendingStopHandler = nil
        }
        // stopped externally, unrecoverable
        else {
            cancelTunnelWithError(error)
        }
    }
    
    // MARK: Data counter (tunnel queue)

    private func refreshDataCount() {
        guard dataCountInterval > 0 else {
            return
        }
        tunnelQueue.schedule(after: .milliseconds(dataCountInterval)) { [weak self] in
            self?.refreshDataCount()
        }
        guard isCountingData, let proxy = proxy, let dataCount = proxy.dataCount() else {
            defaults?.removeDataCountArray()
            return
        }
        defaults?.dataCountArray = [dataCount.0, dataCount.1]
    }
}

extension TunnelKitProvider: GenericSocketDelegate {
    
    // MARK: GenericSocketDelegate (tunnel queue)
    
    func socketDidTimeout(_ socket: GenericSocket) {
        log.debug("Socket timed out waiting for activity, cancelling...")
        reasserting = true
        socket.shutdown()

        // fallback: TCP connection timeout suggests falling back
        if let _ = socket as? NETCPSocket {
            guard tryNextProtocol() else {
                // disposeTunnel
                return
            }
        }
    }
    
    func socketDidBecomeActive(_ socket: GenericSocket) {
        guard let proxy = proxy else {
            return
        }
        if proxy.canRebindLink() {
            proxy.rebindLink(socket.link(withMTU: cfg.mtu))
            reasserting = false
        } else {
            proxy.setLink(socket.link(withMTU: cfg.mtu))
        }
    }
    
    func socket(_ socket: GenericSocket, didShutdownWithFailure failure: Bool) {
        guard let proxy = proxy else {
            return
        }
        
        var shutdownError: Error?
        let didTimeoutNegotiation: Bool
        var upgradedSocket: GenericSocket?

        // look for error causing shutdown
        shutdownError = proxy.stopError
        if failure && (shutdownError == nil) {
            shutdownError = ProviderError.linkError
        }
        didTimeoutNegotiation = (shutdownError as? SessionError == .negotiationTimeout)
        
        // only try upgrade on network errors
        if shutdownError as? SessionError == nil {
            upgradedSocket = socket.upgraded()
        }

        // clean up
        finishTunnelDisconnection(error: shutdownError)

        // fallback: UDP is connection-less, treat negotiation timeout as socket timeout
        if didTimeoutNegotiation {
            guard tryNextProtocol() else {
                // disposeTunnel
                return
            }
        }

        // reconnect?
        if reasserting {
            log.debug("Disconnection is recoverable, tunnel will reconnect in \(reconnectionDelay) milliseconds...")
            tunnelQueue.schedule(after: .milliseconds(reconnectionDelay)) {

                // give up if reasserting cleared in the meantime
                guard self.reasserting else {
                    return
                }

                self.connectTunnel(upgradedSocket: upgradedSocket, preferredAddress: socket.remoteAddress)
            }
            return
        }

        // shut down
        disposeTunnel(error: shutdownError)
    }
    
    func socketHasBetterPath(_ socket: GenericSocket) {
        log.debug("Stopping tunnel due to a new better path")
        logCurrentSSID()
        proxy?.reconnect(error: ProviderError.networkChanged)
    }
}

extension TunnelKitProvider: SessionProxyDelegate {
    
    // MARK: SessionProxyDelegate (tunnel queue)
    
    /// :nodoc:
    public func sessionDidStart(_ proxy: SessionProxy, remoteAddress: String, reply: SessionReply) {
        reasserting = false
        
        log.info("Session did start")
        
        log.info("Returned ifconfig parameters:")
        log.info("\tRemote: \(remoteAddress.maskedDescription)")
        log.info("\tIPv4: \(reply.options.ipv4?.description ?? "not configured")")
        log.info("\tIPv6: \(reply.options.ipv6?.description ?? "not configured")")
        // FIXME: refine logging of other routing policies
        if let routingPolicies = reply.options.routingPolicies {
            log.info("\tDefault gateway: \(routingPolicies.map { $0.rawValue })")
        } else {
            log.info("\tDefault gateway: not configured")
        }
        if let dnsServers = reply.options.dnsServers, !dnsServers.isEmpty {
            log.info("\tDNS: \(dnsServers.map { $0.maskedDescription })")
        } else {
            log.info("\tDNS: not configured")
        }
        log.info("\tDomain: \(reply.options.searchDomain?.maskedDescription ?? "not configured")")

        if reply.options.httpProxy != nil || reply.options.httpsProxy != nil {
            log.info("\tProxy:")
            if let proxy = reply.options.httpProxy {
                log.info("\t\tHTTP: \(proxy.maskedDescription)")
            }
            if let proxy = reply.options.httpsProxy {
                log.info("\t\tHTTPS: \(proxy.maskedDescription)")
            }
            if let bypass = reply.options.proxyBypassDomains {
                log.info("\t\tBypass domains: \(bypass.maskedDescription)")
            }
        }

        bringNetworkUp(remoteAddress: remoteAddress, configuration: proxy.configuration, reply: reply) { (error) in
            if let error = error {
                log.error("Failed to configure tunnel: \(error)")
                self.pendingStartHandler?(error)
                self.pendingStartHandler = nil
                return
            }
            
            log.info("Tunnel interface is now UP")
            
            proxy.setTunnel(tunnel: NETunnelInterface(impl: self.packetFlow, isIPv6: reply.options.ipv6 != nil))

            self.pendingStartHandler?(nil)
            self.pendingStartHandler = nil
        }

        isCountingData = true
        refreshDataCount()
    }
    
    /// :nodoc:
    public func sessionDidStop(_: SessionProxy, shouldReconnect: Bool) {
        log.info("Session did stop")

        isCountingData = false
        refreshDataCount()

        reasserting = shouldReconnect
        socket?.shutdown()
    }
    
    private func bringNetworkUp(remoteAddress: String, configuration: SessionProxy.Configuration, reply: SessionReply, completionHandler: @escaping (Error?) -> Void) {
        let routingPolicies = configuration.routingPolicies ?? reply.options.routingPolicies
        let isIPv4Gateway = routingPolicies?.contains(.IPv4) ?? false
        let isIPv6Gateway = routingPolicies?.contains(.IPv6) ?? false
        let isGateway = isIPv4Gateway || isIPv6Gateway

        var ipv4Settings: NEIPv4Settings?
        if let ipv4 = reply.options.ipv4 {
            var routes: [NEIPv4Route] = []

            // route all traffic to VPN?
            if isIPv4Gateway {
                let defaultRoute = NEIPv4Route.default()
                defaultRoute.gatewayAddress = ipv4.defaultGateway
                routes.append(defaultRoute)
//                for network in ["0.0.0.0", "128.0.0.0"] {
//                    let route = NEIPv4Route(destinationAddress: network, subnetMask: "128.0.0.0")
//                    route.gatewayAddress = ipv4.defaultGateway
//                    routes.append(route)
//                }
            }
            
            for r in ipv4.routes {
                let ipv4Route = NEIPv4Route(destinationAddress: r.destination, subnetMask: r.mask)
                ipv4Route.gatewayAddress = r.gateway
                routes.append(ipv4Route)
            }
            
            ipv4Settings = NEIPv4Settings(addresses: [ipv4.address], subnetMasks: [ipv4.addressMask])
            ipv4Settings?.includedRoutes = routes
            ipv4Settings?.excludedRoutes = []
        }

        var ipv6Settings: NEIPv6Settings?
        if let ipv6 = reply.options.ipv6 {
            var routes: [NEIPv6Route] = []

            // route all traffic to VPN?
            if isIPv6Gateway {
                let defaultRoute = NEIPv6Route.default()
                defaultRoute.gatewayAddress = ipv6.defaultGateway
                routes.append(defaultRoute)
//                for network in ["2000::", "3000::"] {
//                    let route = NEIPv6Route(destinationAddress: network, networkPrefixLength: 4)
//                    route.gatewayAddress = ipv6.defaultGateway
//                    routes.append(route)
//                }
            }

            for r in ipv6.routes {
                let ipv6Route = NEIPv6Route(destinationAddress: r.destination, networkPrefixLength: r.prefixLength as NSNumber)
                ipv6Route.gatewayAddress = r.gateway
                routes.append(ipv6Route)
            }

            ipv6Settings = NEIPv6Settings(addresses: [ipv6.address], networkPrefixLengths: [ipv6.addressPrefixLength as NSNumber])
            ipv6Settings?.includedRoutes = routes
            ipv6Settings?.excludedRoutes = []
        }

        var dnsServers = cfg.sessionConfiguration.dnsServers ?? reply.options.dnsServers ?? []

        // fall back
        if dnsServers.isEmpty {
            log.warning("DNS: No servers provided, using fall-back servers: \(fallbackDNSServers.maskedDescription)")
            dnsServers = fallbackDNSServers
        }

        let dnsSettings = NEDNSSettings(servers: dnsServers)
        if !isGateway {
            dnsSettings.matchDomains = [""]
        }
        if let searchDomain = cfg.sessionConfiguration.searchDomain ?? reply.options.searchDomain {
            dnsSettings.domainName = searchDomain
            dnsSettings.searchDomains = [searchDomain]
            if !isGateway {
                dnsSettings.matchDomains = dnsSettings.searchDomains
            }
        }
        
        // add direct routes to DNS servers
        if !isGateway {
            for server in dnsServers {
                if server.contains(":") {
                    ipv6Settings?.includedRoutes?.insert(NEIPv6Route(destinationAddress: server, networkPrefixLength: 128), at: 0)
                } else {
                    ipv4Settings?.includedRoutes?.insert(NEIPv4Route(destinationAddress: server, subnetMask: "255.255.255.255"), at: 0)
                }
            }
        }
        
        var proxySettings: NEProxySettings?
        if let httpsProxy = cfg.sessionConfiguration.httpsProxy ?? reply.options.httpsProxy {
            proxySettings = NEProxySettings()
            proxySettings?.httpsServer = httpsProxy.neProxy()
            proxySettings?.httpsEnabled = true
        }
        if let httpProxy = cfg.sessionConfiguration.httpProxy ?? reply.options.httpProxy {
            if proxySettings == nil {
                proxySettings = NEProxySettings()
            }
            proxySettings?.httpServer = httpProxy.neProxy()
            proxySettings?.httpEnabled = true
        }
        // only set if there is a proxy (proxySettings set to non-nil above)
        proxySettings?.exceptionList = cfg.sessionConfiguration.proxyBypassDomains ?? reply.options.proxyBypassDomains
        
        // block LAN if desired
        if routingPolicies?.contains(.blockLocal) ?? false {
            let table = RoutingTable()
            if isIPv4Gateway,
                let gateway = table.defaultGateway4()?.gateway(),
                let route = table.broadestRoute4(matchingDestination: gateway) {

                route.partitioned().forEach {
                    let destination = $0.network()
                    guard let netmask = $0.networkMask() else {
                        return
                    }
                    
                    log.info("Block local: Suppressing IPv4 route \(destination)/\($0.prefix())")
                    
                    let included = NEIPv4Route(destinationAddress: destination, subnetMask: netmask)
                    included.gatewayAddress = reply.options.ipv4?.defaultGateway
                    ipv4Settings?.includedRoutes?.append(included)
                }
            }
            if isIPv6Gateway,
                let gateway = table.defaultGateway6()?.gateway(),
                let route = table.broadestRoute6(matchingDestination: gateway) {

                route.partitioned().forEach {
                    let destination = $0.network()
                    let prefix = $0.prefix()
                    
                    log.info("Block local: Suppressing IPv6 route \(destination)/\($0.prefix())")

                    let included = NEIPv6Route(destinationAddress: destination, networkPrefixLength: prefix as NSNumber)
                    included.gatewayAddress = reply.options.ipv6?.defaultGateway
                    ipv6Settings?.includedRoutes?.append(included)
                }
            }
        }
        
        let newSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)
        newSettings.ipv4Settings = ipv4Settings
        newSettings.ipv6Settings = ipv6Settings
        newSettings.dnsSettings = dnsSettings
        newSettings.proxySettings = proxySettings
        
        setTunnelNetworkSettings(newSettings, completionHandler: completionHandler)
    }
}

extension TunnelKitProvider {
    private func tryNextProtocol() -> Bool {
        guard strategy.tryNextProtocol() else {
            disposeTunnel(error: ProviderError.exhaustedProtocols)
            return false
        }
        return true
    }
    
    // MARK: Logging
    
    private func configureLogging(debug: Bool, customFormat: String? = nil) {
        let logLevel: SwiftyBeaver.Level = (debug ? .debug : .info)
        let logFormat = customFormat ?? "$Dyyyy-MM-dd HH:mm:ss.SSS$d $L $N.$F:$l - $M"
        
        if debug {
            let console = ConsoleDestination()
            console.useNSLog = true
            console.minLevel = logLevel
            console.format = logFormat
            log.addDestination(console)
        }
        
        let memory = memoryLog
        memory.minLevel = logLevel
        memory.format = logFormat
        memory.maxLines = maxLogLines
        log.addDestination(memoryLog)
    }
    
    private func flushLog() {
        log.debug("Flushing log...")
        if let url = cfg.urlForLog(in: appGroup) {
            memoryLog.flush(to: url)
        }
    }
    
    private func logCurrentSSID() {
        if let ssid = observer.currentWifiNetworkName() {
            log.debug("Current SSID: '\(ssid.maskedDescription)'")
        } else {
            log.debug("Current SSID: none (disconnected from WiFi)")
        }
    }
    
//    private func anyPointer(_ object: Any?) -> UnsafeMutableRawPointer {
//        let anyObject = object as AnyObject
//        return Unmanaged<AnyObject>.passUnretained(anyObject).toOpaque()
//    }

    // MARK: Errors
    
    private func setErrorStatus(with error: Error) {
        defaults?.set(unifiedError(from: error).rawValue, forKey: Configuration.lastErrorKey)
    }
    
    private func unifiedError(from error: Error) -> ProviderError {
        if let te = error.tunnelKitErrorCode() {
            switch te {
            case .cryptoBoxRandomGenerator, .cryptoBoxAlgorithm:
                return .encryptionInitialization
                
            case .cryptoBoxEncryption, .cryptoBoxHMAC:
                return .encryptionData
                
            case .tlsBoxCA, .tlsBoxClientCertificate, .tlsBoxClientKey:
                return .tlsInitialization
                
            case .tlsBoxServerCertificate, .tlsBoxServerEKU:
                return .tlsServerVerification
                
            case .tlsBoxHandshake:
                return .tlsHandshake
                
            case .dataPathOverflow, .dataPathPeerIdMismatch:
                return .unexpectedReply
                
            case .dataPathCompression:
                return .serverCompression
                
            case .LZO:
                return .lzo

            default:
                break
            }
        } else if let se = error as? SessionError {
            switch se {
            case .negotiationTimeout, .pingTimeout, .staleSession:
                return .timeout
                
            case .badCredentials:
                return .authentication
                
            case .serverCompression:
                return .serverCompression
                
            case .failedLinkWrite:
                return .linkError
                
            case .noRouting:
                return .routing

            default:
                return .unexpectedReply
            }
        }
        return error as? ProviderError ?? .linkError
    }
}

private extension Proxy {
    func neProxy() -> NEProxyServer {
        return NEProxyServer(address: address, port: Int(port))
    }
}
