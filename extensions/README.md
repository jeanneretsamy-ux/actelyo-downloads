# Skills, Plugins et MCP — Actelyo Desktop 1.6.0

Dans le menu **Personnaliser**, ouvrir **Skills**, **Plugins** ou **MCP**. Les documents, modèles d'actes et moteurs RAG restent dans **Fichiers, rédaction et RAG**. Un skill est une consigne versionnée sélectionnable pour la rédaction ; il n'est pas indexé comme une pièce documentaire.

## Installer et inspecter

Chaque écran propose les paquets installés, le catalogue, une recherche et un filtre d'origine. **Ajouter** permet de créer un skill, importer un `SKILL.md`, un ZIP avec ses ressources, un manifeste JSON ou une configuration `mcpServers`. Un catalogue JSON peut être chargé depuis un fichier ou une URL HTTPS sans paramètres ni identifiants. Un catalogue ne doit contenir aucun secret. Les entrées importées restent disponibles après redémarrage.

Avant installation : consulter auteur déclaré, version, origine, empreinte SHA-256 du contenu normalisé installé, manifeste, liste et empreintes des fichiers, et permissions requises. Les paquets sont non signés : l'empreinte vérifie le contenu, pas l'identité de l'auteur. Les autorisations doivent être cochées explicitement. Un paquet installé est désactivé ; son activation est distincte. Aucune commande de paquet ne démarre à l'installation ou à l'activation.

**Inspecter** permet de lire les consignes et fichiers, modifier le manifeste en créant une nouvelle version, restaurer une version conservée, désactiver ou désinstaller. La modification préserve les ressources du ZIP. Un même numéro de version ne peut désigner deux contenus différents. L'intégrité est revérifiée avant activation, application d'un skill et connexion MCP. La désinstallation conserve les versions et l'audit ; elle ferme les connexions du paquet.

## Plugins

Un plugin Actelyo est un paquet déclaratif réunissant des skills et/ou des serveurs MCP. Les skills fournis apparaissent aussi dans la page Skills et suivent l'activation du plugin. Les scripts présents dans les ressources d'un skill restent inspectables ; ils ne sont pas exécutés par le moteur de rédaction. Ce format ne charge pas d'interface JavaScript arbitraire dans le navigateur.

## Connexions MCP

Le client utilise le SDK officiel `@modelcontextprotocol/sdk`, avec transports **stdio** et **Streamable HTTP**. Après installation et activation du paquet, **Connecter** affiche une confirmation native avec la commande exacte ou l'adresse du serveur. Une connexion réussie réalise l'initialisation MCP et charge son vrai catalogue d'outils et leurs schémas. Aucun serveur n'est reconnecté automatiquement au redémarrage.

**Voir les outils** permet de lire le schéma, saisir les arguments JSON et examiner puis exécuter un appel. Chaque appel requiert une confirmation native avec ses arguments exacts, y compris pour les outils déclarés en lecture seule. Les outils sont ici utilisables manuellement depuis cette interface ; cette version n'ajoute pas d'appels MCP autonomes par l'assistant.

Un processus stdio utilise les droits du compte Windows. Les permissions affichées ne constituent pas un bac à sable système. HTTPS est requis pour les serveurs distants ; HTTP est accepté en boucle locale. Les redirections et changements d'origine sont refusés. Les secrets doivent être placés dans `env` ou `headers`, jamais dans les arguments ou URL. Ils sont chiffrés avec Electron safeStorage/Windows et remplacés par des références dans les manifestes conservés. Les ressources de ZIP ordinaires ne sont pas soumises à une détection générale de secrets.

Le catalogue initial contient deux skills de synthèse/relecture, un MCP d'outils de texte et un plugin de rédaction combinant skill et MCP. Le serveur de texte fourni calcule réellement les statistiques et le SHA-256 du texte transmis, sans lire de fichiers ni utiliser le réseau. Aucun connecteur Outlook, Lexis ou autre service non implémenté n'est annoncé comme opérationnel.

## Format

```json
{
  "schemaVersion": 1,
  "id": "cabinet.redaction",
  "kind": "plugin",
  "name": "Rédaction du cabinet",
  "description": "Consignes de rédaction et connexion locale",
  "version": "1.0.0",
  "author": "Mon cabinet",
  "skills": [{
    "id": "relecture", "name": "Relecture", "description": "Contrôle final",
    "instructions": "Signaler les informations absentes et citer les pièces utilisées."
  }],
  "servers": [{
    "id": "local", "name": "Serveur du cabinet", "transport": "stdio",
    "command": "node", "args": ["C:/MonServeur/server.js"]
  }]
}
```

`kind` vaut `skill`, `plugin` ou `mcp`. Un paquet `skill` contient exactement un skill et aucun serveur ; un paquet `mcp` contient des serveurs et aucun skill. Un ZIP contient un `manifest.json` ou `actelyo-extension.json`, ou un seul `SKILL.md`, accompagné de ressources. Le frontmatter Markdown reconnaît `id`, `name`, `description`, `author`, `version`. Import : 24 Mo ; ZIP : 256 fichiers, 80 Mo décompressés au maximum, sans liens symboliques ni traversée de répertoires.

Un catalogue contient `{ "schemaVersion": 1, "entries": [ ...manifestes... ] }`. La validation de toutes les entrées précède le chargement. Charger un catalogue ne déclenche aucune installation ni commande.

Catalogue Actelyo public chargeable : https://raw.githubusercontent.com/jeanneretsamy-ux/actelyo-downloads/main/extensions/catalog.json

## Stockage et audit

Registre : `%APPDATA%/Actelyo ERP/extensions/extensions.sqlite`. Ressources : `extensions/packages/<empreinte>/`. Ces fichiers sont séparés de `local-workspace/knowledge.sqlite`. Les anciens skills sont repris une seule fois dans le registre, avec leur état d'activation, sans supprimer les lignes d'origine. Les pièces et l'index RAG restent conservés.

Le journal couvre revue, installation, modification, restauration, activation, application des skills à un projet, connexions, refus et appels MCP. Il contient versions et empreintes ; les arguments et résultats des outils ne sont journalisés que par leur empreinte. L'écran affiche les 1 000 derniers événements et propose un export JSON complet. Le chaînage SHA-256 permet de vérifier sa cohérence locale ; il ne constitue pas une preuve externe contre un administrateur capable de réécrire toute la base.

## Construction et validation

Installer les dépendances du dépôt puis exécuter `npm run electron:build` sur Windows. Le SDK MCP et js-yaml sont des dépendances du projet. Le catalogue et le serveur intégré sont des fichiers versionnés sous `public/extensions/`, copiés dans `dist/extensions/` par Vite. Le client MCP et le registre sont compilés dans le processus principal Electron, sans Node dans le renderer.

Les tests de livraison utilisent un profil isolé et des données fictives. Le test de transmission des consignes utilise une fixture HTTP de contrat ; il ne mesure pas la qualité d'un modèle. Les tests MCP exercent réellement les deux transports, l'initialisation, le catalogue et les appels ; les confirmations sont simulées uniquement dans le profil de test. Le profil installé du client n'est pas utilisé pour ces tests.

Après construction, lancer `npm run test:desktop-extensions`. Si nécessaire, définir `ACTELYO_DESKTOP_EXECUTABLE` avec le chemin absolu de l'exécutable à tester. Le script crée son profil sous `playwright-report/` et conserve son rapport et ses captures sous `outputs/`.
