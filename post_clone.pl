#!/usr/bin/perl

###############################################################################
# WARNING! # WARNING! # WARNING! # WARNING! # WARNING! # WARNING! # WARNING! ##
###############################################################################
#       THIS WILL NOT WORK IN ITS CURRENT FORM WITH RHEL/CENTOS 7            ##
## NOT SURE WHY - WILL INVESTIGATE SHOULD WE RUN RHEL/CENTOS 7 IN THE FUTURE ##
###############################################################################

# PURPOSE:
# This script sits on the SOURCE VM or template to be executed manually after
# cloning or, preferrably, invoked as a service (see post_clone.service).  It 
# cleans up the network interface files, host name and Oracle configuration files
# to remove remants of what is left behind following a normal clone operation.
#
# This script was created to handle our specific needs, but could be easily modified
# to suit any other generic or specific operations per company.  If you have questions,
# don't hesitate to contact me at sirloper@gmail.com

###############################################################################
#
# Version History
# 7/24/14 - (mcartwright) - Initial release.
# 7/25/14 - (mcartwright) - Changed dbora active_flag to only manipulate chkconfig.
#			 			  - Added "alter database" for global name config.
# 8/7/14  - (mcartwright) - Added error checking if the host isn't in the host_services table.
#                         - Misc bug fixes on host and service name variable placement.
#                         - Refactor host_service lookup to avoid table scans (added "where" clause").
#                         - Fixed hadling of active_flag in host_service table to read it correctly.
#                         - Current post-run reboot is required and prompts the user before rebooting.  This
#                           will change in the next release to be automatic with an override flag.
# 8/8/14  - (mcartwright) - Added puppet agent and customization to determine puppet master to use and write puppet.conf.
#                           Puppet masters updated to include a class to invoke this script once/year at most.
# 8/15/14 - (mcartwright) - Fixed a bug surrounding the ora_active_flag not being read correctly.
#                         - Changed the select from the service_name table to truncate all but 1 space between columns.
#                         - Changed the guessing of GATEWAY and IPADDR to be a bit more safe and not assume only 2 interface files max.
# 8/26/14 - (mcartwright) - Fixed grepping for the IPADDR to avoid listing the file name in the output regardless of how many files grep examined.
# 9/11/14 - (mcartwright) - Added -h to grep commands to avoid weirdness if there are multiple files being searched
#						  - Removed reboot question and made it automatic.  This is to support the new run-once system on fresh clones.
# 5/1/15  - (mcartwright) - Fixed ntpdate to use static time server
# 5/12/15 - (mcartwright) - Modified /etc/hosts format to include staged ip address and full name to allow for Oracle to start even in
#							staged state, allowing database alters to occur.
# 5/29/15 - (mcartwright) - Added code to automatically set password for user_icm_runner based on environment.
# 7/6/15  - (mcartwright) - Added special case for RVA Rule nodes (RLSAP* and RLSAQ*) to set special sga sizes.
# 9/3/15  -	(mcartwright) - Added overwrite for /etc/fstab to remove golden gate mount point
# 11/1/15 - (mcartwright) - Added special case for Dallas RT Rule nodes to set special DB Sizes
# 1/4/16  - (mcartwright) - Refactored handling of different init files (single format for all initRLSDB11G files)
#						  - Removed dependancy of gridctl1.host_service for passwords and service name mapping (internalized map)
# 1/5/16  - (mcartwright) - Removed puppet configuration attempts and reading of "active" flag due to non-use
# 1/13/16 - (mcartwright) - Added custom /etc/security/limits.d/99-grid-oraclelimits.conf and /etc/grub.conf formats to handle huge page settings
#
###############################################################################

use strict "refs"; # Always a good idea.
use File::Copy;
#use File::Path;

###############################################################################
# User-defined global variables (no trailing slash on paths!)
###############################################################################
#
my $TNS_ADMIN = "/u01/app/oracle/product/11.2.0/dbhome_1/network/admin";
my $ORACLE_HOME = "/u01/app/oracle/product/11.2.0/dbhome_1";

# hostname to service name and password mapping
# Format: 'HOSTNAME' => ['SERVICE_NAME', 'PASSWORD_HASH'],
my %host_to_service_name_map = (
	'DALRLSGOLD' 	=> ['RLSGOLDN', '9B4AD08E857AC3C1' ],
	'HPNCDRVA01' 	=> ['RLSAD01', '3EE9CE226DBDD442' ],
);
#
#'End of User-define global Variables
###############################################################################

