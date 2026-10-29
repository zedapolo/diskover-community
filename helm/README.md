# Diskover Community Edition – Chart Helm pour OpenShift

Déploie [Diskover Community Edition](https://github.com/diskoverdata/diskover-community) (indexeur de fichiers + interface `diskover-web`) sur OpenShift, avec :

- **Elasticsearch 8.x** géré par l'opérateur **ECK** (Elastic Cloud on Kubernetes) ;
- des **images Red Hat UBI 9** construites dans le cluster (BuildConfig / ImageStream) ;
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

| Composant | Image de base Red Hat | Construction |
|---|---|---|
| Scanner (`diskover.py`) | `registry.access.redhat.com/ubi9/python-312` | BuildConfig `<release>-scanner` |
| diskover-web | `registry.access.redhat.com/ubi9/nginx-126` + PHP 8.3 (module `php:8.3` UBI 9) | BuildConfig `<release>-web` |
| Elasticsearch | image Elastic choisie par l'opérateur ECK | CR `Elasticsearch` |

Les deux images sont construites depuis le dépôt Git de Diskover (`build.git.ref`, par défaut `v2.3.5`) avec un Dockerfile inline. Elles s'exécutent en UID arbitraire (SCC `restricted-v2`).

## Prérequis

- OpenShift 4.x et Helm 3.
- Opérateur **ECK** installé et **surveillant le namespace cible** (sinon le CR `Elasticsearch` reste sans effet).
- Pods de build avec accès sortant vers `github.com`, `pypi.org` et les dépôts UBI Red Hat (`cdn-ubi.redhat.com`). En environnement déconnecté : miroir interne (voir `images.*` et `build.git.uri`).
- Un `StorageClass` fournissant des volumes RWO (Elasticsearch et base SQLite de diskover-web).
- **Droits cluster-admin** si vous utilisez `scans[].nfs` (création d'un PersistentVolume).

## Installation

```bash
oc new-project diskover
helm install diskover ./diskover -f mes-valeurs.yaml

oc get builds -w                 # attendre la fin des 2 builds
oc get elasticsearch             # attendre HEALTH=green
oc get route diskover-web -o jsonpath='{.spec.host}{"\n"}'
```

Premier démarrage : les pods `diskover-web` peuvent rester quelques minutes en `ImagePullBackOff` tant que les images ne sont pas construites ; ils démarrent seuls ensuite.

Connexion initiale : **`diskover` / `darkdata`**. À changer immédiatement (⚙ → Settings).
Puis ⚙ → **Indices** → sélectionner l'index `diskover-<nom>-<date>` → *Save Selection*.

### Exemple de valeurs

```yaml
elasticsearch:
  version: 8.19.0
  resources:
    requests: { cpu: "2", memory: 8Gi }
    limits:   { memory: 8Gi }
  storage:
    size: 200Gi
    storageClassName: ocs-storagecluster-ceph-rbd

web:
  route:
    host: diskover.apps.mon-cluster.example.com

scanner:
  supplementalGroups: [5000]       # GID ayant accès à vos partages
  extraArgs: "--threads 8"
  resources:
    requests: { cpu: "2", memory: 2Gi }
    limits:   { memory: 4Gi }

scans:
  - name: projets
    schedule: "0 2 * * *"
    nfs:
      server: nas.example.com
      path: /export/projets
      mountOptions: [nfsvers=4.1, ro, noatime]
  - name: archives
    schedule: "0 3 * * 0"
    volume:
      persistentVolumeClaim:
        claimName: pvc-archives     # PV créé par votre admin
```

## Paramètres

### Images et build

| Paramètre | Défaut | Description |
|---|---|---|
| `images.pythonBase` | `registry.access.redhat.com/ubi9/python-312:latest` | Base du scanner |
| `images.nginxBase` | `registry.access.redhat.com/ubi9/nginx-126:latest` | Base de diskover-web |
| `build.enabled` | `true` | Crée BuildConfig + ImageStream (sinon fournissez vos images) |
| `build.git.uri` | dépôt officiel Diskover | Source des builds |
| `build.git.ref` | `v2.3.5` | Tag ou branche |

### Elasticsearch

| Paramètre | Défaut | Description |
|---|---|---|
| `elasticsearch.create` | `true` | `false` = utiliser un cluster existant |
| `elasticsearch.name` | `diskover` | Nom du CR → service `<name>-es-http`, secret `<name>-es-elastic-user` |
| `elasticsearch.version` | `8.19.0` | Diskover CE requiert ES 8.x |
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
| `scanner.supplementalGroups` | `[]` | GID additionnels pour lire les données |
| `scanner.extraArgs` | `""` | Arguments de `diskover.py` (ex. `--threads 8`) |
| `scans[]` | `[]` | Un CronJob par entrée (voir ci-dessous) |

### Entrées `scans[]`

| Clé | Description |
|---|---|
| `name` | Nom court en minuscules ; sert aux noms de ressources et à l'index `diskover-<name>-AAAAMMJJ` |
| `schedule` | Expression cron |
| `nfs.server`, `nfs.path` | Le chart crée un PV + PVC NFS en `ReadOnlyMany` (`Retain`) |
| `nfs.size` | Capacité indicative (défaut `1Ti`) |
| `nfs.mountOptions` | Défaut : `nfsvers=4.1, ro, noatime` |
| `volume` | Alternative à `nfs` : source de volume Kubernetes, ex. un PVC existant |

Les données sont toujours montées en lecture seule sur `/data` dans le pod du scanner.

## Exploitation

```bash
# Lancer un scan immédiatement
oc create job --from=cronjob/diskover-scan-projets scan-manuel
oc logs -f job/scan-manuel

# Après un nouveau build de l'image web
oc rollout restart deploy/diskover-web

# Reconstruire les images (ex. changement de build.git.ref)
oc start-build diskover-web
oc start-build diskover-scanner

# Mot de passe de l'utilisateur Elasticsearch
oc get secret diskover-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d
```

## Détails techniques à connaître

- **Configuration par variables d'environnement** : web et scanner lisent `ES_HOST`, `ES_PORT`, `ES_USER`, `ES_PASS`, `ES_HTTPS`, `ES_SSLVERIFICATION` et `DATABASE`. Le mot de passe provient du secret ECK.
- **`clear_env = no`** est positionné dans la configuration php-fpm : sans cela, php-fpm supprime ces variables et l'application ne trouve plus Elasticsearch.
- **Base SQLite** : stockée sur le PVC de diskover-web (`/data/diskoverdb.sqlite3`). Un seul écrivain → 1 réplique, stratégie `Recreate`.
- **Scanner et réglages de l'interface** : chaque job utilise sa propre base SQLite éphémère ; les réglages faits dans l'UI ne s'appliquent pas aux scans. Utilisez `scanner.extraArgs`.
- **ES sans `vm.max_map_count`** : `node.store.allow_mmap: false` évite tout sysctl privilégié.
- **Rétention** : les index s'accumulent (un par scan et par jour). Prévoyez une purge (ILM, curator ou job dédié).

## Dépannage

| Symptôme | Piste |
|---|---|
| Pods web en `ImagePullBackOff` | Builds non terminés : `oc get builds`, `oc logs build/diskover-web-1` |
| Build web en échec sur `dnf install` | Accès au CDN UBI ou paquet PHP indisponible ; ajuster la liste dans `templates/buildconfigs.yaml` |
| `Failed to connect to Elasticsearch` | ECK ne surveille pas le namespace, cluster pas encore `green`, ou `ES_HTTPS` incohérent avec `elasticsearch.tls` |
| Erreur 500 / `is not writable` sur diskover-web | PVC non monté ou droits du volume : `oc logs deploy/diskover-web -c php-fpm` |
| Scan très court / index quasi vide | Droits NFS insuffisants : vérifier `scanner.supplementalGroups` et les permissions côté NAS |
| PV NFS refusé à l'installation | Droits cluster-admin requis, ou créer le PV à part et utiliser `volume.persistentVolumeClaim` |

## Désinstallation

```bash
helm uninstall diskover
# Conservés volontairement (Retain / PVC de données) : à supprimer manuellement si besoin
oc delete pvc -l app.kubernetes.io/instance=diskover
oc delete pv -l app.kubernetes.io/instance=diskover
```

## Licence

Ce chart est fourni sans garantie. Diskover Community Edition est distribué sous licence Apache 2.0 ; voir le dépôt officiel.
