#!/usr/bin/perl

# PURPOSE:
# Read a given ini config file to check if the clones are up, oracle is running etc.
# This was created for specific use-case for my company but could easily be modified
# to instead test for any other serices/conditions as needed.  If you have any questions
# don't hesitate to ask me at sirloper@gmail.com

# Initialize
use Getopt::Std;
use Config::IniFiles;
use threads;
use threads::shared;
use Switch;

# Get the arguments
getopts('hc:uv:', \%opts);

# Command-line checking
if ( $opts{'h'} ) {
    DoHelp( "ShowHelp" );
    exit( 0 );
}
unless( $opts{'c'} ) {
    DoHelp( "ConfigFile" );
    exit( 2 );
}
unless( $opts{'v'} ) {
    DoHelp( "version" );
    exit( 2 );
} else {
    unless ( $opts{'v'} =~ /stage|live/ ) {
        DoHelp( "version" );
        exit( 2 );
    }
}
if ( ( $opts{'u'} ) || ( $opts{'p'} ) ) {
    print "\n\nIncorrect usage!  Did you mean to call clone.pl instead?\n\n\n";
    exit( 1 );
}

tie %cfg, 'Config::IniFiles', ( -file => "$opts{'c'}" );


print "\nPreparing to test all targets defined in configuration file \"$opts{'c'}\" for $opts{'v'}.\n\nPlease wait, this may take a while. Results will be displayed once complete.\n\n";
    open( SQL_SCRIPT, ">", "/tmp/user_icm_runner_get_hash.sql" );
    print SQL_SCRIPT <<EOP;
set feedback off
set heading off
set echo off
set newpage 0
select password from sys.user\$ where name= 'USER_ICM_RUNNER';
EOP
    close( SQL_SCRIPT );
        open( SQL_SCRIPT, ">", "/tmp/user_icm_runner_test_lock.sql" );
    print SQL_SCRIPT <<EOP;
set feedback off
set heading off
set echo off
set newpage 0
select account_status from dba_users where username = 'USER_ICM_RUNNER';
EOP
    close( SQL_SCRIPT );
    
foreach $current_target ( keys %cfg ) {
    #print "Testing $current_target..\n";
    if ( $opts{'v'} =~ 'stage' ) {
        $test_ip = $cfg{$current_target}{'ipaddr'};
    } else {
        $test_ip = $cfg{$current_target}{'liveipaddr'};
    }
    #print "Local Hostname: ";
    if ( $opts{'v'} =~ 'stage' ) {
        print "(If this is all caps, post_clone did not run. DO NOT SWAP): "; 
    }
    $temp = `ssh -oConnectTimeout=3 -oStrictHostKeyChecking=no $test_ip 'echo \$HOSTNAME'`;
    $temp =~ s/\s+//g;
    $results{$current_target}[0] = $temp;
    $temp = `ssh -oConnectTimeout=3 -oStrictHostKeyChecking=no $test_ip 'ifconfig | grep -B1 'addr:10' | grep 'cast:10''`;
    @parts = split( /\s+/, $temp );
    $temp = $parts[2];
    $results{$current_target}[1] = $temp;
    #system( qq[ssh -oConnectTimeout=3 -oStrictHostKeyChecking=no $test_ip "su - oracle -c 'lsnrctl status | grep Service | grep -v 11G | grep -v PLSExt | grep -v Summary'"] );
    $oracle_status = `ssh -oConnectTimeout=3 -oStrictHostKeyChecking=no $test_ip "su - oracle -c 'lsnrctl status | grep Service | grep -v 11G | grep -v PLSExt | grep -v Summary'"`;
    while ( 1 ) {
        if ( $oracle_status =~ /Service/  ) {
            last;
        } else {
            print "Detected Oracle didn't start on $current_target.  Attempting to start now...\n";
            `ssh -oConnectTimeout=3 -oStrictHostKeyChecking=no $test_ip 'service dbora start'`;
            $oracle_status = `ssh -oConnectTimeout=3 -oStrictHostKeyChecking=no $test_ip "su - oracle -c 'lsnrctl status | grep Service | grep -v 11G | grep -v PLSExt | grep -v Summary'"`;
            next;
        }
    }
    
    # Test for locked account
    system( "scp -oConnectTimeout=3 -oStrictHostKeyChecking=no /tmp/user_icm_runner_get_hash.sql $test_ip:/tmp/user_icm_runner_get_hash.sql 2>1 > /dev/null" );
    $user_icm_runner_lock_result = `ssh -oConnectTimeout=3 -oStrictHostKeyChecking=no $test_ip "su - oracle -c \'echo \@/tmp/user_icm_runner_get_hash.sql \| sqlplus -S / as sysdba\'"`;
    $results{$current_target}[3] = $user_icm_runner_lock_result;
    
    # Get password hash
    system( "scp -oConnectTimeout=3 -oStrictHostKeyChecking=no /tmp/user_icm_runner_test_lock.sql $test_ip:/tmp/user_icm_runner_test_lock.sql 2>1 > /dev/null" );
    $user_icm_runner_hash_result = `ssh -oConnectTimeout=3 -oStrictHostKeyChecking=no $test_ip "su - oracle -c \'echo \@/tmp/user_icm_runner_test_lock.sql \| sqlplus -S / as sysdba\'"`;
    $results{$current_target}[4] = $user_icm_runner_hash_result;

    $oracle_status =~ s/\s+//g;
    @parts = split( /\"/, $oracle_status );
    $service_name = $parts[1];
    $results{$current_target}[2] = $service_name;
    #print "\n\n";
    
}

print <<EOS;
Summary:
=============================================================================================================
|     Host Name         |   Service Name    |    IP Address     |    Password Hash      |    Lock Status    |
|  (NOT be all caps)    | (Oracle Instance) |                   |  (All should match!)  | (should be OPEN)  |
=============================================================================================================
EOS

format STDOUT = 
| @|||||||||||||||||||| | @|||||||||||||||| | @|||||||||||||||| | @|||||||||||||||||||| | @|||||||||||||||| |
$results{$current_target}[0], $results{$current_target}[2], $results{$current_target}[1], $results{$current_target}[3], $results{$current_target}[4]
=============================================================================================================
.

foreach $current_target ( keys %cfg ) {
    write;
}

print "\n";

sub DoHelp {
    $error = shift;
    switch( $error ) {
        case "ConfigFile" { print "\nERROR: The config file to use was not specified.\n\nUSAGE:\n$0 <-c PATH/CONFIG_FILE.INI> -v <stage|live> | [-h]\n\n"; }
        case "version"    { print "\nERROR: The version (staged or live) to use was not specified.\n\nUSAGE:\n$0 <-c PATH/CONFIG_FILE.INI> -v <stage|live> | [-h]\n\n"; }
        case "ShowHelp"   { print "USAGE:\n$0 <-c PATH/CONFIG_FILE.INI> -v <stage|live> | [-h]\n\n"; }
        else              { print "USAGE:\n$0 <-c PATH/CONFIG_FILE.INI> -v <stage|live> | [-h]\n\n"; }
    }
}