# Main
# Extend the path so that root knows about sqlplus etc.
$ENV{PATH} = "$ENV{PATH}:/u01/app/oracle/product/11.2.0/dbhome_1/bin";
$ENV{ORACLE_HOME} = "/u01/app/oracle/product/11.2.0/dbhome_1";
# First, the host name - storing both capital and lower-case for differnet use-cases.
my $hostname = uc( `hostname -s` );
chomp( $hostname );
if ( $hostname =~ /[0-9]{12}$/ ) {
	$hostname = substr( $hostname, -99, -12 );
}
$lower_hostname = lc( $hostname );
if ( $lower_hostname =~ /gold|prime|usapmaj/i ) {
	print "This script should never be executed on a Master.  Exiting...\n";
	exit( 1 );
}

# Get the UID/GID for oracle:dba to be sure file ownerships correct later.
my $pass_entry = `grep -h ^oracle /etc/passwd`;
my ( $user, $xpass, $uid, $gid, $comment, $home, $shell ) = split( /:/, $pass_entry );

# Figure out the IP address, Netmask and Gateway based on existing files.
# Look first in the proper place, but fall-back to the secondary in case the clone isn't "clean".
my $ipaddr = `grep -h IPADDR /etc/sysconfig/network-scripts/ifcfg-eth\* \| tail -1`;
my ( $junk, $short_ipaddr ) = split( /=/, $ipaddr );

my $netmask = `grep -h NETMASK /etc/sysconfig/network-scripts/ifcfg-eth\* \| tail -1`;

my $gateway = `grep -h GATEWAY /etc/sysconfig/network-scripts/ifcfg-eth\* \|tail -1 2> /dev/null`;

# Make sure that the date/time is accurat
system( "service ntpd stop; ntpdate ntp.mycompany.com; service ntpd start" );


print "Beginning customization ...\n";

# Start the database for now so we can alter the global table..
system( "service dbora start" );
print "Waiting for Oracle to become available...\n";
sleep( 30 );

#Do this before re-writing the files so that Oracle will start and global_name can be changed.
PostRunCleanup();

# create the new config files before creating the new config files and rebooting.
DefineFormats();

system( "mkdir -p /root/automation_backups" );
# Write out the files, saving a backup just in case (in root's home directory to be sure no files conflict..
copy( "/etc/sysconfig/network", "/root/automation_backups/network.orig" );
open( NETWORK_FILE, ">", "/etc/sysconfig/network" );
select( NETWORK_FILE );
write;
close( NETWORK_FILE );

copy( "/etc/sysconfig/network-scripts/ifcfg-eth0", "/root/automation_backups/ifcfg-eth0" );
open( IFCFG_ETH0, ">", "/etc/sysconfig/network-scripts/ifcfg-eth0" );
select( IFCFG_ETH0 );
write;
close( IFCFG_ETH0 );

copy( "/etc/hosts", "/root/automation_backups/hosts" );
open( ETC_HOSTS, ">", "/etc/hosts" );
select( ETC_HOSTS );
write;
close( ETC_HOSTS );

copy( "$ORACLE_HOME/dbs/initRLSDB11G.ora", "/root/automation_backups/initRLSDB11G.ora" );
# Set up different oracle parameters depending on the host name, which dictates SGA sizing and Grub memory settings
if ( $host_to_service_name_map{$hostname}[0] =~ /RLSAP|RLSAQ/ ) {
	$db_cache_size = '3G';
	$sga_max_size = '8G';
	$sga_target = '8G';
	$shared_pool_size = '3G';
	$grub_setting = '4101';
	$oracle_soft_memlock = '8398848';
	$oracle_hard_memlock = '8398848';
} elsif ( $host_to_service_name_map{$hostname}[0] =~ /RLSPRD[21-23]/ ) {
	$db_cache_size = '6G';
	$sga_max_size = '12G';
	$sga_target = '12G';
	$shared_pool_size = '2G';
	$grub_setting = '6149';
	$oracle_soft_memlock = '12593152';
	$oracle_hard_memlock = '12593152';
} else {
	$db_cache_size = '3G';
	$sga_max_size = '6G';
	$sga_target = '6G';
	$shared_pool_size = '1G';
	$grub_setting = '6149';
	$oracle_soft_memlock = '12593152';
	$oracle_hard_memlock = '12593152';
}
open( INIT_RLSDB11G, ">", "$ORACLE_HOME/dbs/initRLSDB11G.ora" );
select INIT_RLSDB11G;
write;
close( INIT_RLSDB11G );
chown( $uid, $gid, "$ORACLE_HOME/dbs/initRLSDB11G.ora" );

copy( "$TNS_ADMIN/listener.ora", "/root/automation_backups/listener.ora" );
open( LISTENER_ORA, ">", "$TNS_ADMIN/listener.ora" );
select( LISTENER_ORA );
write;
close( LISTENER_ORA );
chown( $uid, $gid, "$TNS_ADMIN/listener.ora" );
select( STDOUT );

open ( ETC_FSTAB, ">", "/etc/fstab" );
select( ETC_FSTAB );
write;
close( ETC_FSTAB );
select( STDOUT );

