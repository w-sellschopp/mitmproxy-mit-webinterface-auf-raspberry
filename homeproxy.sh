#!/bin/bash

# Farben für die Ausgabe
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Access Point Einstellungen
AP_SSID="MITMProxy"
AP_PASSWORD="12345678" # HINWEIS: Dies ist ein unsicheres Passwort! Bitte in Produktion ändern!
AP_INTERFACE="wlan0" # Die WLAN-Schnittstelle des Raspberry Pi
ETH_INTERFACE="eth0" # Die Ethernet-Schnittstelle des Raspberry Pi
AP_IP="192.168.42.1"
AP_NETMASK="255.255.255.0"
AP_NETWORK="${AP_IP}/24"
DHCP_START="192.168.42.100"
DHCP_END="192.168.42.150"

# Funktion für Statusmeldungen
log_status() {
    echo -e "${GREEN}### STATUS: ${1} ###${NC}"
}

# Funktion für Warnungen
log_warning() {
    echo -e "${YELLOW}### WARNUNG: ${1} ###${NC}"
}

# Funktion für Fehler
log_error() {
    echo -e "${RED}### FEHLER: ${1} ###${NC}"
    exit 1
}

# 1. System aktualisieren und notwendige Pakete installieren
log_status "Aktualisiere System und installiere notwendige Pakete (hostapd, dnsmasq, python3-pip)..."
sudo apt update && sudo apt upgrade -y || log_error "System-Update fehlgeschlagen."
sudo apt install -y python3 python3-pip git dialog hostapd dnsmasq netfilter-persistent iptables-persistent || log_error "Paketinstallation fehlgeschlagen."

# 2. mitmproxy installieren
log_status "Installiere mitmproxy via pip..."
pip3 install mitmproxy || log_error "mitmproxy Installation fehlgeschlagen."

# 3. Netzwerkkonfiguration für den Access Point
log_status "Konfiguriere Netzwerkschnittstellen für den Access Point..."

# DHCPCD für WLAN-Schnittstelle deaktivieren, falls aktiv
sudo systemctl stop dhcpcd || log_warning "dhcpcd konnte nicht gestoppt werden (möglicherweise nicht aktiv)."
sudo systemctl disable dhcpcd || log_warning "dhcpcd konnte nicht deaktiviert werden (möglicherweise nicht aktiv)."

# Konfiguriere statische IP für die WLAN-Schnittstelle
echo "interface $AP_INTERFACE" | sudo tee /etc/dhcpcd.conf > /dev/null
echo "    static ip_address=$AP_NETWORK" | sudo tee -a /etc/dhcpcd.conf > /dev/null
echo "    nohook wpa_supplicant" | sudo tee -a /etc/dhcpcd.conf > /dev/null

# Alte Konfiguration von /etc/network/interfaces wiederherstellen (falls nötig)
# In neueren Raspbian-Versionen wird dhcpcd für WLAN verwendet, interfaces nur für Ethernet/Loopback.
# Dies sollte aber nicht stören, solange dhcpcd für wlan0 deaktiviert wird.

# IPv4-Forwarding aktivieren
log_status "Aktiviere IPv4-Forwarding..."
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-ip-forward.conf > /dev/null
sudo sysctl -p /etc/sysctl.d/99-ip-forward.conf || log_error "IPv4-Forwarding konnte nicht aktiviert werden."

# 4. hostapd konfigurieren (Access Point Software)
log_status "Konfiguriere hostapd..."
HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
sudo tee $HOSTAPD_CONF > /dev/null <<EOF
interface=$AP_INTERFACE
ssid=$AP_SSID
hw_mode=g
channel=7
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=$AP_PASSWORD
EOF
sudo chmod 600 $HOSTAPD_CONF

# hostapd default config anpassen (DAEMON_CONF)
sudo sed -i 's/^#DAEMON_CONF=""/DAEMON_CONF="\/etc\/hostapd\/hostapd.conf"/' /etc/default/hostapd
sudo systemctl unmask hostapd
sudo systemctl enable hostapd || log_error "hostapd konnte nicht aktiviert werden."

# 5. dnsmasq konfigurieren (DHCP und DNS für den Access Point)
log_status "Konfiguriere dnsmasq..."
DNSMASQ_CONF="/etc/dnsmasq.conf"
# Vorhandene dnsmasq.conf sichern
if [ -f "$DNSMASQ_CONF" ]; then
    sudo mv "$DNSMASQ_CONF" "$DNSMASQ_CONF.bak" || log_warning "Vorhandene dnsmasq.conf konnte nicht gesichert werden."
fi

sudo tee $DNSMASQ_CONF > /dev/null <<EOF
interface=$AP_INTERFACE
dhcp-range=$DHCP_START,$DHCP_END,255.255.255.0,24h
dhcp-option=option:router,$AP_IP
dhcp-option=option:dns-server,$AP_IP # Verwende den Pi selbst als DNS-Server (für mitmproxy DNS Interception)
# dhcp-option=option:dns-server,8.8.8.8,8.8.4.4 # Alternativ externe DNS-Server
listen-address=$AP_IP
EOF
sudo systemctl enable dnsmasq || log_error "dnsmasq konnte nicht aktiviert werden."

# 6. iptables Regeln für NAT und transparenten Proxy
log_status "Konfiguriere iptables Regeln für NAT und transparenten mitmproxy..."

