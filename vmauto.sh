#!/bin/bash

#############################################################################################
#      vmauto.sh : Script permettant de déployer rapidement une machine virtuelle sous xen  #
#      Auteur    : Cedric TINTANET							    #
#      Usage     : vmauto.sh <nom_machine> <lun>					    #
#      Release   : 1.1 (03/02/2012)							    #
#############################################################################################

modif_networkinterfaces() {
cat << EOF > $MOUNT/$nom_machine/etc/network/interfaces
# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
allow-hotplug eth0
iface eth0 inet static
	address $IPADDR
	netmask $NETMASK
	network $NETWORK
	broadcast 172.16.255.255
	gateway $GATEWAY
	# dns-* options are implemented by the resolvconf package, if installed
	dns-nameservers $DNS
	dns-search $SEARCHDOMAIN
EOF
	
}

modif_fstab() {
        if [ $DEFMAKEVG -eq 1 ]; then
		BLKID=$(/sbin/blkid -o value /dev/mapper/vg$rewrited_name-lvsystem1 | head -1)
		FSTYPE=$(/sbin/blkid -o value /dev/mapper/vg$rewrited_name-lvsystem1 | tail -1)
	else
		BLKID=$(/sbin/blkid -o value ${periph}1 | head -1)
		FSTYPE=$(/sbin/blkid -o value ${periph}1 | tail -1)
	fi

	sed -i 's/^UUID=.*$/UUID='$BLKID'\t\/boot\t'$FSTYPE'\tdefaults\t0\t0/' $MOUNT/$nom_machine/etc/fstab
	sed -i 's/patron'$ARCH'/'$rewrited_name'/g' $MOUNT/$nom_machine/etc/fstab
}

modif_hostname() {
    sed -i 's/patron'$ARCH'/'$nom_machine'/g' $MOUNT/$nom_machine/etc/hostname
}

modif_hosts() {
    newline="$IPADDR	$nom_machine.$DOMAIN	$nom_machine"
    sed -i 's/^.*patron'$ARCH'.*$/'"$newline"'/' $MOUNT/$nom_machine/etc/hosts
}

modif_cronapt() {
    sed -i 's/patron'$ARCH'/'$nom_machine'/g' $MOUNT/$nom_machine/etc/cron-apt/config
}

modif_bootgrub() {
    sed -i 's/patron'$ARCH'/'$rewrited_name'/g' $MOUNT/$nom_machine/boot/grub/grub.cfg
#    if [ "$DEFHYPER" != "xen" ]; then
#        sed -i 's/^default[[:space:]]*0$/default 2/' MOUNT/$nom_machine/boot/grub/menu.lst
#    fi
}

modif_nslcd() {
    sed -i 's/patron'$ARCH'/'$nom_machine'/g' $MOUNT/$nom_machine/etc/nslcd.conf
}

modif_sudoers() {
    chmod 640 $MOUNT/$nom_machine/etc/sudoers
    sed -i 's/patron'$ARCH'/'$nom_machine'/g' $MOUNT/$nom_machine/etc/sudoers
    chmod 440 $MOUNT/$nom_machine/etc/sudoers
}

modif_aliases() {
    sed -i 's/patron'$ARCH'/'$nom_machine'/g' $MOUNT/$nom_machine/etc/aliases
}

modif_mail() {
	sed -i 's/patron'$ARCH'/'$nom_machine'/g' $MOUNT/$nom_machine/etc/mailname
	sed -i 's/patron'$ARCH'/'$nom_machine'/g' $MOUNT/$nom_machine/etc/exim4/update-exim4.conf.conf
}
	
get_config_sshd_option() {
        option="$1"

        [ -f $MOUNT/$nom_machine/etc/ssh/sshd_config ] || return

        # TODO: actually only one '=' allowed after option
        perl -lne 's/\s+/ /g; print if s/^\s*'"$option"'[[:space:]=]+//i' \
           $MOUNT/$nom_machine/etc/ssh/sshd_config
}


