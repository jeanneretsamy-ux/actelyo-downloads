# Actelyo Suite — installation Windows et modèles Actelyo

1. Extraire entièrement le ZIP sur un disque local, puis ouvrir **Installer.cmd**.
2. Vérifier les versions et l’espace. Le kit préserve les versions plus récentes et les données personnelles.
3. Le diagnostic démarre les cinq interfaces avec des profils isolés. Consulter `Rapports/<date>/installation.json`, `qa.json` et `rapport.html`. `startup-pass` valide le démarrage ; `interoperability: not-tested` indique que l’inférence et l’indexation ne sont pas testées sur ce poste.
4. Choisir les modèles Actelyo, ou appuyer sur Entrée pour plus tard. **Installer-ModelesActelyo.cmd** reprend cette étape sans réinstaller les applications.

## Modèles proposés

| Modèle | Rôle | Fichiers et exécution |
| --- | --- | --- |
| LegalYA v36 R2 | Rédaction juridique | GGUF, environ 1,25 Go ; import dans LLM Studio |
| LegalYA Architect V37 | Rédaction juridique | GGUF, environ 7,38 Go ; import et mémoire adaptée requis |
| Qushu Embed | Indexation et recherche | Environ 0,58 Go ; service Sentence Transformers à configurer séparément |
| Matousse Decision 10K | Routage et décision | Candidat expérimental non proposé en installation automatique ; modèle de base et moteur spécifique requis |

Les dépôts Hugging Face sont privés : votre compte doit y être autorisé. Le téléchargement utilise `HF_TOKEN` ou le jeton Hugging Face déjà configuré sur le PC ; sinon une saisie masquée est demandée. Le kit n’enregistre pas ce jeton. Les poids ne sont pas publiés dans le ZIP ni envoyés sur GitHub.

Les fichiers vont dans `Paquets-Actelyo/Modeles/<identifiant>`. `modeles-verifies.json` enregistre leurs tailles et SHA-256 après réussite de tous les téléchargements et indique explicitement que l’inférence n’est pas testée. Chaque modèle est lié à une révision figée. Un fichier existant incorrect est refusé, jamais écrasé ; les fichiers corrects sont réutilisés hors ligne.

## Espace et sélection

Prévoir environ 35 Go pour les applications sur un poste neuf, plus les modèles choisis. Les réserves sont vérifiées par disque avant installation. Déplacer les téléchargements ne déplace pas les applications, qui conservent leur dossier Windows habituel.

```powershell
# Plan sans téléchargement ni installation
.\Installer-ActelyoSuite.ps1 -Mode Plan
.\Installer-ModelesActelyo.ps1 -Mode Plan -Models legalya-v36-r2,qushu-embed
# Autre disque pour les modèles
.\Installer-ModelesActelyo.ps1 -Destination D:\Actelyo\Modeles
# Vérification du démarrage et de l’affichage
.\Installer-ActelyoSuite.ps1 -Mode Verify -StartupOnly
```

Fermer les applications avant de les mettre à jour. Le kit ne redémarre pas l’Explorateur et ne termine pas les applications personnelles. `-SkipVerification` signifie installation seule, avec interopérabilité non testée.

## Portée des tests

Le diagnostic utilisateur ne télécharge aucun modèle tiers. La QA interne du dépôt teste séparément génération, embeddings, recherches ERP/RAG, RAG-Anything, références transférées à Law Harness et fournisseur OpenBousic. Ses modèles publics de référence sont définis hors du ZIP utilisateur. Ce profil exige explicitement `-IncludeTestModels -TestModelsCatalog <fichier>` ; il ne nécessite aucune clé privée.

La QA des applications ne certifie pas automatiquement l’inférence des modèles Actelyo, la pertinence juridique, le contrôle du navigateur ou toutes les fonctions. Les références littérales contrôlées par Law Harness conservent une revue humaine pour leur portée juridique.
