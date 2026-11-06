# Applications et modèles Actelyo

[Centre de téléchargement](https://jeanneretsamy-ux.github.io/actelyo-downloads/)

## Kit commun Windows

[Télécharger Actelyo Suite 1.2.0](https://github.com/jeanneretsamy-ux/actelyo-downloads/releases/download/actelyo-suite-v1.2.0/Actelyo-Suite-1.2.0-Kit.zip), extraire le ZIP puis ouvrir **Installer.cmd**. Le ZIP « Code » est destiné aux développeurs.

Le kit installe LLM Studio, ERP, RAG Desktop, RAG-Anything, Law Harness et OpenBousic. Il contrôle les SHA-256, l’espace et les versions, puis vérifie le démarrage et les cinq interfaces dans des profils séparés. Prévoir environ **35 Go libres** sur un poste Windows x64 neuf, plus les modèles choisis ; le plan affiche le besoin par disque.

Le choix des modèles est exclusivement Actelyo : **LegalYA v36 R2**, **LegalYA Architect V37** et **Qushu Embed**. **Matousse Decision 10K** est présenté comme candidat expérimental et ne figure pas dans les choix d’installation automatique. Aucun modèle générique n’est proposé ou téléchargé par défaut.

Les poids restent sur les dépôts privés Hugging Face d’Actelyo. Le kit demande un accès autorisé, par saisie masquée, sans enregistrer le jeton. **Installer-ModelesActelyo.cmd** reprend cette sélection séparément. Les fichiers sont téléchargés à une révision figée et vérifiés individuellement. Les GGUF LegalYA sont à importer dans LLM Studio. Qushu utilise **Sentence Transformers**, pas GGUF : son service d’inférence reste à configurer séparément. Télécharger les poids ne certifie ni le chargement sur votre matériel ni la qualité juridique.

**Verifier.cmd** contrôle le démarrage, l’affichage et les commandes accessibles des applications. Son rapport distingue ce diagnostic de la QA complète d’inférence et d’indexation. La configuration des modèles et la synchronisation des dossiers personnels ne sont pas effectuées par ce diagnostic.

## Validation technique interne

La CI continue de tester les six installations, les échanges réels et les 20 icônes Windows. Ses modèles de référence Qwen et Nomic sont définis uniquement dans `tests/qa-models.json`, absent du kit utilisateur. Ils ne sont pas renommés Actelyo. Aucune clé ni poids privés n’est transmis à la CI publique. Ce résultat ne constitue pas une validation d’inférence de LegalYA, Qushu ou Matousse.

Pour maintenir le catalogue, modifier `catalog.json`, puis exécuter `node scripts/sync-download-catalog.cjs --write`. Inclure `docs/desktop-catalog.json` dans le même changement. La QA vérifie que les modèles étrangers d’un ancien catalogue ne sont pas proposés et que les modèles privés ne déclenchent pas de téléchargement anonyme.

Actelyo LLM utilise llama.cpp. Son connecteur LM Studio emploie le SDK ouvert ; l’interface propriétaire LM Studio n’est pas incluse. Docker fournit des services séparés des interfaces Windows.

Le kit 1.2.0 contient le candidat ERP 1.8.6-rc.4 et Law Harness 2026.11.9. Les modèles, clés API et services externes restent à configurer. La paie prépare ou importe des résultats externes ; aucune transmission fiscale ni migration cloud n’est réalisée par le kit.