host_keys_required() {
        hostkeys="$(get_config_sshd_option HostKey)"
        if [ "$hostkeys" ]; then
                echo "$hostkeys" | awk '{ printf("%s/%s%s\n",mounted,namemachine,$0); }' mounted=$MOUNT namemachine=$nom_machine
        else
                # No HostKey directives at all, so the server picks some
                # defaults depending on the setting of Protocol.
                protocol="$(get_config_sshd_option Protocol)"
                [ "$protocol" ] || protocol=1,2
                if echo "$protocol" | grep 1 >/dev/null; then
                        echo $MOUNT/$nom_machine/etc/ssh/ssh_host_key
                fi
                if echo "$protocol" | grep 2 >/dev/null; then
                        echo $MOUNT/$nom_machine/etc/ssh/ssh_host_rsa_key
                        echo $MOUNT/$nom_machine/etc/ssh/ssh_host_dsa_key
                fi
        fi

}

create_ssh_key() {
        msg="$1"
        shift
        hostkeys="$1"
        shift
        file="$1"
        shift
        if echo "$hostkeys" | grep -x "$file" >/dev/null && \
           [ ! -f "$file" ] ; then
                echo -n $msg
                ssh-keygen -q -f "$file" -N '' "$@"
                echo
                #if which restorecon >/dev/null 2>&1; then
                #        restorecon "$file.pub"
                #fi
        fi
}

modif_sshhost() {
        echo "suppression des clefs ssh du patron"
        rm -f $MOUNT/$nom_machine/etc/ssh/ssh_host*

        hostkeys="$(host_keys_required)"

        create_ssh_key "Creating SSH1 key; this may take some time ..." \
                "$hostkeys" $MOUNT/$nom_machine/etc/ssh/ssh_host_key -t rsa1

        create_ssh_key "Creating SSH2 RSA key; this may take some time ..." \
                "$hostkeys" $MOUNT/$nom_machine/etc/ssh/ssh_host_rsa_key -t rsa
        create_ssh_key "Creating SSH2 DSA key; this may take some time ..." \
                "$hostkeys" $MOUNT/$nom_machine/etc/ssh/ssh_host_dsa_key -t dsa
}

close_vgfs() {

    #/bin/umount /$MOUNT/$nom_machine/{boot,var,tmp,usr,home}
    for i in boot ${LVNAME[*]} ; do
	[ "$i" != "root" -a "$i" != "swap" ] && /bin/umount /$MOUNT/$nom_machine/$i
    done
    /bin/umount /$MOUNT/$nom_machine/
    $PREFIX/vgchange -a n $nom_machine
    if [ $DEFMAKEVG -eq 1 ]; then
	$PREFIX/kpartx -d /dev/mapper/vg$rewrited_name-lvsystem
    else
	$PREFIX/kpartx -d $periph
    fi
}

#defmakevg:
#$1 : Nom de la machine spécifié en argument du script
#$2 : Nom du périphérique spécifié en argument du script
defmakevg() {
    stopboucle=1
    #echo "fonction defmakevg variable \$2 : $2"
    #read
    chaine="Doit on créer un VG nommé vg$1 sur $2 ?"
    if [ $DEFMAKEVG -eq 1 ] ; then
        chaine=$chaine" (O/n)"
    else chaine=$chaine" (o/N)"
    fi
    echo -n $chaine
    while [ $stopboucle -eq 1 ] ; do
        read nDEFMAKEVG
        case $nDEFMAKEVG in 
            O|Y|o|y) DEFMAKEVG=1
                     stopboucle=0
                     ;;
            N|n)    DEFMAKEVG=0
                    stopboucle=0
                    ;;
            *) echo -n "Erreur de saisie: Vous avez le choix entre (O/o Y/y N/n): "
        esac
    done
}

defipaddr() {
    matchipaddr=1
    while [ $matchipaddr -ne 0 ] ; do  
        read -p "Adresse IP du serveur? ($1) " IPADDR
        IPADDR=${IPADDR:-$1}
        echo $IPADDR | egrep $regexpipaddr > /dev/null
        matchipaddr=$?
        [ $matchipaddr -ne 0 ] && echo "Mauvais format"
    done
    echo $IPADDR
}

defnetmask() {
    matchnetmask=1
    while [ $matchnetmask -ne 0 ] ; do  
        read -p "Masque de sous reseau ($1)? " NNETMASK
        NETMASK=${NNETMASK:-$1}
        echo $NETMASK | egrep $regexpipaddr > /dev/null
        matchnetmask=$?
        [ $matchnetmask -ne 0 ] && echo "Mauvais format"
    done
    echo $NETMASK
}


