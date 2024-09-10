# vpn-server-preparation-4-amnezia

firstbyte preparation(ipv6 deactivation included)
```
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1 && sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1 && sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1 && sudo wget https://raw.githubusercontent.com/rinxster/vpn-server-preparation-4-amnezia/main/vpn-server-preparation-4-amnezia.sh -O vpn-server-preparation-4-amnezia.sh && sudo chmod +x vpn-server-preparation-4-amnezia.sh && sudo bash vpn-server-preparation-4-amnezia.sh


```
non-firstbyte(ipv6 deactivation excluded)

```
sudo wget https://raw.githubusercontent.com/rinxster/vpn-server-preparation-4-amnezia/main/vpn-server-preparation-4-amnezia.sh -O vpn-server-preparation-4-amnezia.sh && sudo chmod +x vpn-server-preparation-4-amnezia.sh && sudo bash vpn-server-preparation-4-amnezia.sh

```
