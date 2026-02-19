#!/bin/bash

# Farben für die Ausgabe
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Funktion für Statusmeldungen
log_status() {
    echo -e "${GREEN}### STATUS: ${1} ###${NC}"
}

# Funktion für Warnungen
log_warning() {
    echo -e "${YELLOW}### WARNUNG: ${1} ###${NC}"
}

# 1. System aktualisieren und notwendige Pakete installieren
log_status "Aktualisiere System und installiere notwendige Pakete..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y python3 python3-pip git dialog

# 2. mitmproxy installieren
log_status "Installiere mitmproxy via pip..."
pip3 install mitmproxy

# 3. mitmproxy Zertifikate generieren (wird automatisch beim ersten Start von mitmproxy/mitmweb gemacht, aber zur Sicherheit hier erwähnt)
# Normalerweise nicht notwendig, da mitmweb dies automatisch erledigt, aber falls man es erzwingen will:
# mitmproxy --version # Lässt mitmproxy seine Konfigurationsdateien und Zertifikate anlegen

# 4. mitmweb Systemd Service erstellen (falls Sie dies für den automatischen Start nutzen möchten)
log_status "Erstelle mitmweb Systemd Service..."
SERVICE_FILE="/etc/systemd/system/mitmweb.service"
echo "[Unit]" | sudo tee $SERVICE_FILE
echo "Description=Mitmweb Proxy" | sudo tee -a $SERVICE_FILE
echo "After=network.target" | sudo tee -a $SERVICE_FILE
echo "" | sudo tee -a $SERVICE_FILE
echo "[Service]" | sudo tee -a $SERVICE_FILE
echo "ExecStart=/usr/local/bin/mitmweb --web-host 0.0.0.0 --web-port 8081" | sudo tee -a $SERVICE_FILE
echo "Restart=always" | sudo tee -a $SERVICE_FILE
echo "User=pi" # Ersetzen Sie 'pi' durch den gewünschten Benutzer, unter dem mitmweb laufen soll
echo "Group=pi" # Ersetzen Sie 'pi' durch die gewünschte Gruppe
echo "" | sudo tee -a $SERVICE_FILE
echo "[Install]" | sudo tee -a $SERVICE_FILE
echo "WantedBy=multi-user.target" | sudo tee -a $SERVICE_FILE

sudo systemctl daemon-reload
sudo systemctl enable mitmweb

log_status "mitmweb Service erstellt und für den automatischen Start aktiviert."

# 5. Informationen zum mitmweb Token bereitstellen
log_warning "WICHTIG: mitmweb benötigt ein Token für den Zugriff auf das Webinterface."
echo "Wenn mitmweb gestartet wird, wird ein einmaliges Token in der Konsole angezeigt."
echo "Um das Token zu sehen, können Sie den Service starten und die Logs überprüfen:"
echo -e "${YELLOW}sudo systemctl start mitmweb${NC}"
echo -e "${YELLOW}sudo journalctl -u mitmweb -f${NC} (Drücken Sie Strg+C zum Beenden)"
echo ""
echo "Das Token sieht in etwa so aus: 'Web interface listening at http://0.0.0.0:8081 with authentification token: <YOUR_TOKEN_HERE>'"
echo "Sie müssen dieses Token in Ihrem Browser eingeben, wenn Sie sich mit dem mitmweb-Interface verbinden."
echo ""
log_status "Installation abgeschlossen. Bitte überprüfen Sie die Logs für das mitmweb Token."

# Optional: Firewall-Regeln (falls erforderlich)
# log_status "Öffne Port 8081 in der Firewall (UFW)..."
# sudo ufw allow 8081/tcp
# sudo ufw enable # Nur, wenn UFW noch nicht aktiv ist und Sie es aktivieren möchten
# sudo ufw status

# Hinweis zur manuellen Interception (falls relevant für das Originalskript)
# log_status "Um den mitmproxy als transparenten Proxy einzurichten, sind weitere Schritte erforderlich (z.B. iptables Regeln)."
# log_status "Weitere Informationen finden Sie in der mitmproxy Dokumentation."
