# Chart Helm Diskover Community Edition

Chart Helm pour déployer Diskover Community Edition et son interface web sur OpenShift / Kubernetes.

Consultez la documentation complète et le guide de déploiement hors-ligne (Air-gap / Offline) dans [../README.md](../README.md).

### Installation rapide en mode connecté :
```bash
helm install diskover ./ -f values.yaml
```

### Installation en environnement déconnecté (Offline) :
```bash
helm install diskover ./ -f values-offline.example.yaml
```