# Alte Regeln löschen (optional, aber gut für saubere Konfiguration)
sudo iptables -F
sudo iptables -X
sudo iptables -t nat -F
sudo iptables -t nat -X

# NAT (Masquerading) für den Internetzugang
sudo iptables -t nat -A POSTROUTING -o $ETH_INTERFACE -j MASQUERADE

# Transparentes Proxying für HTTP (Port 80) und HTTPS (Port 443)
# Umleiten von HTTP-Traffic an mitmproxy
sudo iptables -t nat -A PREROUTING -i $AP_INTERFACE -p tcp --dport 80 -j REDIRECT --to-port 8080
# Umleiten von HTTPS-Traffic an mitmproxy
sudo iptables -t nat -A PREROUTING -i $AP_INTERFACE -p tcp --dport 443 -j REDIRECT --to-port 8080
# Umleiten von DNS-Traffic an mitmproxy (optional, für DNS Interception in mitmproxy)
sudo iptables -t nat -A PREROUTING -i $AP_INTERFACE -p udp --dport 53 -j REDIRECT --to-port 8080
sudo iptables -t nat -A PREROUTING -i $AP_INTERFACE -p tcp --dport 53 -j REDIRECT --to-port 8080

# ICMP und DNS vom mitmproxy selbst zulassen
sudo iptables -A INPUT -p icmp -j ACCEPT
sudo iptables -A INPUT -p udp --dport 53 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 53 -j ACCEPT

# Traffic zum mitmproxy selbst (Webinterface 8081, Proxy 8080) zulassen
sudo iptables -A INPUT -p tcp --dport 8080 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 8081 -j ACCEPT

# Weiteren Traffic durchlassen
sudo iptables -A FORWARD -i $AP_INTERFACE -o $ETH_INTERFACE -j ACCEPT
sudo iptables -A FORWARD -i $ETH_INTERFACE -o $AP_INTERFACE -m state --state RELATED,ESTABLISHED -j ACCEPT

# Speichere die iptables Regeln dauerhaft
log_status "Speichere iptables Regeln dauerhaft..."
sudo sh -c "iptables-save > /etc/iptables/rules.v4" || log_error "iptables-Regeln konnten nicht gespeichert werden."
sudo sh -c "ip6tables-save > /etc/iptables/rules.v6" || log_warning "ip6tables-Regeln konnten nicht gespeichert werden (möglicherweise kein IPv6 eingerichtet)."

# 7. mitmweb Systemd Service erstellen
log_status "Erstelle mitmweb Systemd Service..."
SERVICE_FILE="/etc/systemd/system/mitmweb.service"
sudo tee $SERVICE_FILE > /dev/null <<EOF
[Unit]
Description=Mitmweb Proxy
After=network.target

[Service]
ExecStart=/usr/local/bin/mitmweb --mode transparent --web-host 0.0.0.0 --web-port 8081 --listen-host $AP_IP --listen-port 8080
Restart=always
User=pi # Ersetzen Sie 'pi' durch den gewünschten Benutzer
Group=pi # Ersetzen Sie 'pi' durch die gewünschte Gruppe

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable mitmweb || log_error "mitmweb Service konnte nicht aktiviert werden."

# 8. Services starten und Status überprüfen
log_status "Starte hostapd, dnsmasq und mitmweb Services..."
sudo systemctl start hostapd || log_error "hostapd konnte nicht gestartet werden."
sudo systemctl start dnsmasq || log_error "dnsmasq konnte nicht gestartet werden."
sudo systemctl start mitmweb || log_error "mitmweb konnte nicht gestartet werden."

log_status "Alle Services erfolgreich gestartet!"

# 9. Informationen zum mitmweb Token bereitstellen
log_warning "WICHTIG: mitmweb benötigt ein Token für den Zugriff auf das Webinterface."
echo "Wenn mitmweb gestartet wird, wird ein einmaliges Token in der Konsole/Logs angezeigt."
echo "Um das Token zu sehen, können Sie die Logs überprüfen:"
echo -e "${YELLOW}sudo journalctl -u mitmweb -f${NC} (Drücken Sie Strg+C zum Beenden)"
echo ""
echo "Das Token sieht in etwa so aus: 'Web interface listening at http://0.0.0.0:8081 with authentification token: <YOUR_TOKEN_HERE>'"
echo "Sie müssen dieses Token in Ihrem Browser eingeben, wenn Sie sich mit dem mitmweb-Interface verbinden."
echo ""
echo -e "${GREEN}### INSTALLATION ABGESCHLOSSEN! ###${NC}"
echo -e "Der Access Point '${AP_SSID}' mit dem Passwort '${AP_PASSWORD}' sollte jetzt verfügbar sein."
echo -e "Verbinden Sie Ihre Geräte mit diesem Access Point."
echo -e "Öffnen Sie dann in Ihrem Browser http://${AP_IP}:8081 und geben Sie das Token ein, das Sie aus den Logs entnehmen können."
echo -e "Denken Sie daran, das mitmproxy CA-Zertifikat auf Ihren Geräten zu installieren, um HTTPS-Verbindungen ordnungsgemäß zu inspizieren."
echo -e "Das Zertifikat finden Sie unter http://mitm.it von einem durch den Proxy geleiteten Gerät aus."

# Neustart (optional, aber oft gut nach Netzwerkänderungen)
# log_status "System wird in 5 Sekunden neu gestartet, um alle Änderungen anzuwenden..."
# sleep 5
# sudo reboot
