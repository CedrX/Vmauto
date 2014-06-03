#!/bin/bash

#set -x
#Création d'une table de partitions sur le périphérique spécifié : $1
create_part_fdisk() {
periph=$1

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
}

#Renomme le périphérique, si celui ci se termine par un chiffre
periph_good_name() {
    periphbase=$1
    echo $periphbase | grep -q "^.*[0-9]$"
    #rajout d'un "p" à la fin du contenu de $periph si ce contenu se termine par un chiffre
    #convention d'écriture linux
    if [ $? -eq 0 ] ; then
        periphbase=$periphbase"p"
    fi
    echo $periphbase
}

create_tab_of_lv() {
    vgname=$1
    vgdisplay -v $vgname | \
    grep "LV Name" | \
    sed 's/^.*\///' | \
    awk 'BEGIN { root=false; indice=1 } \
        /root/   { root=true; tab[0]="root" } \
        /[^root]/ { tab[indice++]=$0 } \
        END { printf("("); \
              for(i=0;i<indice;i++) { \
                  if(i==0) printf("%s",tab[i]); \
                  else printf(" %s",tab[i]); \
               } \
              printf(")\n") \
            }'
}

create_score_tab() {
	printf "("
	for ((i=1;i<=$#;i++)) ; do 
                if [ "$i" -eq "$#" ] ; then
                        eval "echo \$$i" | sed 's/\// /g' | awk  '{ printf("%s",NF) }'
		else
			eval "echo \$$i" | sed 's/\// /g' | awk  '{ printf("%s ",NF) }'
		fi
	done
	printf ")"
}

create_ordered_lv_tab_of_mounts() {
    vgname=$1
    eval "Tab_Of_Lv="$(create_tab_of_lv $vgname)
    #echo ${Tab_Of_Lv[*]}
    j=0
    for i in ${Tab_Of_Lv[*]} ; do 
	rewrited_lv=$(rewrited_mapper_name $i)
        #echo $rewrited_lv
        grep -q "/dev/mapper/$vgname-$rewrited_lv " /proc/mounts
	if [ $? -eq 0 ] ; then 
                Tab_Of_Mounted_Directory[$j]=$(grep "/dev/mapper/$vgname-$rewrited_lv " /proc/mounts | awk ' { print $2 };')
		Tab_Of_Mounted_Lv[$j]=$i
		j=$((j+1))
	fi
    done
    #echo "Tab of mounted directory : ${Tab_Of_Mounted_Directory[*]}"
    #echo "Tab of mounted lv: ${Tab_Of_Mounted_Lv[*]}"	
    eval "score_tab="$(create_score_tab ${Tab_Of_Mounted_Directory[*]})
    #echo ${score_tab[*]}
    printf "("
    ( for ((i=0;i<${#Tab_Of_Mounted_Lv[*]};i++)) ; do 
        echo "${score_tab[$i]} ${Tab_Of_Mounted_Lv[$i]}" 
    done ) | sort -r | awk ' BEGIN { indice=0; } \
                                   { if(!indice) printf("%s",$2); \
                                     else printf(" %s",$2); \
                                     indice++; \
                                   } \
                              END { printf(")\n");}' 
#    
}



#la variable rewrited name tient compte des conventions d'écriture de linux 
#pour les VG dont le nom contient un tiret
rewrited_mapper_name() {
    nom_machine=$1
    echo $nom_machine | sed 's/\(-\)/\1\1/g'
}

#crée un pv et un vg du nom $1 sur la deuxième partition du disque passé en 2eme argument $2
create_pv() {
    nom_machine=$1
    periph=$2
    
    $PREFIX/kpartx -a $periph
    if [ $? -ne 0 ] ; then echo "Problem kpartx"; return 1; fi
    periph=$(periph_good_name $periph)
    if [ -b "$periph""2" ] ; then
        $PREFIX/pvcreate $periph"2"
        $PREFIX/vgcreate $nom_machine $periph"2"
        $PREFIX/vgchange --addtag tag_build $nom_machine
    else
        echo "ERREUR: Impossible de trouver le périphérique $partition_lvm"
        return 1
    fi
    $PREFIX/vgchange -a y $nom_machine
}

#Supprime les vg et les pv sur le périphérique spécifiés

remove_vg() {
    vg_name=$1
    $PREFIX/vgchange -a n $vg_name
    $PREFIX/vgremove -f $vg_name
}

remove_pv() {
    for i in $* ; do
        $PREFIX/pvremove -f $i
    done
}

remove_partition_table() {
    periph=$1
    dd if=/dev/zero of=$periph count=1 bs=512
}

create_lv() {
    nom_machine=$1
    #Creation des volumes logiques
    j=0
    for i in ${LVNAME[*]} ; do
        $PREFIX/lvcreate -n $i -L ${LVSIZE[$j]} $nom_machine
        j=$((j+1))
    done
}

format_first_part() {
    periph=$1
    periph=$(periph_good_name $periph)
    echo $periph
    first_part_on_periph="${periph}1"
    if [ -b "$first_part_on_periph" ] ; then
        mkfs.ext4 $first_part_on_periph
    else
        echo "Probleme else format_first_part"
        return 1
    fi
}

format_lv() {
    vg_name=$1
    fs_type=$2
    rewrited_vg=$(rewrited_mapper_name $vg_name)
    eval "Tab_Of_Lv="$(create_tab_of_lv $vg_name)
    for i in ${Tab_Of_Lv[*]} ; do
        rewrited_lv=$(rewrited_mapper_name $i)
        if [ -b "/dev/mapper/${rewrited_vg}-${rewrited_lv}" ] ; then
            if [ $i != "swap" ] ; then
                echo "Formatage de /dev/mapper/${rewrited_vg}-${rewrited_lv}"
                $PREFIX/mkfs.ext4 /dev/mapper/${rewrited_vg}-${rewrited_lv}
            else
                echo "Creation de la swap"
                $PREFIX/mkswap /dev/mapper/${rewrited_vg}-${rewrited_lv}
            fi
        else
            echo "Unable to build Filesystem /dev/mapper/${rewrited_vg}-${rewrited_lv}"
            return 1
        fi
    done
}

mount_lv() {
    vg_name=$1
    directory=$2
    
    grep -q "$directory " /etc/mtab
    if [ $? -eq 0 ]; then
        device=$(grep "$directory " /etc/mtab | awk ' { print $1 }')
        echo "Device : $device mounted in $directory"
        return 1
    fi
    rewrited_name=$(rewrited_mapper_name $vg_name)
    eval "Tab_Of_Lv="$(create_tab_of_lv $vg_name)        
    if [ ! -d "$directory" ]; then
        mkdir $directory
    fi
    if [ $? -eq 0 ] ; then
        mount /dev/mapper/$rewrited_name-$(rewrited_mapper_name ${Tab_Of_Lv[0]}) $directory
    fi
    if [ -d "$directory" ] ; then
        for i in $(seq 1 $((${#Tab_Of_Lv[*]}-1))) ; do
            rewrited_lv=$(rewrited_mapper_name ${Tab_Of_Lv[$i]})
            if [ "${Tab_Of_Lv[$i]}" != "swap" ] ; then 
                [ -d "$directory/${Tab_Of_Lv[$i]}" ] || mkdir $directory/${Tab_Of_Lv[$i]}
                mount /dev/mapper/$rewrited_name-${rewrited_lv} $directory/${Tab_Of_Lv[$i]}
            fi
        done
    fi
}

umount_lv() {
    vg_name=$1
    rewrited_vg=$(rewrited_mapper_name $vg_name)
    eval "sorted_Tab_Of_Lv="$(create_ordered_lv_tab_of_mounts $vg_name)
    for i in ${sorted_Tab_Of_Lv[*]} ; do
        rewrited_lv=$(rewrited_mapper_name $i)
        umount /dev/mapper/$rewrited_vg-$rewrited_lv
        if [ "$?" -ne 0 ] ; then
            echo "Impossible de démonter le volume logique $i du VG : $vg_name"
        fi
    done
}

mount_first_part() {
    directory=$1
    periph=$2
    directory_boot="$directory/boot"
    if [ ! -d "$directory_boot" ] ; then
        mkdir $directory_boot
    fi
    periph=$(periph_good_name $periph)
    mount -t ext4 ${periph}1 $directory_boot
    if [ $? -ne 0 ] ; then
        echo "Probleme de montage dans mount_first_part"
        return 1
    fi
}

umount_first_part() {
    directory=$1
    directory_boot="$directory/boot"
    grep -q $directory_boot /etc/mtab
    if [ $? -eq 0 ]; then
        umount $directory_boot
    fi
    if [ $? -ne 0 ]; then  echo "Impossible de démonter $directory/boot"
    else echo 0
    fi
    
}


PREFIX=/sbin
LVNAME=("root" "var" "usr" "tmp" "home" "swap")
LVMOUNT=("/" "/var" "/usr" "/tmp" "/home" "none")
LVSIZE=("1G" "2,8G" "4,6G" "512M" "1G" "2G")

#if [ ! $# -eq 2 ]; then
#    echo "Usage $0 <nom_machine> <periph>"
#    return 1
#fi
#nom_machine=$1
#periph=$2
#create_part_fdisk $periph
#create_pv $nom_machine $periph
#create_lv $nom_machine
#format_first_part $periph
#format_lv $nom_machine

#create_tab_of_lv $nom_machine
#create_score_tab / /usr /var /opt /usr/local /tmp /home
#create_ordered_lv_tab_of_mounts $nom_machine
#umount_lv $nom_machine
#mount_lv $nom_machine /mnt/$nom_machine
#mount_first_part /mnt/$nom_machine $periph
#umount_first_part /mnt/$nom_machine
#umount_lv $nom_machine
#remove_vg $nom_machine
#remove_pv $(periph_good_name $periph)"2"
#kpartx -d $periph
#remove_partition_table $periph
#eval "var="$(create_tab_of_lv thetradev)
#echo ${var[0]}
#create_tab_of_mounts 1 2 3 4 5 6 7 8 9
