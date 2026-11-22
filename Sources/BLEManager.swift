import Foundation
import CoreBluetooth
import AudioToolbox

struct DiscoveredWheel: Identifiable {
    let id: UUID
    let name: String
    var rssi: Int
    let peripheral: CBPeripheral
}

enum ConnectionState: Equatable {
    case bluetoothOff
    case unauthorized
    case idle
    case scanning
    case connecting
    case connected
}

final class BLEManager: NSObject, ObservableObject {
    /// Instance unique, partagée par l'app, les Raccourcis (bouton Action, Siri) et l'Apple Watch.
    static let shared = BLEManager()

    /// Vitesse de bridage.
    static let restrictedLimit = 25

    // Service UART BLE commun aux roues Leaperkim, Begode et Kingsong
    static let serviceUUID = CBUUID(string: "FFE0")
    static let characteristicUUID = CBUUID(string: "FFE1")

    @Published var state: ConnectionState = .idle
    @Published var discovered: [DiscoveredWheel] = []
    @Published var data = WheelData()
    @Published var connectedName: String?
    @Published var maxSpeed: Double = 0
    @Published var framesReceived = 0
    @Published var lastFrameDate: Date?
    @Published var limiterBusy = false
    @Published var limiterMessage: String?

    /// Action de bridage programmée, appliquée dès que la roue est à l'arrêt.
    @Published var pendingAction: LimiterAction? {
        didSet {
            UserDefaults.standard.set(pendingAction?.rawValue, forKey: Keys.pending)
        }
    }

    /// Marque détectée (ou forcée) pour la roue connectée.
    @Published private(set) var activeBrand: WheelBrand = .auto

    /// Marque choisie dans les réglages (.auto = détection).
    @Published var preferredBrand: WheelBrand {
        didSet {
            UserDefaults.standard.set(preferredBrand.rawValue, forKey: Keys.brand)
            resetProtocol()
        }
    }

    /// Nombre de cellules du pack, mémorisé par marque.
    @Published var cellCount: Int {
        didSet {
            UserDefaults.standard.set(cellCount, forKey: Keys.cells(activeBrand))
            proto?.cellCount = cellCount
        }
    }
    @Published var speedAlarm: Double {
        didSet { UserDefaults.standard.set(speedAlarm, forKey: Keys.speedAlarm) }
    }
    @Published var pwmAlarm: Double {
        didSet { UserDefaults.standard.set(pwmAlarm, forKey: Keys.pwmAlarm) }
    }
    /// Limite « normale » de la roue, restaurée au débridage (mémorisée au premier bridage).
    @Published var normalLimit: Int? {
        didSet {
            if let v = normalLimit { UserDefaults.standard.set(v, forKey: Keys.normalLimit) }
            else { UserDefaults.standard.removeObject(forKey: Keys.normalLimit) }
        }
    }

    var currentWheelID: String? { peripheral?.identifier.uuidString }
    var crcFailures: Int { proto?.crcFailures ?? 0 }
    var rejectedFrames: Int { proto?.rejectedFrames ?? 0 }
    var speedLimitRange: ClosedRange<Int> { proto?.speedLimitRange ?? 10...99 }

    /// Vrai quand la roue confirme une limite de 25 km/h.
    var isLimited: Bool {
        state == .connected && data.speedLimitKnown
            && abs(data.speedLimit - Double(BLEManager.restrictedLimit)) < 0.5
    }

    private enum Keys {
        static let speedAlarm = "speedAlarm"
        static let pwmAlarm = "pwmAlarm"
        static let lastWheel = "lastWheelUUID"
        static let normalLimit = "normalLimit"
        static let brand = "preferredBrand"
        static let pending = "pendingLimiterAction"
        static let knownWheels = "knownWheels"
        static let autoConnect = "autoConnect"
        static func cells(_ b: WheelBrand) -> String { "cells_\(b.rawValue)" }
    }

    static func defaultCells(_ brand: WheelBrand) -> Int {
        switch brand {
        case .leaperkim, .auto: return 36   // Lynx S : 151,2 V
        case .begode: return 24             // 100,8 V
        case .kingsong: return 20           // 84 V
        }
    }