#defnetwork : calcul l'adresse du reseau en fonction de l'ip de la machine et du netmask
#Appel : defnetwork ipaddr netmask
defnetwork() {
    #Calcul du network en fonction de l'adresse ip et du netmask
    j=0
    for i in $(echo $1 | sed 's/\./ /g') ; do
        TABADRIP[$j]=$i
        j=$((j+1))
    done
    
    j=0
    for i in $(echo $2 | sed 's/\./ /g') ; do
        TABMASK[$j]=$i
        j=$((j+1))
    done
    
    #ET logique entre adresse IP et masque de sous reseau
    NETWORK=$((${TABADRIP[$i]}&${TABMASK[$i]}))
    j=1
    for i in $(seq 1 ${#TABADRIP}) ; do
        CALCUL=$((${TABADRIP[$i]}&${TABMASK[$i]}))
        NETWORK="$NETWORK.$CALCUL"
        j=$((j+1))
    done
    echo $NETWORK
}

defgateway() {
    matchgateway=1
    while [ $matchgateway -ne 0 ] ; do 
        read -p "Passerelle par défaut? ($1)" NGATEWAY
        GATEWAY=${NGATEWAY:-$1}
        echo $GATEWAY | egrep $regexpipaddr > /dev/null
        matchgateway=$?
        [ $matchgateway -ne 0 ] && echo "Mauvais format"
    done
    echo $GATEWAY
}

#defnameserver : Définir le nom FQDN du serveur
#Appel : defnameserver $DEFDNSSRV (ou DEFDNSSRV = "vigix.intra.inist.fr" par exemple)
defnameserver() {
    DEFNAMESRV=$(echo $1 | sed 's/\([^.]*\)\..*/\1/')
    read -p "Nom du serveur? ($DEFNAMESRV)" NAMESRV
    NAMESRV=${NAMESRV:-$DEFNAMESRV}
    echo $NAMESRV
}

defnamedomain() {
    read -p "Domaine? ($1) " NDOMAIN
    DOMAIN=${NDOMAIN:-$1}
    echo $DOMAIN
}

defipdns() {
    stopboucle=1
    while [ $stopboucle -eq 1 ] ; do 
            stopboucle=0
            read -p "Serveur(s) de nom (un espace entre chaque adresse IP) ($*) ? " RDNS
            for i in $RDNS ; do 
                    echo $i | egrep $regexpipaddr  > /dev/null
                    if [ $? -ne 0 ] ; then 
                            echo "Mauvais format adresse IP ($i)"
                            stopboucle=1
                            break;
                    fi
                    NDNS="$NDNS $i"		
            done
    done
    NDNS=$(echo $NDNS | sed 's/^ //')
    DNS=${NDNS:-$*}
    echo $DNS
}

defsearchdomain() {
    read -p "Domaines de recherche pour resolv.conf ($*) ? " NSEARCHDOMAIN
    SEARCHDOMAIN=${NSEARCHDOMAIN:-$*}
    echo $SEARCHDOMAIN
}



defarchitecture() {
    ARCH=""
    while [ "$ARCH" != "32" -a "$ARCH" != "64" ] ; do
        read -p "Type d'architecture (32 ou 64 bits) :" ARCH
        [ "$ARCH" != "32" -a $ARCH != "64" ] && echo "Vous devez choisir 32 ou 64 bits!!"
    done
    echo $ARCH
}

defhyperviseur() {
    stopboucle=1
    read -p "Type d'hyperviseur (X)en ou (O)thers ($1) :" NHYPER 
    while [ $stopboucle -eq 1 ] ; do
        case $NHYPER in
            O|o) stopboucle=0
                 HYPER="others"
                 ;;

            X|x) stopboucle=0
                 HYPER="xen"
                  ;;
            *)  read -p "Erreur de saisie: Vous avez le choix entre (X)en ou (O)thers: " NHYPER
                
        esac
    done
    echo $HYPER
}

source ./options-xen.sh

