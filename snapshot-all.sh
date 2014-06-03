#!/bin/bash

dir=/etc/xen/scripts
. $dir/locking.sh

XM_COMMAND=/usr/sbin/xm
REP_COW=/usr/local/

get_domid() {
	domain_name=$1
	echo $($XM_COMMAND domid $domain_name)
}

is_multipath() {
	block=$1
	dmsetup table | grep -q multipath
	if [ $? -eq 0 ]; then echo 0
	else echo 1
	fi
}

create_mapper() {
	dev=$1
	echo 0 $(blockdev --getsz $dev) linear $dev 0 | dmsetup create dev"$dev"
}

create_snap() {
	mapping=$1
	cow_block=$2
	chunk_size=$3
	echo 0 $(blockdev --getsz $mapping) snapshot $mapping $cow_block p $chunk_size | dmsetup create snap"$mapping"
}

create_dup() {
	mapping=$1
	dmsetup table $mapping | dmsetup create "$mapping"dup
}

get_max_priority() {
	multipath_mapping=$1
	awk ' BEGIN { priority=0; }
	      { if (NR!=1) 
		{
			if(priority<=$4) {
				path=$1;
				dev=$2
				dev_t=$3
				priority=$4
			}
		}
	     }
	     END { printf("%s %s %s\n",path,dev,dev_t); }'

}			

#echo 0 $(blockdev --getsz /dev/sdd) linear /dev/sdd 0 | dmsetup create devsdd
#dmsetup table devsdd | dmsetup create devsdddup
#xm pause jlt
#dmsetup suspend mpath1
#dm suspend sdd
#dd if=/dev/zero of=/usr/local/devsdd-cow.img count=8 seek=2097152
#losetup -f /usr/local/devsdd-cow.img
#LOOP=$(losetup -a | grep devsdd-cow.img | cut -d : -f 1)
#echo 0 $(blockdev --getsz devsdddup) snapshot /dev/mapper/devsdddup $LOOP p 8 | \
#	dmsetup create snapdevsdd
#echo 0 $(blockdev --getsz devsdddup) snapshot-origin /dev/mapper/devsdddup | \
#	dmsetup create origindevsdd
#dmsetup table origindevsdd | dmsetup load devsdd

#xenstore-write /local/domain/0/backend/vbd/4/51728/physical-device fe:15
#xenstore-read /local/domain/0/backend/vbd/4/51728/physical-device
