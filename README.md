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
- **Apple Watch, sans app montre** (fonctionne avec l'IPA iPhone seul, quel que soit l'outil de signature) :
  - écran **À l'écoute** de la montre : le titre affiche la vitesse et l'état du bridage ;
    **Lecture/Pause** = brider/débrider (2 appuis en moins de 5 s pour confirmer),
    **Suivant** = klaxon, **Précédent** = annonce vocale de l'état.
    Astuce : sur la montre, Réglages > Général > Réveil de l'écran > « Lancer auto. les apps audio ».
    La télécommande met la musique en pause tant que la roue est connectée (désactivable dans Réglages).
  - **notification « LynxDash connecté »** avec les boutons Brider à 25 km/h / Débrider ;
  - **Live Activity** dans la pile intelligente de la montre (vitesse, batterie, PWM, bridage).
- **Apple Watch, avec app montre** : version « iPhone + Apple Watch » (signature de la montre requise).

Garde-fous :
- refus au-dessus de 3 km/h ;
- l'appli relit la limite dans la roue pour confirmer le réglage ;
- la limite d'origine est mémorisée au premier bridage, puis restaurée au débridage (modifiable dans Réglages).

## Obtenir l'IPA (sans Mac)
1. Envoie tout le dossier, y compris `.github`, dans un dépôt GitHub (il peut être privé).
2. Onglet **Actions**, workflow « Build IPA » : il produit deux artefacts :
   - **LynxDash-ipa** : iPhone seul (le plus simple à sideloader, recommandé : la montre se pilote quand même) ;
   - **LynxDash-Watch-ipa** : iPhone + Apple Watch.
3. Sideloade l'IPA avec Sideloadly, AltStore ou SideStore. Pour la montre, Sideloadly est le plus fiable. Un compte Apple gratuit consomme 2 identifiants d'app (iPhone + montre).

iOS 18 minimum, watchOS 10 minimum (watchOS 11 pour la Live Activity sur la montre).

## Autres fonctions
- **Boîte noire** : la dernière minute de télémétrie est figée en cas de chute, de coupure Bluetooth en roulant, de PWM > 90 %, de surchauffe ou de tension anormale. Graphiques et export CSV.
- **Santé de la batterie** : chute de tension sous effort et résistance interne estimée, historique par roue, alerte si la batterie se dégrade.
- **Météo du trajet** (Open-Meteo) : pluie, rafales, risque de verglas sur les 3 prochaines heures, alerte à la connexion.
- **Classement et défis entre amis** : kilomètres du mois, records, défi collectif (données chiffrées avec le code du club).
- **Atelier** : prochaine révision et relances clients (WhatsApp / SMS), demandes de rendez-vous envoyées depuis l'appli du client (lien `lynxdash://rdv`), fiche diagnostic enrichie (santé batterie, incidents).

## Avant de rouler
Teste le bridage roue posée, puis vérifie la nouvelle limite sur un petit trajet à basse vitesse.
L'appli n'a pas été testée sur une roue réelle : confirme toujours la limite affichée.
