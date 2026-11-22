# LynxDash

Tableau de bord iOS (SwiftUI + CoreBluetooth) pour gyroroues, avec **bridage à 25 km/h**.

## Marques gérées
| Marque | Télémétrie | Bridage 25 km/h |
|---|---|---|
| Leaperkim / Veteran (Lynx, Lynx S, Sherman, Patton…) | ✅ | ✅ (firmware avec CRC) |
| Nosfet | ✅ (même protocole que Leaperkim) | ✅ |
| Begode / Gotway / Extreme Bull (firmware d'origine) | ✅ | ✅ |
| Kingsong | ✅ | ✅ (avec le mot de passe des alarmes) |
| InMotion | ❌ pas encore | ❌ |

La marque est détectée automatiquement. Tu peux aussi la forcer dans Réglages.
Les protocoles et commandes de réglage proviennent de l'analyse d'EUC World 2.68.

## Bridage
- **Dans l'appli** : maintiens le bouton 2 secondes, puis confirme.
- **Bouton Action / Siri / Raccourcis** : actions « Brider la roue à 25 km/h » et « Débrider la roue ».
  Pour le bouton Action : Réglages iPhone > Bouton Action > Raccourci > LynxDash.
- **Apple Watch** : appli LynxDash sur la montre, bouton puis confirmation (version « iPhone + Apple Watch »).

Garde-fous :
- refus au-dessus de 3 km/h ;
- l'appli relit la limite dans la roue pour confirmer le réglage ;
- la limite d'origine est mémorisée au premier bridage, puis restaurée au débridage (modifiable dans Réglages).

## Obtenir l'IPA (sans Mac)
1. Envoie tout le dossier, y compris `.github`, dans un dépôt GitHub (il peut être privé).
2. Onglet **Actions**, workflow « Build IPA » : il produit deux artefacts :
   - **LynxDash-ipa** : iPhone seul (le plus simple à sideloader) ;
   - **LynxDash-Watch-ipa** : iPhone + Apple Watch.
3. Sideloade l'IPA avec Sideloadly, AltStore ou SideStore. Pour la montre, Sideloadly est le plus fiable. Un compte Apple gratuit consomme 2 identifiants d'app (iPhone + montre).

iOS 17 minimum, watchOS 10 minimum.

## Avant de rouler
Teste le bridage roue posée, puis vérifie la nouvelle limite sur un petit trajet à basse vitesse.
L'appli n'a pas été testée sur une roue réelle : confirme toujours la limite affichée.
