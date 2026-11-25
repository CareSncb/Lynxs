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
    // Nordic UART (InMotion)
    static let nordicService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let nordicWrite = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let nordicNotify = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    @Published var state: ConnectionState = .idle
    @Published var discovered: [DiscoveredWheel] = []
    @Published var data = WheelData()
    @Published var connectedName: String?
    @Published var maxSpeed: Double = 0
    @Published var framesReceived = 0
    @Published var lastFrameDate: Date?
    @Published var limiterBusy = false
    @Published var limiterMessage: String?
    @Published private(set) var eventLog: [VeteranEvent] = []
    @Published private(set) var eventLogDownloading = false
    private var lastEventDate = Date.distantPast

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
            saveProfile { $0.cells = self.cellCount }
        }
    }
    @Published var speedAlarm: Double {
        didSet {
            UserDefaults.standard.set(speedAlarm, forKey: Keys.speedAlarm)
            saveProfile { $0.speedAlarm = self.speedAlarm }
        }
    }
    @Published var pwmAlarm: Double {
        didSet {
            UserDefaults.standard.set(pwmAlarm, forKey: Keys.pwmAlarm)
            saveProfile { $0.pwmAlarm = self.pwmAlarm }
        }
    }
    /// Limite « normale » de la roue, restaurée au débridage (mémorisée au premier bridage).
    @Published var normalLimit: Int? {
        didSet {
            if let v = normalLimit { UserDefaults.standard.set(v, forKey: Keys.normalLimit) }
            else { UserDefaults.standard.removeObject(forKey: Keys.normalLimit) }
            saveProfile { $0.normalLimit = self.normalLimit }
        }
    }

    var currentWheelID: String? { peripheral?.identifier.uuidString }

    /// Roue bridée définitivement à 25 km/h par l'atelier (code atelier obligatoire pour lever).
    @Published private(set) var isPermanentlyLimited = false
    private var lastPermanentEnforce = Date.distantPast

    /// Active / lève le bridage définitif de la roue connectée.
    /// Lever le bridage exige d'avoir saisi le code atelier (vérifié par l'écran appelant).
    @MainActor
    func setPermanentLimit(_ on: Bool, atelierCodeVerified: Bool) async -> String {
        guard let id = currentWheelID else { return "Roue non connectée" }
        if !on && !atelierCodeVerified { return "Code atelier requis" }
        ProfileStore.shared.update(id) { $0.permanentLimit = on ? true : nil }
        isPermanentlyLimited = on
        if on {
            let outcome = await engageLimiter()
            return "Bridage définitif activé — " + outcome.message(for: .engage)
        }
        return "Bridage définitif levé. La roue reste bridée tant que tu ne la débrides pas."
    }

    /// Si la limite a été remontée hors de LynxDash (appli du fabricant…), on rebride au prochain arrêt.
    private func enforcePermanentLimit(_ d: WheelData) {
        guard isPermanentlyLimited, d.speedLimitKnown,
              d.speedLimit > Double(BLEManager.restrictedLimit) + 0.5,
              pendingAction == nil, !limiterBusy,
              Date().timeIntervalSince(lastPermanentEnforce) > 30 else { return }
        lastPermanentEnforce = Date()
        SafetyMonitor.shared.notify(title: "Bridage définitif",
                                    body: "La limite a été modifiée hors de LynxDash : la roue est rebridée à 25 km/h au prochain arrêt.")
        Task { @MainActor in _ = await self.engageLimiter() }
    }
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

    /// Packs proposés (jusqu'à 60S / 252 V : InMotion P6 = 56S).
    static let cellOptions = [16, 20, 24, 30, 32, 36, 40, 42, 48, 50, 56, 60]

    static func defaultCells(_ brand: WheelBrand) -> Int {
        switch brand {
        case .leaperkim, .auto: return 36   // Lynx S : 151,2 V
        case .begode: return 24             // 100,8 V
        case .kingsong: return 20           // 84 V
        case .inmotion: return 56           // P6 : 235,2 V
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
    private var writeCharacteristic: CBCharacteristic?
    private var pollTimer: Timer?
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
        scheduledLimit = defaults.object(forKey: "scheduledLimit") as? Int
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
        let cells = profileCells()
            ?? UserDefaults.standard.object(forKey: Keys.cells(brand)) as? Int
            ?? BLEManager.defaultCells(brand)
        applyingProfile = true
        cellCount = cells
        applyingProfile = false
        isPermanentlyLimited = currentWheelID.flatMap { ProfileStore.shared.profile($0)?.permanentLimit } ?? false
        p.cellCount = cells
        (p as? InMotionProtocol)?.restoreKnownLimit()
        startPollingIfNeeded()
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
        lastAccepted = nil
        consecutiveRejects = 0
        framesReceived = 0
        data = WheelData()
        resetProtocol()
    }

    /// Lance une connexion en attente vers chaque roue connue : iOS connecte automatiquement
    /// la première qui s'allume, même en arrière-plan (ou relance l'appli si le système l'a fermée).
    func connectKnownWheels() {
        guard autoConnect, !Prefs.workshopMode, central.state == .poweredOn, state != .connected else { return }
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

    /// Mode atelier : on se connecte aux roues des clients sans les mémoriser ni enregistrer de trajet.
    func workshopModeChanged() {
        if Prefs.workshopMode { cancelPendingConnections() } else { connectKnownWheels() }
    }

    func forgetWheel(_ id: String) {
        knownWheels.removeValue(forKey: id)
        UserDefaults.standard.set(knownWheels, forKey: Keys.knownWheels)
    }

    private func rememberWheel(_ p: CBPeripheral) {
        knownWheels[p.identifier.uuidString] = p.name ?? connectedName ?? "Roue"
        UserDefaults.standard.set(knownWheels, forKey: Keys.knownWheels)
    }

    // MARK: - Profils par roue

    private var applyingProfile = false

    private func saveProfile(_ change: (inout WheelProfile) -> Void) {
        guard !applyingProfile, !Prefs.workshopMode, let id = currentWheelID else { return }
        ProfileStore.shared.update(id, change)
    }

    /// Recharge les réglages mémorisés pour cette roue (cellules, alarmes, limite habituelle).
    private func applyProfile(_ id: String) {
        guard let p = ProfileStore.shared.profile(id) else { return }
        applyingProfile = true
        if let v = p.speedAlarm { speedAlarm = v }
        if let v = p.pwmAlarm { pwmAlarm = v }
        if let v = p.normalLimit { normalLimit = v }
        applyingProfile = false
    }

    /// Cellules mémorisées pour la roue connectée, sinon celles de la marque.
    private func profileCells() -> Int? {
        guard let id = currentWheelID else { return nil }
        return ProfileStore.shared.profile(id)?.cells
    }

    var maintenanceItems: [MaintenanceItem] {
        guard let id = currentWheelID else { return [] }
        if let items = ProfileStore.shared.profile(id)?.maintenance { return items }
        let items = MaintenanceItem.defaults(total: data.totalDistance)
        ProfileStore.shared.update(id) { $0.maintenance = items }
        return items
    }

    func updateMaintenance(_ items: [MaintenanceItem]) {
        guard let id = currentWheelID else { return }
        ProfileStore.shared.update(id) { $0.maintenance = items }
        objectWillChange.send()
    }

    // MARK: - Journal d'événements

    var supportsEventLog: Bool { proto?.supportsEventLog ?? false }

    /// Télécharge le journal d'erreurs de la roue (Leaperkim, firmware récent).
    @MainActor
    func downloadEventLog() async {
        guard state == .connected, let p = proto, p.supportsEventLog else { return }
        eventLog = []
        eventLogDownloading = true
        lastEventDate = Date()
        send(p.eventLogRequest())
        // Fin quand plus rien n'arrive pendant 4 s (ou au bout de 2 minutes)
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Date().timeIntervalSince(lastEventDate) > 4 { break }
        }
        eventLogDownloading = false
    }

    // MARK: - Commandes de réglage

    var supportsSpecialLight: Bool { proto?.supportsSpecialLight ?? false }
    var supportsLight: Bool { !(proto?.lightCommands(.on).isEmpty ?? true) }
    var supportsPedals: Bool { !(proto?.pedalsCommands(.medium).isEmpty ?? true) }
    var specialLightLabel: String { proto?.specialLightLabel ?? "" }

    func setLight(_ mode: LightMode) {
        guard state == .connected, let p = proto else { return }
        send(p.lightCommands(mode))
    }

    var supportsWheelHorn: Bool { !(proto?.hornCommands().isEmpty ?? true) }

    /// Fait biper la roue. Renvoie false si la marque ne le permet pas.
    @discardableResult
    func wheelHorn() -> Bool {
        guard state == .connected, let p = proto else { return false }
        let cmds = p.hornCommands()
        guard !cmds.isEmpty else { return false }
        send(cmds)
        return true
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
        let entries = p.drainEvents()
        if !entries.isEmpty {
            var byIndex = Dictionary(eventLog.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
            for e in entries { byIndex[e.index] = e }
            eventLog = byIndex.values.sorted { $0.index > $1.index }
            lastEventDate = Date()
        }
    }

    // Filtre anti-valeurs aberrantes (toutes marques)
    private var lastAccepted: WheelData?
    private var lastAcceptedDate = Date.distantPast
    private var consecutiveRejects = 0
    @Published private(set) var outliersRejected = 0

    /// Rejette une trame dont les valeurs sautent de façon physiquement impossible.
    private func isPlausible(_ d: WheelData) -> Bool {
        guard let p = lastAccepted, consecutiveRejects < 8 else { return true }
        let dt = max(0.05, Date().timeIntervalSince(lastAcceptedDate))
        guard dt < 5 else { return true }
        if p.voltage > 0, abs(d.voltage - p.voltage) > max(6, p.voltage * 0.12) { return false }
        if abs(abs(d.speed) - abs(p.speed)) > 25 * max(1, dt) { return false }
        if p.totalDistance > 0, d.totalDistance > 0 {
            let delta = d.totalDistance - p.totalDistance
            if delta < -0.05 || delta > 0.1 * max(1, dt) { return false }
        }
        if d.hasPWM, p.hasPWM, abs(d.pwm - p.pwm) > 60 { return false }
        return true
    }

    /// Tension mesurée au-dessus du maximum du pack choisi → le pack est forcément plus gros.
    /// (Pas sur Begode : la tension y est calculée à partir du nombre de cellules.)
    private func autoCorrectCells(_ d: WheelData) {
        guard activeBrand != .begode, cellCount > 0,
              d.voltage > Double(cellCount) * 4.25 + 1,
              let fit = BLEManager.cellOptions.first(where: { Double($0) * 4.2 >= d.voltage - 0.5 }),
              fit != cellCount else { return }
        cellCount = fit
    }

    private func handle(_ d: WheelData) {
        if !isPlausible(d) {
            consecutiveRejects += 1
            outliersRejected += 1
            return
        }
        consecutiveRejects = 0
        autoCorrectCells(d)
        enforcePermanentLimit(d)
        lastAccepted = d
        lastAcceptedDate = Date()
        data = d
        framesReceived += 1
        lastFrameDate = Date()
        maxSpeed = max(maxSpeed, abs(d.speed))
        checkPendingAction(d)
        TelemetryHub.shared.ingest(d, manager: self)

        // Alarmes vitesse / PWM / marge de sécurité : gérées par SafetyAlarms (via TelemetryHub)
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

    private func startPollingIfNeeded() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard proto?.usesPolling == true else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.state == .connected, self.writeCharacteristic != nil,
                  let bytes = self.proto?.poll(now: Date()) else { return }
            self.write(bytes)
        }
    }

    private func write(_ bytes: [UInt8]) {
        guard let p = peripheral, let c = writeCharacteristic ?? characteristic else { return }
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
            guard !commands.isEmpty || p.usesPolling else { return "Commande indisponible pour cette roue" }
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
    /// `pinVerified` : vrai seulement quand le code PIN vient d'être saisi dans l'appli.
    @MainActor
    func releaseLimiter(pinVerified: Bool = false) async -> LimiterOutcome {
        if PinLock.required && !pinVerified { return .failed(PinLock.lockedMessage) }
        if isPermanentlyLimited { return .failed("Roue bridée définitivement à 25 km/h : lève d'abord le bridage définitif (code atelier)") }
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

    /// Limite à appliquer dès le prochain arrêt (restauration après l'antivol, vitesse max…).
    @Published var scheduledLimit: Int? {
        didSet { UserDefaults.standard.set(scheduledLimit, forKey: "scheduledLimit") }
    }

    /// Applique une limite maintenant si possible, sinon au prochain arrêt / à la prochaine connexion.
    @MainActor
    func applyLimitNowOrLater(_ kmh: Int) async -> String {
        if connectionBlockReason == nil && abs(data.speed) < BLEManager.stopSpeed {
            if let error = await setSpeedLimit(kmh) {
                scheduledLimit = kmh
                return "Pas encore appliquée (\(error)) : nouvel essai au prochain arrêt"
            }
            scheduledLimit = nil
            return "Limite réglée à \(kmh) km/h ✓"
        }
        scheduledLimit = kmh
        return "Limite de \(kmh) km/h programmée : appliquée dès que la roue est connectée et à l'arrêt"
    }

    /// Vitesse maximale choisie dans les réglages (protégée par le PIN côté interface).
    @MainActor
    func setMaxSpeed(_ kmh: Int) async -> String {
        if isPermanentlyLimited { return "Roue bridée définitivement à 25 km/h : vitesse max verrouillée" }
        normalLimit = kmh
        if isLimited || pendingAction == .engage {
            return "Vitesse max enregistrée (\(kmh) km/h) : elle s'appliquera au débridage"
        }
        return await applyLimitNowOrLater(kmh)
    }

    private func rememberNormalLimit() {
        guard data.speedLimitKnown else { return }
        let current = Int(data.speedLimit.rounded())
        // On ne mémorise que des vraies vitesses de route (pas 25, ni le 10 km/h de l'antivol)
        if current > BLEManager.restrictedLimit || (current == 0 && activeBrand == .begode) {
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
        // Limite programmée (antivol désarmé en roulant, vitesse max…)
        if pendingAction == nil, let target = scheduledLimit, !limiterBusy,
           let since = stoppedSince, Date().timeIntervalSince(since) >= BLEManager.stopDelay,
           Date().timeIntervalSince(lastPendingAttempt) > 5, connectionBlockReason == nil {
            lastPendingAttempt = Date()
            Task { @MainActor in
                if await self.setSpeedLimit(target) == nil {
                    self.scheduledLimit = nil
                    self.limiterMessage = "Limite de \(target) km/h appliquée ✓"
                }
            }
            return
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
                p.discoverServices([BLEManager.serviceUUID, BLEManager.nordicService])
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
        if !Prefs.workshopMode {
            rememberWheel(peripheral)
            applyProfile(peripheral.identifier.uuidString)
        }
        peripheral.delegate = self
        peripheral.discoverServices([BLEManager.serviceUUID, BLEManager.nordicService])
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
        writeCharacteristic = nil
        pollTimer?.invalidate()
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
        if let nordic = services.first(where: { $0.uuid == BLEManager.nordicService }) {
            // InMotion
            if proto == nil || preferredBrand == .auto { activate(.inmotion) }
            peripheral.discoverCharacteristics([BLEManager.nordicWrite, BLEManager.nordicNotify], for: nordic)
            return
        }
        for service in services where service.uuid == BLEManager.serviceUUID {
            peripheral.discoverCharacteristics([BLEManager.characteristicUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let chars = service.characteristics else { return }
        if service.uuid == BLEManager.nordicService {
            for c in chars {
                if c.uuid == BLEManager.nordicWrite { writeCharacteristic = c }
                if c.uuid == BLEManager.nordicNotify {
                    characteristic = c
                    peripheral.setNotifyValue(true, for: c)
                }
            }
            startPollingIfNeeded()
            return
        }
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
