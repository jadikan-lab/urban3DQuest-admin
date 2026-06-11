# Sauvegarde documentee - urban3DQuest-admin

- Date: 2026-06-12 00:04:07 (local)
- Repository: https://github.com/jadikan-lab/urban3DQuest-admin.git
- Branche active: main
- Commit HEAD: ff5c20ca95781a701d8856530c13741cf9682b37
- Politique env: PROD par defaut (STG en pause)

## Fichier de sauvegarde

- Bundle: backups/urban3DQuest-admin-documented-20260612-000407.bundle
- SHA-256: 85df8146cbb195932f06361090c5942eb640390ecd17b86b0f9c0fb475bbb244
- Verification: `git bundle verify backups/urban3DQuest-admin-documented-20260612-000407.bundle` -> OK

## Contexte fonctionnel inclus

Derniers commits inclus:

1. ff5c20c - Fix fixed ZIP exports with unique filenames
2. a1f94ee - Split create flow into Flash and Fixed tabs
3. 46b1865 - [claude] switch fixed QR flow to landing and remove GPS requirement
4. ad07aef - [claude] support persisted solo reflash count from found_by

## Procedure de restauration

### Option A - Cloner depuis le bundle

```bash
git clone backups/urban3DQuest-admin-documented-20260612-000407.bundle urban3DQuest-admin-restore
cd urban3DQuest-admin-restore
git checkout main
```

### Option B - Injecter dans un repo existant

```bash
git fetch backups/urban3DQuest-admin-documented-20260612-000407.bundle main:restored/main
git checkout restored/main
```

## Controle d'integrite recommande

```bash
shasum -a 256 backups/urban3DQuest-admin-documented-20260612-000407.bundle
```

Comparer la valeur obtenue a:

`85df8146cbb195932f06361090c5942eb640390ecd17b86b0f9c0fb475bbb244`
