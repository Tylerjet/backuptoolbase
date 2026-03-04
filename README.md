# Backup Tool Base
Backup Tool Base is a simple tool that I got the idea from my assisting of klipper-backup but just base functionality of add credentials, choose files to backup and schedule that backup. It is a script for manual or automated GitHub backups for my personal use but could come in handy or be modified by others.

## Installation

### Download:
```shell
git clone https://github.com/Tylerjet/backuptoolbase
```

### Create Config:
```shell
cp ~/backuptoolbase/install.conf.example ~/backuptoolbase/install.conf
# Edit install.conf with your values
```

### Run Installer (non-interactive):
```shell
~/backuptoolbase/install.sh -config ~/backuptoolbase/install.conf
```

## Run Backup Manually
```shell
~/backuptoolbase/script.sh -config ~/backuptoolbase/install.conf
```

### Optional Commit Message
```shell
~/backuptoolbase/script.sh -config ~/backuptoolbase/install.conf -c "Manual backup"
```

## Debug Mode

### Installer Debug
```shell
~/backuptoolbase/install.sh -d -config ~/backuptoolbase/install.conf
```

### Backup Debug
```shell
~/backuptoolbase/script.sh -d -config ~/backuptoolbase/install.conf
```

### Debug Output Includes
- Invocation and active config path
- Masked config preview (tokens/secrets hidden)
- Resolved runtime values
- Dependency checks
- Service and cron state details
