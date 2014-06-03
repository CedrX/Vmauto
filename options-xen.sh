#!/bin/bash

PREFIX="/sbin"
MOUNT=/mnt/

#DEFMAKEVG: variable qui spécifie si :
# - on doit créer un VG vgnommachine sur le périphérique spécifié en argument et ensuite créer un lvsystem dans ce vg
# - ou si on doit directement partitionner la périphérique spécifié en argument pour recevoir le systeme
# valeur = 1 ==> On crée le VG vgnommachine
# valeur = 0 ==> On partitionne directement le périphérique et on installe le système dessus
DEFMAKEVG=1
DEFHYPER="xen"
GATEWAY="192.168.0.1"
DNS="192.168.0.1"
NETMASK="255.255.255.0"
DOMAIN="domain.fr"
SEARCHDOMAIN="domain1.fr domain2.fr"
regexpipaddr='\b(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b'
#MACHINE32=vigix.intra.inist.fr
MACHINE32=server1.domain.fr
MACHINE64=server2.domain.fr
FTPUSER=user
FTPPASSWD=password


LVNAME=("root" "var" "usr" "tmp" "home" "swap")
LVMOUNT=("/" "/var" "/usr" "/tmp" "/home" "none")
LVSIZE=("1G" "2,8G" "4,6G" "512M" "1G" "2G")
#LVNAME=("root" "swap" "home")
#LVMOUNT=("/" "none" "/home")
#LVSIZE=("3G" "2G" "3G")