    /// Roues déjà connectées (UUID → nom), reconnectées automatiquement dès qu'elles s'allument.
    @Published private(set) var knownWheels: [String: String] =
        UserDefaults.standard.dictionary(forKey: "knownWheels") as? [String: String] ?? [:]
    @Published var autoConnect: Bool = UserDefaults.standard.object(forKey: "autoConnect") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoConnect, forKey: Keys.autoConnect)
            if autoConnect { connectKnownWheels() } else { cancelPendingConnections() }
        }
    }

    private var central: CBCentralManager!
    private var pendingPeripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var proto: WheelProtocol?
    private var detectBuffer: [UInt8] = []
    private var userDisconnected = false
    private var lastAlarm = Date.distantPast
    private var kingsongProbeSent = false
    private var stoppedSince: Date?
    private var lastPendingAttempt = Date.distantPast
    private var pendingAttempts = 0

    override init() {
        let defaults = UserDefaults.standard
        let brand = WheelBrand(rawValue: defaults.string(forKey: Keys.brand) ?? "") ?? .auto
        preferredBrand = brand
        cellCount = defaults.object(forKey: Keys.cells(.leaperkim)) as? Int ?? 36
        speedAlarm = defaults.object(forKey: Keys.speedAlarm) as? Double ?? 0
        pwmAlarm = defaults.object(forKey: Keys.pwmAlarm) as? Double ?? 80
        normalLimit = defaults.object(forKey: Keys.normalLimit) as? Int
        pendingAction = LimiterAction(rawValue: defaults.string(forKey: Keys.pending) ?? "")
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "be.gyrocare.lynxdash.central",
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
    }

    // MARK: - Protocole

    private func resetProtocol() {
        detectBuffer.removeAll()
        kingsongProbeSent = false
        if preferredBrand == .auto {
            proto = nil
            activeBrand = .auto
        } else {
            activate(preferredBrand)
        }
    }

    private func activate(_ brand: WheelBrand) {
        guard let p = ProtocolDetector.make(brand) else { return }
        proto = p
        activeBrand = brand
        let cells = UserDefaults.standard.object(forKey: Keys.cells(brand)) as? Int
            ?? BLEManager.defaultCells(brand)
        cellCount = cells
        p.cellCount = cells
        send(p.initialCommands())
    }

    // MARK: - Actions

    func startScan() {
        guard central.state == .poweredOn else { return }
        discovered.removeAll()
        if state != .connected && state != .connecting { state = .scanning }
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        if central.isScanning { central.stopScan() }
        if state == .scanning { state = .idle }
    }

    func connect(_ wheel: DiscoveredWheel) {
        stopScan()
        if let current = peripheral, current.identifier != wheel.id {
            userDisconnected = true
            central.cancelPeripheralConnection(current)
        }
        userDisconnected = false
        peripheral = wheel.peripheral
        connectedName = wheel.name
        state = .connecting
        prepareForNewConnection()
        central.connect(wheel.peripheral, options: nil)
    }

    /// Déconnexion manuelle : la reconnexion automatique reprend au prochain allumage de la roue
    /// (relance de l'appli ou bouton « Connexion auto »).
    func disconnect() {
        userDisconnected = true
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        cancelPendingConnections()
        state = .idle
    }

    func resetMaxSpeed() {
        maxSpeed = 0
    }

    private func prepareForNewConnection() {
        framesReceived = 0
        data = WheelData()
        resetProtocol()
    }

    /// Lance une connexion en attente vers chaque roue connue : iOS connecte automatiquement
    /// la première qui s'allume, même en arrière-plan (ou relance l'appli si le système l'a fermée).
    func connectKnownWheels() {
        guard autoConnect, central.state == .poweredOn, state != .connected else { return }
        let ids = knownWheels.keys.compactMap(UUID.init(uuidString:))
        guard !ids.isEmpty else { return }
        for p in central.retrievePeripherals(withIdentifiers: ids) where pendingPeripherals[p.identifier] == nil {
            pendingPeripherals[p.identifier] = p
            p.delegate = self
            central.connect(p, options: nil)
        }
        if state != .connecting { state = .connecting }
        if connectedName == nil { connectedName = "Recherche de tes roues…" }
    }

    private func migrateLastWheel() {
        if let old = UserDefaults.standard.string(forKey: Keys.lastWheel), knownWheels[old] == nil {
            knownWheels[old] = "Roue"
            UserDefaults.standard.set(knownWheels, forKey: Keys.knownWheels)
            UserDefaults.standard.removeObject(forKey: Keys.lastWheel)
        }
    }

    private func cancelPendingConnections(except keep: UUID? = nil) {
        for (id, p) in pendingPeripherals where id != keep {
            central.cancelPeripheralConnection(p)
        }
        pendingPeripherals = pendingPeripherals.filter { $0.key == keep }
    }

    func forgetWheel(_ id: String) {
        knownWheels.removeValue(forKey: id)
        UserDefaults.standard.set(knownWheels, forKey: Keys.knownWheels)
    }

    private func rememberWheel(_ p: CBPeripheral) {
        knownWheels[p.identifier.uuidString] = p.name ?? connectedName ?? "Roue"
        UserDefaults.standard.set(knownWheels, forKey: Keys.knownWheels)
    }

    // MARK: - Commandes de réglage

    var supportsSpecialLight: Bool { proto?.supportsSpecialLight ?? false }
    var specialLightLabel: String { proto?.specialLightLabel ?? "" }

    func setLight(_ mode: LightMode) {
        guard state == .connected, let p = proto else { return }
        send(p.lightCommands(mode))
    }

    func setPedals(_ mode: PedalsMode) {
        guard state == .connected, let p = proto else { return }
        send(p.pedalsCommands(mode))
    }

    // MARK: - Réception

    private func received(_ value: Data) {
        if proto == nil {
            detectBuffer.append(contentsOf: value)
            if let brand = ProtocolDetector.detect(detectBuffer) {
                activate(brand)
                let pending = Data(detectBuffer)
                detectBuffer.removeAll()
                process(pending)
            } else if detectBuffer.count > 512 {
                detectBuffer.removeFirst(detectBuffer.count - 64)
            }
            return
        }
        process(value)
    }

    private func process(_ value: Data) {
        guard let p = proto else { return }
        for frame in p.feed(value) {
            handle(frame)
        }
    }

    private func handle(_ d: WheelData) {
        data = d
        framesReceived += 1
        lastFrameDate = Date()
        maxSpeed = max(maxSpeed, abs(d.speed))
        checkPendingAction(d)
        TelemetryHub.shared.ingest(d, manager: self)

        let speedTriggered = speedAlarm > 0 && abs(d.speed) >= speedAlarm
        let pwmTriggered = d.hasPWM && pwmAlarm > 0 && d.pwm >= pwmAlarm
        if (speedTriggered || pwmTriggered) && Date().timeIntervalSince(lastAlarm) > 1.0 {
            lastAlarm = Date()
            AudioServicesPlayAlertSound(SystemSoundID(1005))
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    /// Kingsong n'envoie rien tant qu'on ne lui a rien demandé sur certains modèles :
    /// si rien n'est reconnu après 3 s, on envoie une requête Kingsong (ignorée par les autres marques).
    private func scheduleKingsongProbe() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.state == .connected, self.proto == nil, !self.kingsongProbeSent else { return }
            self.kingsongProbeSent = true
            self.write(KingsongProtocol.frame(0x9B))
        }
    }

    // MARK: - Envoi

    private func write(_ bytes: [UInt8]) {
        guard let p = peripheral, let c = characteristic else { return }
        let type: CBCharacteristicWriteType =
            c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(Data(bytes), for: c, type: type)
    }

    private func send(_ commands: [WheelCommand]) {
        guard !commands.isEmpty else { return }
        var delay: TimeInterval = 0
        for cmd in commands {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.write(cmd.bytes)
            }
            delay += cmd.delayAfter
        }
    }

    // MARK: - Bridage

    /// Raison liée à la connexion / à la roue empêchant d'envoyer un réglage (hors vitesse).
    var connectionBlockReason: String? {
        guard state == .connected, characteristic != nil, framesReceived > 0, let p = proto else {
            return "Roue non connectée"
        }
        return p.settingsBlockReason()
    }

    /// Raison pour laquelle on ne peut pas envoyer de réglage tout de suite, ou nil si c'est possible.
    var settingsBlockReason: String? {
        if let reason = connectionBlockReason { return reason }
        guard abs(data.speed) < BLEManager.stopSpeed else {
            return "Roue en mouvement"
        }
        return nil
    }

    /// En dessous de cette vitesse (km/h), la roue est considérée à l'arrêt.
    static let stopSpeed = 2.0
    /// Durée d'arrêt avant d'appliquer un bridage programmé (s).
    static let stopDelay: TimeInterval = 1.5

    /// Attend que la roue soit connectée et envoie des données (utile au lancement par Siri / la montre).
    @MainActor
    func waitForTelemetry(timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state == .connected && framesReceived > 0 && data.speedLimitKnown { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Envoie une limite de vitesse et vérifie que la roue l'a bien appliquée.
    /// Renvoie nil en cas de succès, sinon un message d'erreur.
    @MainActor
    func setSpeedLimit(_ kmh: Int) async -> String? {
        if let reason = settingsBlockReason { return reason }
        guard let p = proto else { return "Roue non connectée" }
        guard p.speedLimitRange.contains(kmh) else {
            return "Valeur hors limites (\(p.speedLimitRange.lowerBound) à \(p.speedLimitRange.upperBound) km/h)"
        }
        limiterBusy = true
        defer { limiterBusy = false }

        for attempt in 0..<2 {
            let commands = p.speedLimitCommands(kmh: kmh)
            guard !commands.isEmpty else { return "Commande indisponible pour cette roue" }
            send(commands)
            let sendTime = commands.reduce(0.0) { $0 + $1.delayAfter }
            try? await Task.sleep(nanoseconds: UInt64(sendTime * 1_000_000_000))
            for _ in 0..<30 {
                if abs(data.speedLimit - Double(kmh)) < 0.5 { return nil }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if attempt == 0, settingsBlockReason != nil { break }
        }
        return "La roue n'a pas confirmé le réglage (limite lue : \(Int(data.speedLimit)) km/h)"
    }

    /// Bride à 25 km/h. En roulant, le bridage est programmé et s'applique dès l'arrêt.
    @MainActor
    func engageLimiter() async -> LimiterOutcome {
        if isLimited {
            pendingAction = nil
            return .applied
        }
        if let reason = connectionBlockReason { return .failed(reason) }
        rememberNormalLimit()
        if abs(data.speed) >= BLEManager.stopSpeed {
            pendingAction = .engage
            return .scheduled
        }
        return await apply(.engage)
    }

    /// Débride. En roulant, le débridage est programmé et s'applique dès l'arrêt.
    @MainActor
    func releaseLimiter() async -> LimiterOutcome {
        if pendingAction == .engage && !isLimited {
            // Bridage pas encore appliqué : on l'annule simplement
            pendingAction = nil
            return .applied
        }
        guard let target = normalLimit, target != BLEManager.restrictedLimit else {
            return .failed("Limite d'origine inconnue : règle-la dans Réglages")
        }
        if let reason = connectionBlockReason { return .failed(reason) }
        if abs(data.speed) >= BLEManager.stopSpeed {
            pendingAction = .release
            return .scheduled
        }
        _ = target
        return await apply(.release)
    }

    func cancelPending() {
        pendingAction = nil
    }

    private func rememberNormalLimit() {
        guard data.speedLimitKnown else { return }
        let current = Int(data.speedLimit.rounded())
        if current != BLEManager.restrictedLimit {
            // 0 = tiltback désactivé (Begode) : on le mémorise aussi pour le restaurer
            normalLimit = current
        }
    }

    @MainActor
    private func apply(_ action: LimiterAction) async -> LimiterOutcome {
        let error: String?
        switch action {
        case .engage:
            rememberNormalLimit()
            error = await setSpeedLimit(BLEManager.restrictedLimit)
        case .release:
            guard let target = normalLimit else { return .failed("Limite d'origine inconnue") }
            if target == 0 && activeBrand == .begode {
                if let reason = settingsBlockReason { return .failed(reason) }
                write([0x22])   // '"' : tiltback désactivé
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                error = data.speedLimit == 0 ? nil : "La roue n'a pas confirmé le réglage"
            } else {
                error = await setSpeedLimit(target)
            }
        }
        if let error { return .failed(error) }
        pendingAction = nil
        AudioServicesPlaySystemSound(1520)
        return .applied
    }

    /// Appelé à chaque trame : applique l'action programmée une fois la roue arrêtée.
    private func checkPendingAction(_ d: WheelData) {
        if abs(d.speed) < BLEManager.stopSpeed {
            if stoppedSince == nil { stoppedSince = Date() }
        } else {
            stoppedSince = nil
        }
        guard let action = pendingAction, !limiterBusy,
              let since = stoppedSince, Date().timeIntervalSince(since) >= BLEManager.stopDelay,
              Date().timeIntervalSince(lastPendingAttempt) > 5 else { return }
        lastPendingAttempt = Date()
        Task { @MainActor in
            let outcome = await self.apply(action)
            switch outcome {
            case .applied:
                self.pendingAttempts = 0
                self.limiterMessage = action == .engage ? "Bridage appliqué à l'arrêt ✓" : "Débridage appliqué à l'arrêt ✓"
                // Signal sonore + vibration : utile quand le téléphone est en poche
                AudioServicesPlayAlertSound(SystemSoundID(1025))
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            case .failed(let reason):
                self.pendingAttempts += 1
                if self.pendingAttempts >= 3 {
                    self.pendingAction = nil
                    self.pendingAttempts = 0
                    self.limiterMessage = "Action programmée abandonnée : \(reason)"
                }
            case .scheduled:
                break
            }
        }
    }
}

enum LimiterAction: String {
    case engage, release
}

enum LimiterOutcome {
    case applied
    case scheduled
    case failed(String)

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    func message(for action: LimiterAction) -> String {
        switch self {
        case .applied:
            return action == .engage ? "Roue bridée à 25 km/h ✓" : "Roue débridée ✓"
        case .scheduled:
            return action == .engage
                ? "Bridage programmé : il s'appliquera dès que tu seras à l'arrêt"
                : "Débridage programmé : il s'appliquera dès que tu seras à l'arrêt"
        case .failed(let reason):
            return (action == .engage ? "Bridage impossible : " : "Débridage impossible : ") + reason
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if state != .connected { state = .idle }
            migrateLastWheel()
            connectKnownWheels()
        case .unauthorized:
            state = .unauthorized
        default:
            state = .bluetoothOff
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name = peripheral.name ?? advName, !name.isEmpty else { return }
        let rssi = RSSI.intValue
        if let index = discovered.firstIndex(where: { $0.id == peripheral.identifier }) {
            discovered[index].rssi = rssi
        } else {
            discovered.append(DiscoveredWheel(id: peripheral.identifier, name: name,
                                              rssi: rssi, peripheral: peripheral))
        }
        discovered.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // iOS a relancé l'appli en arrière-plan : on récupère la roue connectée ou en attente
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] else { return }
        for p in restored {
            p.delegate = self
            if p.state == .connected {
                peripheral = p
                connectedName = p.name ?? knownWheels[p.identifier.uuidString]
                state = .connected
                prepareForNewConnection()
                p.discoverServices([BLEManager.serviceUUID])
            } else {
                pendingPeripherals[p.identifier] = p
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        cancelPendingConnections(except: peripheral.identifier)
        pendingPeripherals.removeAll()
        self.peripheral = peripheral
        userDisconnected = false
        state = .connected
        connectedName = peripheral.name ?? knownWheels[peripheral.identifier.uuidString] ?? connectedName
        prepareForNewConnection()
        rememberWheel(peripheral)
        peripheral.delegate = self
        peripheral.discoverServices([BLEManager.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        pendingPeripherals.removeValue(forKey: peripheral.identifier)
        if state != .connected {
            state = .idle
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connectKnownWheels() }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else {
            pendingPeripherals.removeValue(forKey: peripheral.identifier)
            return
        }
        characteristic = nil
        TelemetryHub.shared.wheelDisconnected()
        if userDisconnected {
            state = .idle
            self.peripheral = nil
        } else {
            // Roue éteinte ou hors de portée : on attend qu'une des roues connues se rallume
            state = .connecting
            self.peripheral = nil
            prepareForNewConnection()
            connectKnownWheels()
            if pendingPeripherals[peripheral.identifier] == nil {
                pendingPeripherals[peripheral.identifier] = peripheral
                central.connect(peripheral, options: nil)
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == BLEManager.serviceUUID {
            peripheral.discoverCharacteristics([BLEManager.characteristicUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars where c.uuid == BLEManager.characteristicUUID {
            characteristic = c
            peripheral.setNotifyValue(true, for: c)
            if let p = proto { send(p.initialCommands()) } else { scheduleKingsongProbe() }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let value = characteristic.value else { return }
        received(value)
    }
}
