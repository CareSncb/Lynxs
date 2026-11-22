import Foundation

/// Entrée du journal d'événements Leaperkim (format repris d'EUC World 2.68).
struct VeteranEvent: Identifiable, Codable, Hashable {
    var id: Int { index }
    var index: Int
    var code: Int
    var timestamp: Int          // secondes (heure locale de la roue) ; < 2023 = compteur interne
    var text: String            // texte fourni par la roue (format V3), sinon vide

    var date: Date? {
        timestamp >= 1_672_531_200 ? Date(timeIntervalSince1970: TimeInterval(timestamp)) : nil
    }

    var message: String {
        if let m = VeteranEvent.messages[code] { return m }
        return text.isEmpty ? "Événement \(code)" : text
    }

    var isError: Bool { !VeteranEvent.informational.contains(code) }

    static let informational: Set<Int> = [0, 1, 2, 3, 4, 5, 62, 63, 75, 76]

    static let messages: [Int: String] = [
        0: "Roue allumée (bouton)",
        1: "Roue éteinte (bouton)",
        2: "Roue éteinte (chargeur débranché)",
        3: "Roue éteinte (inactivité)",
        4: "Roue éteinte (redémarrage)",
        5: "Roue éteinte (après mise à jour firmware)",
        6: "Protection surintensité phase moteur activée",
        7: "Moteur coupé (capteur de levage)",
        8: "Moteur coupé (tension batterie trop basse)",
        9: "Moteur coupé au-dessus de 10 km/h (tension batterie trop basse)",
        10: "Accéléromètre axe X figé",
        11: "Accéléromètre axe Y figé",
        12: "Accéléromètre axe Z figé",
        13: "Gyroscope axe X figé",
        14: "Gyroscope axe Y figé",
        15: "Gyroscope axe Z figé",
        16: "Alimentation MCU > 3,45 V pendant 0,3 s ou plus",
        17: "Alimentation MCU < 3,15 V pendant 0,3 s ou plus",
        18: "Température MCU > 85 °C pendant 1 s ou plus",
        19: "Température MCU > 95 °C pendant 1 s ou plus",
        20: "Température MCU > 105 °C pendant 1 s ou plus",
        21: "Tension bus DC < 55 V pendant 0,1 s ou plus",
        22: "Tension bus DC < 63 V pendant 0,5 s ou plus",
        23: "Tension bus DC > 105 V pendant 0,5 s ou plus",
        24: "Moteur coupé (limite d'angle atteinte, courant > 80 A)",
        25: "Marge de sécurité < 10 % et courant > 40 A pendant 3 s ou plus",
        26: "Erreur capteur Hall (2 fois)",
        27: "Erreur capteur Hall (10 fois)",
        28: "Erreur capteur Hall (50 fois)",
        29: "Erreur capteur Hall",
        30: "Erreur capteur Hall (roue encore en équilibre)",
        31: "Roue éteinte (1 min après batterie faible)",
        32: "Moteur coupé (blocage moteur détecté)",
        33: "Redémarrage MCU (watchdog)",
        34: "Redémarrage MCU (broche nRST)",
        35: "Redémarrage MCU (logiciel)",
        36: "Courant bus DC trop élevé",
        37: "Erreur capteur Hall (en roulant)",
        38: "Pic / transitoire de tension bus DC",
        39: "Tension bus DC proche de la limite haute",
        40: "Surcharge batterie en descente / freinage pendant 3 s ou plus",
        41: "Roue éteinte (tension batterie trop haute)",
        42: "Roue éteinte à 10 km/h ou plus (tension batterie trop haute)",
        50: "Erreur écriture mémoire FLASH (adresse)",
        51: "Erreur écriture mémoire FLASH (occupée)",
        52: "Erreur écriture mémoire FLASH (programmation)",
        53: "Erreur écriture mémoire FLASH (délai dépassé)",
        60: "Erreur capteur Hall (répétée)",
        61: "Moteur coupé (limite d'angle atteinte, courant > 30 A)",
        62: "Demande de téléchargement du journal",
        63: "Horloge synchronisée depuis l'appli",
        64: "Courant de charge anormal",
        65: "Tension de cellule batterie trop basse",
        66: "Tension de cellule batterie trop haute",
        67: "Température batterie gauche trop haute",
        68: "Température batterie droite trop haute",
        69: "Tension de cellule trop basse (communication BMS)",
        70: "Tension de cellule trop haute (communication BMS)",
        71: "Température batterie gauche trop haute (communication BMS)",
        72: "Température batterie droite trop haute (communication BMS)",
        73: "Erreur de communication batterie",
        74: "Roue éteinte (surintensité)",
        75: "Calibration de l'offset de courant de phase",
        76: "Calibration IMU et offset du courant de charge",
        121: "Tension bus DC < 45 V pendant 0,1 s ou plus",
        122: "Tension bus DC < 50 V pendant 0,5 s ou plus",
        123: "Tension bus DC > 69 V pendant 0,5 s ou plus",
        221: "Tension bus DC < 68 V pendant 0,1 s ou plus",
        222: "Tension bus DC < 78 V pendant 0,5 s ou plus",
        223: "Tension bus DC > 131 V pendant 0,5 s ou plus",
        224: "Tension bus DC > 128 V pendant 0,8 s ou plus",
        225: "Tension bus DC > 142 V pendant 0,1 s ou plus",
        321: "Tension bus DC < 75 V pendant 0,1 s ou plus",
        322: "Tension bus DC < 90 V pendant 0,5 s ou plus",
        323: "Tension bus DC > 157 V pendant 0,5 s ou plus",
        324: "Tension bus DC > 154 V pendant 0,8 s ou plus"
    ]

    /// Extrait les entrées de journal contenues dans une trame de télémétrie (octet 46 = 32 ou 33).
    static func parse(frame f: [UInt8]) -> [VeteranEvent]? {
        guard f.count > 61 else { return nil }
        let i32 = { (o: Int) -> Int in Int(Int32(bitPattern: UInt32(Bytes.u32be(f, o)))) }
        if f.count > 84 && f[46] == 32 {
            // Format V1 : 3 entrées de 11 octets
            return (0..<3).map { i in
                let base = 11 * i
                return VeteranEvent(index: Int(f[47]) + i, code: Bytes.u16be(f, 48 + base),
                                    timestamp: i32(50 + base), text: "")
            }
        }
        if f[46] == 33 {
            // Format V3 : 1 entrée avec texte
            let index = Bytes.u16be(f, 48) & 0x0FFF
            let code = Bytes.u16be(f, 54)
            let count = Int(f[56])
            let textStart = 57 + 4 * count
            var text = ""
            if textStart < f.count - 4 {
                let bytes = f[textStart..<(f.count - 4)].filter { $0 != 0 }
                text = String(decoding: bytes, as: UTF8.self)
            }
            return [VeteranEvent(index: index, code: code, timestamp: i32(50), text: text)]
        }
        return nil
    }

    /// Commande de demande du journal.
    static var requestCommand: [UInt8] {
        VeteranDecoder.command(107, payload: [0x01, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01])
    }
}
