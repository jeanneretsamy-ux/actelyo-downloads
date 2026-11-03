# Actelyo Suite — installation et diagnostic Windows

Ce kit utilise les installateurs publics référencés dans le `catalog.json` joint. Les versions et SHA-256 sont figés ensemble. Il ne télécharge pas le code des dépôts privés. Le moteur QA est inclus ; Python, npm et Playwright ne sont pas à installer séparément par l’utilisateur.

1. Extraire entièrement le ZIP sur un disque local.
2. Ouvrir `Installer.cmd`. Vérifier les versions et l’espace annoncé, puis confirmer la sélection. Les six applications et deux modèles publics de test sont téléchargés et contrôlés.
3. Consulter `Rapports/<date>/installation.json`, puis `rapport.html` et `qa.json` pour la QA. Un échec ou un prérequis manquant produit un code de sortie non nul ; « installé » ne signifie jamais automatiquement « compatible ».

Le kit réserve séparément les téléchargements et l’installation. Prévoir environ 32 Gio (35 Go) libres pour une installation complète neuve, davantage si d’autres programmes écrivent sur le disque. Déplacer les téléchargements ne déplace pas les applications : les installateurs conservent leurs dossiers Windows habituels. Le moteur RAG-Anything est notamment recherché par l’ERP à son emplacement standard.

## Choisir les applications ou un autre dossier de téléchargement

Dans PowerShell, depuis ce dossier :

```powershell
# Aucun téléchargement ni installation : plan et contrôle de l’espace
.\Installer-ActelyoSuite.ps1 -Mode Plan -IncludeTestModels
# Télécharger seulement les paquets, y compris pour les installer ailleurs
.\Installer-ActelyoSuite.ps1 -Mode Download -Destination D:\Actelyo
# Exemple de sélection limitée
.\Installer-ActelyoSuite.ps1 -Mode Install -Apps llm,erp,rag-anything,openbousic -SkipVerification
# Contrôler les applications déjà installées et retrouver les modèles téléchargés
.\Installer-ActelyoSuite.ps1 -Mode Verify -Destination D:\Actelyo
```

La QA complète attend les six applications et les modèles de test. Une sélection partielle n’est pas déclarée conforme à la suite entière. Le kit garde les versions déjà à jour ou plus récentes ; la preuve de compatibilité ne peut porter que sur les versions effectivement testées, enregistrées dans le rapport. Il ne désinstalle pas d’anciennes applications, ne supprime pas les données, ne redémarre pas l’Explorateur et ne tue pas les applications personnelles. Fermer les applications avant de les mettre à jour.

`-SkipVerification` permet l’installation seule, avec un statut `installed` et une interopérabilité `not-tested`. Le lanceur `Installer.cmd` conserve par défaut toute la QA de la suite complète.

## Ce qui est réellement testé ensemble

- Démarrage des cinq interfaces ; RAG-Anything est un moteur secondaire sans interface séparée.
- Vrai serveur de LLM Studio, vrais modèles Qwen et Nomic, génération et embeddings locaux, sans serveur simulé ni modèle renommé LegalYA. Le profil documentaire Nomic utilise un contexte, un lot et un lot physique de 2 048 tokens : le lot physique par défaut de 64 tokens est insuffisant pour les pièces. Ces réglages sont enregistrés dans le rapport pour pouvoir les reproduire dans le profil personnel.
- ERP connecté à ce serveur : import d’une pièce synthétique, indexation, recherche et réponse avec sources ; un éventuel repli extractif est identifié dans le rapport.
- ERP → RAG-Anything : recherche secondaire réelle sur la même pièce, avec conservation de son identifiant.
- ERP → vérificateur installé de Law Harness : transfert de passages, assemblage automatique des citations et chronologie avec références contrôlées. Ce test ne prouve pas l’inférence du chat de Law Harness ni la pertinence juridique des affirmations.
- RAG Desktop → LLM Studio : collecte de document, embeddings, recherche vectorielle et réponse sourcée.
- OpenBousic → LLM Studio : découverte du modèle et véritable génération via son chemin de test de fournisseur. L’édition autonome de fichiers et le contrôle du navigateur restent couverts par leurs QA dédiées.
- Coexistence des interfaces pendant les échanges, avec ports séparés. Les processus lancés par la QA sont fermés ensuite.

Les tests utilisent des profils séparés et des documents fictifs. La QA refuse d’importer ou de configurer un profil si l’application ne permet pas de vérifier son isolation. Elle ne reconfigure pas les profils personnels. Pour l’usage quotidien, choisir le serveur et les modèles dans les réglages habituels des applications : LLM Studio → Serveur et API ; reporter son URL locale et ses identifiants de modèles dans ERP, RAG, Law Harness et OpenBousic. Les index et les dossiers personnels ne sont pas automatiquement synchronisés entre applications.

Qwen 0.6B et Nomic sont des modèles de test sous Apache-2.0. Aucun poids LegalYA/Matousse ni corpus privé n’est inclus. Réussir ces tests techniques n’est pas une certification de qualité juridique ni une garantie de toutes les fonctionnalités de chaque application. La construction du ZIP seule ne certifie rien : consulter le résultat de la QA sur machine Windows propre pour la combinaison exacte de versions.
