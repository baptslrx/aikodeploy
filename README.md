# AikoDeploy

Mets ton site en ligne en un clic. AikoDeploy envoie sur ton hébergeur (FTP, FTPS ou SFTP : o2switch, OVH, Hostinger, Ionos…) **uniquement les fichiers modifiés**, et garde chaque mise en ligne pour pouvoir **revenir en arrière** si quelque chose casse.

- Jamais envoyés : `node_modules`, `.git`, `.env`, `.DS_Store`, journaux… (liste modifiable)
- Avant d'envoyer : la liste de ce qui va partir (nouveaux, modifiés, supprimés)
- Mot de passe rangé dans le trousseau du Mac ; SFTP par mot de passe ou clé SSH
- « Le site est déjà en ligne » : pour démarrer sans tout renvoyer
- Historique : « Revenir à cette version » remet le serveur dans l'état d'une mise en ligne précédente

## Installation (Mac)

Double-clic sur `macos/Installer AikoDeploy.command`.
