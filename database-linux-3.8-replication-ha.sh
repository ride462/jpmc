#!/bin/bash
#
# Version: 1.10 22-May-2014
#
# install HA to a controller pair
#
# this must be run on the primary, and ssh and rsync must be set up
# as root on both machines.
#
# if replication isn't broken before you run this, it certainly will be
# during.
#
# this has very limited sanity checking, so please be very careful.
#
primary=`hostname`
secondary=
controller_root=
datadir=
secondary_user=
controller_root_secondary=
datadir_secondary=
final=false
rsync_opts=-PIcavz

function usage()
{
	echo "usage: $0 <options>"
	echo "    -s <secondary hostname>"
	echo "    -c <controller root directory>"
	echo "    -d <controller root directory (secondary - optional)>"
	echo "    -e <controller data directory (secondary - optional)>"
	echo "    -f       do final install and activation"
	echo "    -g <user (secondary - optional)>"
	exit -1
}

while getopts s:c:d:e:f:g flag; do
	case $flag in
	s)
		secondary=$OPTARG
		;;
	c)
		controller_root=$OPTARG
		;;
	d)  
		controller_root_secondary=$OPTARG
		;;
	e)
		datadir_secondary=$OPTARG
		;;
	f)
		if [ -z "$noconfirm" ] ; then
			echo "type 'confirm' to stop appserver and install HA"
			read confirm
			if [ "$confirm" != confirm ] ; then
				exit 0;
			fi
		fi
		final=true
	;;
	g)
		secondary_user=$OPTARG
		;;
	*)
		usage
	;;
	esac
done

if [ -z "$controller_root" -o -z "$secondary" ] ; then
	echo must set all of -s and -c flags
	usage
fi

if [ -z "$controller_root_secondary" ] ; then
	controller_root_secondary=$controller_root
fi

datadir=`grep ^datadir $controller_root/db/db.cnf | cut -d = -f 2`
if [ -z "$datadir_secondary" ] ; then
	datadir_secondary=$datadir
fi

if [ -z "$secondary_user" ] ; then
	secondary_user=$USER
fi

#
# make sure replication has stopped
#
echo "STOP SLAVE;RESET SLAVE;RESET MASTER;" | $controller_root/bin/controller.sh login-db

#
# sanity check: make sure we are not the passive side. replicating the
# broken half of an HA will be a disaster!
if echo "select value from global_configuration where name = 'appserver.mode'" | $controller_root/bin/controller.sh login-db | grep -q passive ; then
	echo "copying from passive controller - BOGUS!"
	exit
fi

#
# stop the secondary database (and anything else)
#
ssh $secondary_user@$secondary $controller_root_secondary/bin/controller.sh stop

#
# if final, stop the primary database
#
if [ $final == 'true' ] ; then
	rsync_opts=-Pavz
	$controller_root/bin/controller.sh stop
fi

#
# make sure the db.cnf is HA-enabled.  if the string ^server-id is not there,
# then the primary has not been installed as an HA.
#
if grep -q ^server-id $controller_root/db/db.cnf ; then
	echo server-id present
else
	echo server-id not present
	cat <<- 'ADDITIONS' >> $controller_root/db/db.cnf
	# Replication -- MASTER MASTER (for HA installs) -- Should be appended 
	# to the end of the db.cnf file for the PRIMARY controller.
	binlog_cache_size=1M
	max_binlog_cache_size=10240M
	log_bin=bin-log
	log_bin_index=bin-log.index 
	relay_log=relay-log
	relay_log_index=relay-log.index
	innodb_support_xa=1
	sync_binlog=0
	log-slow-slave-statements
	log-slave-updates
	server-id=666  #  this needs to be unique server ID !!!
	replicate-same-server-id=0
	auto_increment_increment=10
	auto_increment_offset=1
	expire_logs_days=8
	binlog_format=MIXED
	replicate_ignore_table=controller.ejb__timer__tbl
	replicate_ignore_table=controller.connection_validation
	replicate_ignore_table=controller.global_configuration_local
	replicate_wild_ignore_table=controller.mq%
	replicate_wild_ignore_table=mysql.%
	slave-skip-errors=1507,1517,1062,1032,1451
	ADDITIONS
fi

#
# disable automatic start of replication slave
#
echo "skip-slave-start=true" >> $controller_root/db/db.cnf

#
# copy the controller + data to the secondar
#
echo "  -- Rsync'ing Controller: $controller_root"
rsync $rsync_opts								                    \
    --exclude=license.lic						                    \
	--exclude=logs/\*							                    \
	--exclude=db/data/\*                                            \
	--exclude=db/bin/.status                                         \
	--exclude=app_agent_operation_logs/\*                           \
	--exclude=appserver/glassfish/domains/domain1/appagent/logs/\*  \
	--exclude=tmp/\*                                                \
	--inplace --bwlimit=20000					                    \
	$controller_root/ $secondary:$controller_root_secondary