if [ $# -lt 2 ] ; then 
echo "Usage $0 <nom_machine> <lun>";
exit 1
fi

nom_machine=${nom_machine:-$1}
lun=${lun:-$2}

#Teste si le périphérique passé en argument existe
if [ ! -b "$lun" ] ; then
    echo "ERREUR: Le périphérique spécifié $lun n'existe pas sur ce système"
    exit 1
fi


#echo "variable \$lun : $lun"
#read

DEFIPADDR=$(/usr/bin/getent hosts $nom_machine | awk ' { print $1 }')
DEFDNSSRV=$(/usr/bin/getent hosts $nom_machine | awk ' { print $2 }')

specif="nok"
while [ "$specif" == "nok" ] ; do 
    HYPER=$(defhyperviseur $DEFHYPER)
    echo $HYPER
    defmakevg $nom_machine $lun
    IPADDR=$(defipaddr $DEFIPADDR)
    echo $IPADDR
    NETMASK=$(defnetmask $NETMASK)
    echo $NETMASK
    NETWORK=$(defnetwork $IPADDR $NETMASK)
    echo $NETWORK
    GATEWAY=$(defgateway $GATEWAY)
    echo $GATEWAY
    NAMESRV=$(defnameserver $DEFDNSSRV)
    echo $NAMESRV
    DOMAIN=$(defnamedomain $DOMAIN)
    echo $DOMAIN
    echo "variable DNS avant traitement: $DNS"
    DNS=$(defipdns $DNS)
    echo $DNS
    SEARCHDOMAIN=$(defsearchdomain $SEARCHDOMAIN)
    echo $SEARCHDOMAIN
    ARCH=$(defarchitecture)
    echo $ARCH
    
    affmenu="1"
    while [ "$affmenu" == "1" ] ; do
        clear
        tput cup 3 8
        echo "Type d'hyperviseur : "
        tput cup 3 60
        echo $HYPER
        tput cup 4 8
        echo "Créer VG vg$1 sur périphérique $2:"
        tput cup 4 60
        if [ $DEFMAKEVG -eq 1 ] ; then echo "oui"
        else echo "non"
        fi
        tput cup 5 8
        echo  "Nom de la machine (hostname):"
        tput cup 5 40
        echo $NAMESRV
        tput cup 6 8 
        echo  "Domaine:"
        tput cup 6 40 
        echo $DOMAIN
        tput cup 7 8 
        echo  "Adresse IP de la machine:"
        tput cup 7 40 
        echo $IPADDR
        tput cup 8 8 
        echo "Masque de sous reseau:"
        tput cup 8 40
        echo $NETMASK
        tput cup 9 8 
        echo "Reseau:"
        tput cup 9 40 
        echo $NETWORK
        tput cup 10 8 
        echo "Passerelle par defaut:"
        tput cup 10 40
        echo $GATEWAY
        tput cup 11 8
        echo "Serveurs de noms:"
        tput cup 11 40
        echo $DNS
        tput cup 12 8 
        echo "Domaines de recherche:"
        tput cup 12 40 
        echo $SEARCHDOMAIN
        tput cup 13 8 
        echo "Type d'architecture:"
        tput cup 13 40 
        echo "$ARCH bits"
        
        tput cup 15 40
        read -p "(C)ontinuer, (A)bandonner, (M)odifier ?" reponse
        case "$reponse" in 
                C|c) specif="ok"
		     affmenu="0"
                     ;;
                A|a) exit 0
                     ;;
                M|m) specif="nok"
		     affmenu="0"
                     ;;
                *) affmenu="1"
        esac
    done
done

if [ $DEFMAKEVG -eq 1 ] ; then
    $PREFIX/pvcreate $lun
    $PREFIX/vgcreate vg$nom_machine $lun
    $PREFIX/vgchange --addtag tag_phy vg$nom_machine
    TOTALPE=$($PREFIX/vgdisplay vg$nom_machine | grep "Total PE" | awk '{ print $3 }')
    #echo $TOTALPE
    LVPE=$((TOTALPE*3/4))
    #echo $lVPE
    $PREFIX/lvcreate -n lvsystem -l $LVPE vg$nom_machine
    periph="/dev/vg$nom_machine/lvsystem"
else
    periph=$lun
fi
$PREFIX/fdisk $periph << EOF
n
p
1

+300M
n
p
2


t
2
8e
w
EOF

#la variable rewrited name tient compte des conventions d'écriture de linux 
#pour les VG dont le nom contient un tiret

rewrited_name=$(echo $nom_machine | sed 's/\(-\)/\1\1/g')
if [ $DEFMAKEVG -eq 1 ]; then
    $PREFIX/kpartx -a /dev/mapper/vg$rewrited_name-lvsystem
    if [ $? -ne 0 ] ; then echo "Problem kpartx"; exit 1; fi
    if [ -b "/dev/mapper/vg$rewrited_name-lvsystem"2 ] ; then 
        $PREFIX/pvcreate "/dev/mapper/vg$rewrited_name-lvsystem"2
        $PREFIX/vgcreate $nom_machine "/dev/mapper/vg$rewrited_name-lvsystem"2
    else
        echo "ERREUR : Impossible de trouver le périphérique /dev/mapper/vg$rewrited_name-lvsystem2"
        exit 1
    fi
    
