# Applications Actelyo

[Centre de téléchargement](https://jeanneretsamy-ux.github.io/actelyo-downloads/)

Installateurs Windows, modèles GGUF et kit de services Docker. Le catalogue `catalog.json` contient les versions, tailles et SHA-256 des fichiers publiés. L'ERP desktop utilise ce catalogue et vérifie les fichiers avant de proposer leur ouverture.

Le kit ZIP télécharge les applications et modèles, et assemble les parties de Law Harness. Les données utilisateur, corpus et poids privés ne sont pas distribués. Les modèles publics restent séparés des installateurs.

Actelyo LLM possède sa propre interface et utilise llama.cpp. Son connecteur LM Studio emploie le SDK ouvert ; l'interface propriétaire LM Studio n'est pas incluse.

Docker fournit des services, et les interfaces graphiques Windows utilisent les EXE. Voir les limites de validation dans le LISEZ-MOI du kit Docker.