echo "  -- Rsync'ing Data: $datadir"
rsync $rsync_opts							                        \
    --exclude=bin-log\*						                        \
    --exclude=relay-log\*					                        \
    --exclude=\*.log						                        \
    --exclude=\*.pid                                                \
    --inplace --bwlimit=20000				                        \
    $datadir/ $secondary:$datadir_secondary
echo "  -- Rsyncs complete"

#
# restore db.cnf datdir setting on secondary
#
cat > /tmp/ha.changedatadir <<- CHANGEDATADIR
/^datadir=/s,=.*,=$datadir_secondary,
wq
CHANGEDATADIR

#
# edit the secondary to change the datadir
#
cat /tmp/ha.changedatadir | ssh $secondary_user@$secondary ed -s $controller_root_secondary/db/db.cnf

#
# always update the changeid - this marks the secondary
#
cat > /tmp/ha.changeid <<- 'CHANGEID'
/^server-id=/s,666,555,
wq
CHANGEID

#
# edit the secondary to change the server id
#
cat /tmp/ha.changeid | ssh $secondary_user@$secondary ed -s $controller_root_secondary/db/db.cnf

#
# if we're only do incremental, then no need to stop primary
#
if [ $final == 'false' ] ; then
	exit 0;
fi

#
# restart the primary db
#
$controller_root/bin/controller.sh start-db

#
# let's probe the canonical hostnames from the local database
#
primary=`$controller_root/db/bin/mysql --host=$primary --port=3388 --protocol=TCP --user=impossible 2>&1 | awk '{ gsub("^.*@",""); print $1;}' | tr -d \'`

secondary=`ssh $secondary_user@$secondary $controller_root_secondary/db/bin/mysql --host=$primary --port=3388 --protocol=TCP --user=impossible 2>&1 | awk '{ gsub("^.*@",""); print $1;}' | tr -d \'`

#
# build the scripts
#

cat >/tmp/ha.primary <<- PRIMARY
STOP SLAVE;
RESET SLAVE;
RESET MASTER;
GRANT ALL ON *.* TO 'controller_repl'@'$secondary' IDENTIFIED BY 'controller_repl';
CHANGE MASTER TO MASTER_HOST='$secondary', MASTER_USER='controller_repl', MASTER_PASSWORD='controller_repl', MASTER_PORT=3388;
update global_configuration_local set value = 'active' where name = 'appserver.mode';
update global_configuration_local set value = 'primary' where name = 'ha.controller.type';
truncate ejb__timer__tbl;
PRIMARY

cat > /tmp/ha.secondary <<- SECONDARY
STOP SLAVE;
RESET SLAVE;
RESET MASTER;
GRANT ALL ON *.* TO 'controller_repl'@'$primary' IDENTIFIED BY 'controller_repl';
CHANGE MASTER TO MASTER_HOST='$primary', MASTER_USER='controller_repl', MASTER_PASSWORD='controller_repl', MASTER_PORT=3388;
update global_configuration_local set value = 'passive' where name = 'appserver.mode';
update global_configuration_local set value = 'secondary' where name = 'ha.controller.type';
truncate ejb__timer__tbl;
SECONDARY

cat > /tmp/ha.enable <<- 'DISABLE'
g/^skip-slave-start/d
wq
DISABLE

#
# make all the changes on the primary to force master
#
cat /tmp/ha.primary | $controller_root/bin/controller.sh login-db

#
# start the secondary database
#
ssh -f -n $secondary_user@$secondary $controller_root_secondary/bin/controller.sh start-db

#
# ugly hack here - there seems to be a small timing problem
#
until ssh $secondary_user@$secondary tail -2 $controller_root_secondary/logs/database.log | grep -q "ready for connections" ; do
	echo "waiting for mysql to start"
	sleep 2
done
sleep 10

#
# make all the changes on the secondary
#
cat /tmp/ha.secondary | ssh $secondary_user@$secondary $controller_root_secondary/bin/controller.sh login-db

sleep 10

cat /tmp/ha.enable | ed -s $controller_root/db/db.cnf
cat /tmp/ha.enable | ssh $secondary_user@$secondary ed -s $controller_root_secondary/db/db.cnf

#
# start the replication slaves
#
echo "START SLAVE;" | $controller_root/bin/controller.sh login-db
echo "START SLAVE;" | ssh $secondary_user@$secondary $controller_root_secondary/bin/controller.sh login-db

#
# finally, restart the appserver
#
$controller_root/bin/controller.sh start-appserver