#ici on est dans le ca ou on ne crée pas de vg ni de lvsystem sur periph spécifié
else
    $PREFIX/kpartx -a $periph
    if [ $? -ne 0 ] ; then echo "Problem kpartx"; exit 1; fi
    echo $periph | grep -q "^.*[0-9]$"
    #rajout d'un "p" à la fin du contenu de $periph si ce contenu se termine par un chiffre
    #convention d'écriture linux
    if [ $? -eq 0 ] ; then
        periph=$periph"p"
    fi
    if [ -b "$periph""2" ] ; then
        $PREFIX/pvcreate $periph"2"
        $PREFIX/vgcreate $nom_machine $periph"2"
    else
        echo "ERREUR: Impossible de trouver le périphérique $partition_lvm"
        exit 1
    fi
fi

#Creation des volumes logiques
for i in $(seq 0 $((${#LVNAME[*]}-1))) ; do
   $PREFIX/lvcreate -n ${LVNAME[$i]} -L ${LVSIZE[$i]} $nom_machine
done
$PREFIX/vgchange -a y $nom_machine

if [ $DEFMAKEVG -eq 1 ]; then
    if [ -b "/dev/mapper/vg$rewrited_name-lvsystem1" ] ; then 
        $PREFIX/mkfs.ext2 /dev/mapper/vg$rewrited_name-lvsystem1
    else
        echo "Unable to build Filesystem /boot"
        exit 1
    fi
else
    if [ -b "$periph""1" ] ; then 
        $PREFIX/mkfs.ext2 $periph"1"
    else
        echo "Unable to build Filesystem /boot"
        exit 1
    fi
fi

#formatage des volumes logiques
for i in $(seq 0 $((${#LVNAME[*]}-1))) ; do
    if [ -b "/dev/mapper/$rewrited_name-${LVNAME[$i]}" ] ; then
        if [ ${LVNAME[$i]} != "swap" ] ; then
            echo "Formatage de /dev/mapper/$rewrited_name-${LVNAME[$i]}"
            $PREFIX/mkfs.ext3 /dev/mapper/$rewrited_name-${LVNAME[$i]}
        else
            echo "Creation de la swap"
            $PREFIX/mkswap /dev/mapper/$rewrited_name-${LVNAME[$i]}
        fi
    else
        echo "Unable to build Filesystem /${LVNAME[$i]}"
        exit 1
    fi
done
 
#Creation et montage des repertoires des volumes logiques precedemment crees
j=0
for i in ${LVNAME[*]} ; do
    if [ ${LVMOUNT[$j]} != "none" ] ; then
        [ ! -d "$MOUNT/$nom_machine/${LVMOUNT[$j]:1}" ] && mkdir $MOUNT/$nom_machine/${LVMOUNT[$j]:1}
        mount /dev/mapper/$rewrited_name-$i $MOUNT/$nom_machine/${LVMOUNT[$j]:1}
    fi
    j=$((j+1))
done

for i in boot proc sys ; do
    mkdir $MOUNT/$nom_machine/$i
done

if [ $DEFMAKEVG -eq 1 ]; then  
    mount /dev/mapper/vg$rewrited_name-lvsystem1 $MOUNT/$nom_machine/boot
else
    mount $periph"1" $MOUNT/$nom_machine/boot
fi


VAR=MACHINE$ARCH
MACHINE=${!VAR}
/usr/bin/wget --no-proxy ftp://$FTPUSER:$FTPPASSWD@$MACHINE/patron$ARCH.tar.gz -O /tmp/patron$ARCH.tar.gz
if [ $? -eq 0 -a -f /tmp/patron$ARCH.tar.gz ] ; then 
    tar xvfz /tmp/patron$ARCH.tar.gz -C /$MOUNT/$nom_machine
    modif_networkinterfaces
    modif_fstab
    modif_hostname
#    modif_hosts
    modif_cronapt
    modif_bootgrub
    modif_nslcd
    modif_aliases
    modif_sudoers
    modif_mail
    modif_sshhost
    rm /tmp/patron$ARCH.tar.gz
fi
close_vgfs