open ( GRID_ORACLELIMITS_CONF, ">", "/etc/security/limits.d/99-grid-oraclelimits.conf" );
select( GRID_ORACLELIMITS_CONF );
write;
close( GRID_ORACLELIMITS_CONF );
select( STDOUT );

open ( GRUB_CONF, ">", "/etc/grub.conf" );
select( GRUB_CONF );
write;
close( GRUB_CONF );
select( STDOUT );

open ( SYSCTL_CONF, ">>", "/etc/sysctl.conf" );
print SYSCTL_CONF <<EOP;
### oracle recommendations for swappiness
vm.swappiness = 0
vm.dirty_background_ratio = 3
vm.dirty_ratio = 80
vm.dirty_expire_centisecs = 500
vm.dirty_writeback_centisecs = 100
EOP
close( SYSCTL_CONF );

# Subroutine definitions

sub PostRunCleanup {
	# This will truncate files that need it and generally clean up after ourselves.
	system( "cat /dev/null > /etc/udev/rules.d/70-persistent-net.rules" );

	if ( -e "/etc/sysconfig/network-scripts/ifcfg-eth1" ) {
		unlink( "/etc/sysconfig/network-scripts/ifcfg-eth1" );
	}
	if ( -e "/etc/sysconfig/network-scripts/route6-eth1" ) {
		unlink( "/etc/sysconfig/network-scripts/route6-eth1" );
	}
	if ( -e "/etc/sysconfig/network-scripts/route-eth1" ) {
		move( "/etc/sysconfig/network-scripts/route-eth1", "/etc/sysconfig/network-scripts/route-eth0" );
	}
	
	# Set the host name temporarily to satisfy Oracle
	system( "hostname $lower_hostname" );
	
	# Make sure that Oracle starts at boot
	system( "chkconfig dbora on" );
	
	# Make sure that the net-snmp service is OFF on clones.
	system( "chkconfig snmpd off" );

	# Alter the GLOBAL_NAME database to match the service name.
	system( "su - oracle -c \'echo \"ALTER DATABASE RENAME GLOBAL_NAME TO $host_to_service_name_map{$hostname}[0].IHT.COM \;\" \| sqlplus \/ as sysdba\'" );

	# Retrive the proper query to set the password for this system.
	open( PASSWD, ">", "/tmp/passwd.txt" );
	print PASSWD "alter user user_icm_runner identified by values '$host_to_service_name_map{$hostname}[1]'\;";
	close( PASSWD );

	# Set the password for user_icm_runner
	system( "su - oracle -c 'echo \"@/tmp/passwd.txt\" | sqlplus / as sysdba'" );
	
	# Clean up the temp file
	unlink "/tmp/passwd.txt";

	print "\n...Done!\n\n";

	print "Rebooting to allow post clone customizations to take effect ...\n";
	system( "reboot" );
}

sub DefineFormats {
	# Format definitions
	format NETWORK_FILE =
NETWORKING=yes
HOSTNAME=@*
        $lower_hostname
DNS1=10.128.0.11
DNS2=10.128.0.12
DNS3=10.36.0.11
DOMAIN="mycompany.com"
.

	format IFCFG_ETH0 =
DEVICE=eth0
TYPE=Ethernet
ONBOOT=yes
NM_CONTROLLED=no
BOOTPROTO=static
@*
$ipaddr
@*
$netmask
@*
$gateway
.

	format ETC_HOSTS =
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
@*			@* @*.mycompany.com
$short_ipaddr,		$lower_hostname, $lower_hostname
.

	format LISTENER_ORA =
# listener.ora Network Configuration File: /u01/app/oracle/product/11.2.0/dbhome_1/network/admin/listener.ora
# Generated by Oracle configuration tools.

SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (SID_NAME = PLSExtProc)
      (ORACLE_HOME = /u01/app/oracle/product/11.2.0/dbhome_1)
      (PROGRAM = extproc)
    )
  )

LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = @*)(PORT = 1521))
										 $lower_hostname
      (ADDRESS = (PROTOCOL = IPC)(KEY = EXTPROC0))
    )
  )
.

	format INIT_RLSDB11G =
*.pre_page_sga=FALSE
filesystemio_options=asynch
### 3-7-2013 PL/SQL native compilation
plsql_code_type=NATIVE
plsql_optimize_level=2

*.log_checkpoint_interval=0
*.log_checkpoint_timeout=0
*.fast_start_mttr_target=3600
*.compatible='11.2.0.3.0'
*.optimizer_features_enable=11.2.0.3
# Turn off 11g password case sensitivity
sec_case_sensitive_logon=FALSE

