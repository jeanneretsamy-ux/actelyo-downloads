# Applications Actelyo

[Centre de téléchargement](https://jeanneretsamy-ux.github.io/actelyo-downloads/)

## Kit commun Windows

[Télécharger Actelyo Suite 1.0.0](https://github.com/jeanneretsamy-ux/actelyo-downloads/releases/download/actelyo-suite-v1.0.0/Actelyo-Suite-1.0.0-Kit.zip), extraire le ZIP puis ouvrir **Installer.cmd**. Pour un utilisateur, ce ZIP contient les scripts et le moteur QA nécessaires ; le ZIP « Code » du dépôt est destiné aux développeurs.

Le kit installe les six composants du catalogue : LLM Studio, ERP, RAG Desktop, RAG-Anything, Law Harness et OpenBousic. Il vérifie les empreintes, préserve les versions déjà à jour et contrôle l’espace avant chaque installation. Prévoir environ **35 Go libres** sur un Windows x64 neuf ; le plan affiche le besoin exact par disque. Les deux modèles publics de test sont téléchargés séparément.

**Verifier.cmd** teste les applications installées avec des profils et des pièces synthétiques séparés : génération et embeddings dans LLM Studio, recherches ERP/RAG, moteur secondaire RAG-Anything, transfert des références ERP vers Law Harness et génération par le fournisseur OpenBousic. Les rapports JSON/HTML distinguent installation, échanges réussis, échecs et contrôles bloqués. La certification juridique des modèles, la synchronisation des dossiers personnels et l’ensemble des fonctionnalités de chaque application ne sont pas déduits de ces tests techniques. Consulter les résultats associés à la version du kit dans sa release.

Pour préparer un autre ordinateur ou choisir un autre disque de téléchargement, voir [le guide du kit](suite/LIRE-MOI.md). Les fichiers déjà téléchargés et vérifiés peuvent être réutilisés ; aucun modèle ni corpus privé n’est inclus.

Installateurs Windows, modèles GGUF et kit de services Docker. Le catalogue `catalog.json` contient les versions, tailles et SHA-256 des fichiers publiés. L'ERP desktop utilise ce catalogue et vérifie les fichiers avant de proposer leur ouverture.

Le kit ZIP télécharge les applications et modèles, et assemble les parties de Law Harness. Les données utilisateur, corpus et poids privés ne sont pas distribués. Les modèles publics restent séparés des installateurs.

Actelyo LLM possède sa propre interface et utilise llama.cpp. Son connecteur LM Studio emploie le SDK ouvert ; l'interface propriétaire LM Studio n'est pas incluse.

Docker fournit des services, et les interfaces graphiques Windows utilisent les EXE. Voir les limites de validation dans le LISEZ-MOI du kit Docker.
