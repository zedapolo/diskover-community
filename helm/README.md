# Diskover Community Edition – Chart Helm pour OpenShift

Déploie [Diskover Community Edition](https://github.com/diskoverdata/diskover-community) (indexeur de fichiers + interface `diskover-web`) sur OpenShift, avec :

- **Elasticsearch 8.x** géré par l'opérateur **ECK** (Elastic Cloud on Kubernetes) ;
- des **images Red Hat UBI 9** construites dans le cluster (BuildConfig / ImageStream) OU des **images pré-construites (avec Podman)** poussées sur votre registre interne (Harbor, Nexus, Quay...) pour un fonctionnement **100 % hors-ligne (Air-gap / Déconnecté)** ;
- des **scans planifiés** (CronJob) de partages **NFS** montés en lecture seule.

## Architecture

```
                    Route (TLS edge)
                          │
            ┌─────────────▼──────────────┐
            │ Pod diskover-web           │      ┌──────────────────────┐
            │  ├─ nginx    :8080         │      │ Elasticsearch (ECK)  │
            │  └─ php-fpm  127.0.0.1:9000├─────▶│ <name>-es-http:9200  │
            │  PVC SQLite (/data)        │      └──────────▲───────────┘
            └────────────────────────────┘                 │
                                                           │ index diskover-<nom>-<date>
            ┌────────────────────────────┐                 │
            │ CronJob diskover-scan-<n>  ├─────────────────┘
            │  scanner Python            │
            │  /data  ◀── PVC NFS (RO)   │
            └────────────────────────────┘
```

| Composant | Image de base Red Hat | Mode connecté (Build OpenShift) | Mode hors-ligne / Air-gap (Images pré-construites avec Podman) |
|---|---|---|---|
| Scanner (`diskover.py`) | `registry.access.redhat.com/ubi9/python-312` | BuildConfig `<release>-scanner` | `scanner.image.repository` (ex: `registry.corp.local/diskover/scanner:2.3.5`) |
| diskover-web | `registry.access.redhat.com/ubi9/nginx-126` + PHP 8.3 | BuildConfig `<release>-web` | `web.image.repository` (ex: `registry.corp.local/diskover/web:2.3.5`) |
| Elasticsearch | Image Elastic | Image officielle ECK (`docker.elastic.co`) | `elasticsearch.image` (ex: `registry.corp.local/elastic/elasticsearch:8.19.0`) |

Les images s'exécutent en UID arbitraire (compatibilité SCC `restricted-v2` OpenShift).

## Prérequis

- OpenShift 4.x et Helm 3.
- Opérateur **ECK** installé et **surveillant le namespace cible** (sinon le CR `Elasticsearch` reste sans effet).
- Un `StorageClass` fournissant des volumes RWO (Elasticsearch et base SQLite de diskover-web).
- **Droits cluster-admin** si vous utilisez `scans[].nfs` (création d'un PersistentVolume).
- **En environnement connecté** : accès sortant vers `github.com`, `pypi.org` et `cdn-ubi.redhat.com` pour les BuildConfig.
- **En environnement déconnecté (Air-gap / Offline)** : voir la section dédiée ci-dessous.

---

## Déploiement en Environnement Déconnecté (Offline / Air-gap)

En environnement déconnecté, la méthode standard consiste à désactiver les `BuildConfig` (`build.enabled: false`) et à déployer des images pré-construites avec **Podman**.

> [!NOTE]
> **Authentification registre :** Si les identifiants d'accès à votre registre privé sont déjà embarqués au niveau d'OpenShift (pull-secret global du cluster dans `openshift-config` ou secrets liés aux ServiceAccounts), vous n'avez **aucun secret `imagePullSecrets` à configurer**. OpenShift s'authentifie automatiquement.

### 1. Construire et transférer les images avec Podman

Depuis une machine connectée (bastion / poste de dev) :

```bash
# Cloner le dépôt
git clone -b v2.3.5 https://github.com/diskoverdata/diskover-community.git
cd diskover-community

# Construire les images applicatives avec Podman
podman build -t registry.corp.local/diskover/diskover-web:2.3.5 -f docker/Dockerfile.web .
podman build -t registry.corp.local/diskover/diskover-scanner:2.3.5 -f docker/Dockerfile.scanner .

# Récupérer l'image Elasticsearch 8.19.0 officielle
podman pull docker.elastic.co/elasticsearch/elasticsearch:8.19.0
podman tag docker.elastic.co/elasticsearch/elasticsearch:8.19.0 registry.corp.local/elastic/elasticsearch:8.19.0

# Option A : Pousser directement vers votre registre interne (si réseau accessible)
podman push registry.corp.local/diskover/diskover-web:2.3.5
podman push registry.corp.local/diskover/diskover-scanner:2.3.5
podman push registry.corp.local/elastic/elasticsearch:8.19.0

# Option B : Export archive tar (si transfert manuel en zone étanche / sas)
podman save -m -o diskover-airgap-images.tar \
  registry.corp.local/diskover/diskover-web:2.3.5 \
  registry.corp.local/diskover/diskover-scanner:2.3.5 \
  registry.corp.local/elastic/elasticsearch:8.19.0

# (Puis en zone déconnectée :)
podman load -i diskover-airgap-images.tar
podman push registry.corp.local/diskover/diskover-web:2.3.5
podman push registry.corp.local/diskover/diskover-scanner:2.3.5
podman push registry.corp.local/elastic/elasticsearch:8.19.0
```

### 2. Fichier de valeurs pour l'environnement hors-ligne

Créez un fichier `values-offline.yaml` (modèle disponible dans [`helm/diskover/values-offline.example.yaml`](diskover/values-offline.example.yaml)) :

```yaml
# Désactiver le build OpenShift in-cluster
build:
  enabled: false

# Laisser vide : les credentials de registre sont déjà intégrés dans OpenShift
imagePullSecrets: []

# Images pré-construites avec Podman
web:
  image:
    repository: registry.corp.local/diskover/diskover-web
    tag: "2.3.5"
    pullPolicy: IfNotPresent

scanner:
  image:
    repository: registry.corp.local/diskover/diskover-scanner
    tag: "2.3.5"
    pullPolicy: IfNotPresent
  supplementalGroups: [5000]

# Image Elasticsearch sur le registre interne
elasticsearch:
  create: true
  version: 8.19.0
  image: registry.corp.local/elastic/elasticsearch:8.19.0
  storage:
    size: 100Gi

scans:
  - name: archives
    schedule: "0 2 * * *"
    nfs:
      server: nas.corp.local
      path: /export/archives
      mountOptions: [nfsvers=4.1, ro, noatime]
```

### 3. Déploiement

```bash
oc new-project diskover
helm install diskover ./helm/diskover -f values-offline.yaml
```

---

## Installation Standard (Connectée avec Build in-cluster)

```bash
oc new-project diskover
helm install diskover ./helm/diskover -f mes-valeurs.yaml

oc get builds -w                 # attendre la fin des 2 builds
oc get elasticsearch             # attendre HEALTH=green
oc get route diskover-web -o jsonpath='https://{.spec.host}{"\n"}'
```

Premier démarrage : les pods `diskover-web` peuvent rester quelques minutes en `ImagePullBackOff` tant que les images ne sont pas construites ; ils démarrent seuls ensuite.

Connexion initiale : **`diskover` / `darkdata`**. À changer immédiatement (⚙ → Settings).
Puis ⚙ → **Indices** → sélectionner l'index `diskover-<nom>-<date>` → *Save Selection*.

---

## Paramètres de configuration

### Registre privé et Mode Hors-ligne (Air-gap)

| Paramètre | Défaut | Description |
|---|---|---|
| `imagePullSecrets` | `[]` | Secrets de registre (inutile si les credentials sont déjà dans OpenShift) |
| `web.image.repository` | `""` | Dépôt de l'image diskover-web pré-construite (ex: `registry.corp/diskover-web`) |
| `web.image.tag` | `""` (défaut: `appVersion`) | Tag de l'image web |
| `web.image.pullPolicy` | `IfNotPresent` | Politique de pull (`IfNotPresent`, `Always`) |
| `scanner.image.repository` | `""` | Dépôt de l'image scanner pré-construite (ex: `registry.corp/diskover-scanner`) |
| `scanner.image.tag` | `""` (défaut: `appVersion`) | Tag de l'image scanner |
| `scanner.image.pullPolicy` | `IfNotPresent` | Politique de pull (`IfNotPresent`, `Always`) |
| `elasticsearch.image` | `""` | Image Elasticsearch sur votre registre miroir (ex: `registry.corp/elastic/elasticsearch:8.19.0`) |

### Build in-cluster (OpenShift BuildConfig)

| Paramètre | Défaut | Description |
|---|---|---|
| `build.enabled` | `true` | Crée BuildConfig + ImageStream (`false` en environnement offline) |
| `build.git.uri` | dépôt officiel Diskover | Source Git des builds |
| `build.git.ref` | `v2.3.5` | Tag ou branche |
| `build.pullSecret` | `""` | Secret pour tirer `images.pythonBase` / `images.nginxBase` sur un registre privé |
| `build.pipIndexUrl` | `""` | URL miroir PyPI interne si build offline in-cluster |
| `build.pipExtraArgs` | `""` | Arguments additionnels pour pip (ex: `--trusted-host nexus.corp`) |
| `images.pythonBase` | `registry.access.redhat.com/ubi9/python-312:latest` | Base UBI Python du scanner |
| `images.nginxBase` | `registry.access.redhat.com/ubi9/nginx-126:latest` | Base UBI Nginx de diskover-web |

### Elasticsearch (ECK)

| Paramètre | Défaut | Description |
|---|---|---|
| `elasticsearch.create` | `true` | `false` = utiliser un cluster ES existant |
| `elasticsearch.name` | `diskover` | Nom du CR → service `<name>-es-http`, secret `<name>-es-elastic-user` |
| `elasticsearch.version` | `8.19.0` | Diskover CE requiert ES 8.x |
| `elasticsearch.image` | `""` | Surcharge de l'image (indispensable en environnement déconnecté) |
| `elasticsearch.count` | `1` | Nombre de nœuds |
| `elasticsearch.tls` | `true` | TLS sur l'API HTTP (certificat auto-signé ECK) |
| `elasticsearch.sslVerification` | `false` | Diskover ne sait pas charger un CA personnalisé |
| `elasticsearch.resources` | 1 CPU / 4 Gi | Le heap JVM = 50 % de la limite mémoire |
| `elasticsearch.storage.size` / `.storageClassName` | `50Gi` / défaut | Volume de données |
| `elasticsearch.host`, `.port`, `.user`, `.userSecret.name`, `.userSecret.key` | – | Utilisés si `create=false` |

### diskover-web

| Paramètre | Défaut | Description |
|---|---|---|
| `web.resources.nginx` / `.phpfpm` | voir `values.yaml` | Ressources par conteneur |
| `web.persistence.size` / `.storageClassName` | `1Gi` / défaut | Base SQLite (comptes, réglages) |
| `web.route.enabled` / `.host` / `.tls` | `true` / auto / `true` | Route OpenShift |

### Scanner

| Paramètre | Défaut | Description |
|---|---|---|
| `scanner.resources` | 0,5 CPU / 512 Mi → 2 Gi | Ressources du job |
| `scanner.supplementalGroups` | `[]` | GID additionnels pour lire les données NFS |
| `scanner.extraArgs` | `""` | Arguments de `diskover.py` (ex. `--threads 8`) |
| `scans[]` | `[]` | Un CronJob par entrée |

### Entrées `scans[]`

Chaque entrée de `scans[]` crée un CronJob dédié. 

> [!IMPORTANT]
> **Indexation multi-partages (Diskover Community Edition) :**
> Dans Diskover Community Edition, l'indexation de multiples partages dans un **même index Elasticsearch** doit obligatoirement se faire en un seul scan (l'option `--addtoindex` pour ajouter des chemins à un index existant est restreinte à la version commerciale).
> Pour regrouper plusieurs exports NFS dans le même index, utilisez la clé `shares:` : les exports sont montés comme sous-répertoires de `/data` (`/data/<name>`) et indexés ensemble dans `diskover-<name>-AAAAMMJJ`.

| Clé | Description |
|---|---|
| `name` | Nom court en minuscules ; sert aux noms de ressources et au nom d'index par défaut `diskover-<name>-AAAAMMJJ` |
| `schedule` | Expression cron (ex: `"0 2 * * *"`) |
| `indexName` | *(Optionnel)* Modèle de nom d'index (défaut : `"diskover-<name>-$(date +%Y%m%d)"`) |
| `shares[]` | **Multi-partages NFS (même index)** : liste d'exports montés sous `/data/<name>` |
| `shares[].name` | Identifiant du partage (sous-dossier de montage `/data/<name>`) |
| `shares[].server`, `.path` | Serveur NFS et chemin d'export distant |
| `shares[].size` | Capacité indicative (défaut `1Ti`) |
| `shares[].mountOptions` | Options de montage (défaut : `[nfsvers=4.1, ro, noatime]`) |
| `nfs` | **Mono-partage NFS** : monté directement sur `/data` (`server`, `path`, `size`, `mountOptions`) |
| `volumes[]` | **Multi-volumes K8s existants** : liste de volumes avec `mountPath` sous `/data` |
| `volume` | **Mono-volume K8s existant** : monté directement sur `/data` |

---

## Exploitation

```bash
# Lancer un scan immédiatement
oc create job --from=cronjob/diskover-scan-archives scan-manuel
oc logs -f job/scan-manuel

# Récupérer le mot de passe Elasticsearch généré par ECK
oc get secret diskover-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d && echo

# En mode images pré-construites : mise à jour après nouvelle image
oc rollout restart deploy/diskover-web
```

---

## Dépannage

| Symptôme | Piste |
|---|---|
| Pods web en `ImagePullBackOff` | En mode offline : vérifier `web.image.repository` et l'accès au registre interne depuis les nœuds OpenShift. En mode build : vérifier `oc get builds`. |
| Échec de build sur `dnf` ou `pip` | Pas d'accès Internet : passer en mode images pré-construites (`build.enabled: false`). |
| `Failed to connect to Elasticsearch` | ECK ne surveille pas le namespace, cluster pas encore `green`, ou `ES_HTTPS` incohérent avec `elasticsearch.tls`. |
| Erreur 500 / `is not writable` sur diskover-web | Droits PVC : `oc logs deploy/diskover-web -c php-fpm`. |
| Scan très court / index vide | Permissions NFS : vérifier `scanner.supplementalGroups` et les droits d'export sur le NAS. |