*.audit_trail='none'
*.diagnostic_dest='/u01/app/oracle'
*.audit_file_dest='/u01/app/oracle/admin/RLSDB11G/adump'
*.control_file_record_keep_time=14
*.control_files='/u02/oradata/RLSDB11G/RLSDB11G_control_01.ctl','/u02/oradata/RLSDB11G/RLSDB11G_control_02.ctl','/u02/oradata/RLSDB11G/RLSDB11G_control_03.ctl'
*.db_block_size=8192
*.db_cache_advice='on'
*.db_cache_size=@*
$db_cache_size
*.db_domain='iht.com'
*.db_files=100
*.db_name='RLSDB11G'
*.db_recovery_file_dest='/u02/arch'
*.db_recovery_file_dest_size=20G
*.db_recycle_cache_size=0
*.db_writer_processes=4
*.dbwr_io_slaves=0
*.global_names=true
*.instance_name='RLSDB11G'
*.java_pool_size=64M
*.java_soft_sessionspace_limit=10485760
*.job_queue_processes=10
*.large_pool_size=128M
*.log_archive_format='%t_%s_%r.arch'
*.log_archive_max_processes=2
*.log_archive_min_succeed_dest=1
*.nls_length_semantics='BYTE'
*.open_cursors=800
*.parallel_execution_message_size=2148
*.parallel_max_servers=20
*.pga_aggregate_target=1G
*.processes=1500
*.query_rewrite_enabled='FALSE'
*.recyclebin='OFF'
*.remote_login_passwordfile='EXCLUSIVE'
*.resource_limit=true
*.session_cached_cursors=500
*.session_max_open_files=50
*.sga_max_size=@*
$sga_max_size
*.sga_target=@*
$sga_target
*.shared_pool_size=@*
$shared_pool_size
*.shared_pool_reserved_size=128M
*.star_transformation_enabled='FALSE'
*.streams_pool_size=100663296
*.trace_enabled=FALSE
*.undo_management='AUTO'
*.undo_retention=10800
*.undo_tablespace='UNDO'
*.service_names='@*.iht.com'
$host_to_service_name_map{$hostname}[0]
.

	format ETC_FSTAB =
#
# /etc/fstab
# Created by anaconda on Thu Aug 15 16:05:44 2013
#
# Accessible filesystems, by reference, are maintained under '/dev/disk'
# See man pages fstab(5), findfs(8), mount(8) and/or blkid(8) for more info
#
/dev/mapper/vg_centos-lv_root /                       ext4    defaults        1 1
UUID=df7384ba-f011-480a-aa62-3414a50c425a /boot                   ext4    defaults        1 2
/dev/mapper/vg_centos-oracle /u02                    ext4    defaults        1 2
/dev/mapper/vg_centos-lv_swap swap                    swap    defaults        0 0
tmpfs                   /dev/shm                tmpfs   defaults        0 0
devpts                  /dev/pts                devpts  gid=5,mode=620  0 0
sysfs                   /sys                    sysfs   defaults        0 0
proc                    /proc                   proc    defaults        0 0
.

	format GRUB_CONF =
# grub.conf generated by post_clone.pl
#
# Note that you do not have to rerun grub after making changes to this file
# NOTICE:  You have a /boot partition.  This means that
#          all kernel and initrd paths are relative to /boot/, eg.
#          root (hd0,0)
#          kernel /vmlinuz-version ro root=/dev/mapper/vg_centos-lv_root
#          initrd /initrd-[generic-]version.img
#boot=/dev/vda
default=0
timeout=5
splashimage=(hd0,0)/grub/splash.xpm.gz
hiddenmenu
title CentOS (2.6.32-431.17.1.el6.x86_64)
        root (hd0,0)
        kernel /vmlinuz-2.6.32-431.17.1.el6.x86_64 ro root=/dev/mapper/vg_centos-lv_root rd_NO_LUKS LANG=en_US.UTF-8 rd_LVM_LV=vg_centos/lv_swap rd_NO_MD SYSFONT=latarcyrheb-sun16 crashkernel=auto rd_LVM_LV=vg_centos/lv_root  KEYBOARDTYPE=pc KEYTABLE=us rd_NO_DM rhgb quiet clocksource_failover=acpi_pm hugepages=@* transparent_hugepage=never
		$grub_setting
        initrd /initramfs-2.6.32-431.17.1.el6.x86_64.img
.

	format GRID_ORACLELIMITS_CONF =
	oracle soft nproc 2047
oracle hard nproc 16384
oracle soft nofile 1024
oracle hard nofile 65536
oracle soft stack 10240
oracle hard stack 32768
oracle soft memlock @*
$oracle_soft_memlock
oracle hard memlock @*
$oracle_hard_memlock
grid soft nproc 2047
grid hard nproc 16384
grid soft nofile 1024
grid hard nofile 65536
grid soft stack 10240
grid hard stack 32768 
.

}
